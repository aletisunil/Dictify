import AppKit
import Foundation
import os

enum TargetWritingContext: String, Sendable {
    case email
    case chat
    case document
    case code
    case neutral
}

/// Main-actor-isolated Timer wrapper. Owning the `Timer` here (rather than on
/// the pipeline actor via `nonisolated(unsafe)`) guarantees all Timer
/// interaction stays on the main run loop, which Timer requires.
@MainActor
final class ElapsedTimer {
    private var timer: Timer?

    func start(onTick: @escaping @MainActor @Sendable () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                onTick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}

actor TranscriptionPipeline {
    private let appState: AppState
    private let audioEngine: AudioEngine
    private let groqClient: GroqClient
    private let whisperService: WhisperService
    private let gptOssService: GPTOssService
    private let accessibilityInserter: AccessibilityInserter
    private let clipboardPaster: ClipboardPaster
    private let dictionaryStore: DictionaryStore
    private let snippetStore: SnippetStore
    private let historyStore: HistoryStore
    private let statsStore: StatsStore
    private let settings: DictifySettings
    private let elapsedTimer: ElapsedTimer
    private let mediaController: MediaPlaybackController

    private var maxRecordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingGeneration = 0
    private var insertionInFlight = false
    /// Monotonic token identifying the latest start/stop/cancel/interruption
    /// transition. `startRecording` snapshots it and re-checks after suspension
    /// points: a mismatch means another transition interleaved via actor
    /// reentrancy and now owns the pipeline state.
    private var startGeneration = 0
    /// Inputs `startRecording` needs from the main actor, snapshotted in a
    /// single hop so the hotkey→capture path pays one context switch, not four.
    private struct StartContext {
        let writingContext: TargetWritingContext
        let preferredDeviceUID: String
        let pauseMediaDuringDictation: Bool
    }
    /// True when we paused system media for the current dictation, so we only
    /// resume what we actually paused.
    private var didPauseMedia = false
    /// Coarse context inferred locally when capture starts. Raw browser window
    /// titles are never logged, persisted, or sent to Groq.
    private var targetWritingContext: TargetWritingContext = .neutral
    /// Browsers whose bundle alone cannot identify writing context. Their focused
    /// window title is classified locally and immediately discarded.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
    ]

    init(appState: AppState,
         keychainManager: KeychainManager,
         dictionaryStore: DictionaryStore,
         snippetStore: SnippetStore,
         historyStore: HistoryStore,
         statsStore: StatsStore,
         mediaController: MediaPlaybackController) {
        self.appState = appState
        self.audioEngine = AudioEngine()
        self.groqClient = GroqClient(keychainManager: keychainManager)
        self.whisperService = WhisperService(client: groqClient)
        self.gptOssService = GPTOssService(client: groqClient)
        self.accessibilityInserter = AccessibilityInserter()
        self.clipboardPaster = ClipboardPaster()
        self.dictionaryStore = dictionaryStore
        self.snippetStore = snippetStore
        self.historyStore = historyStore
        self.statsStore = statsStore
        self.settings = appState.settings
        self.elapsedTimer = MainActor.assumeIsolated { ElapsedTimer() }
        // Injected (not created here) so AppDelegate can reach it for the
        // best-effort media resume on app termination.
        self.mediaController = mediaController
    }

    /// See `AudioEngine.prewarm()` — called once at launch after permissions
    /// are confirmed so the first hotkey trigger skips the CoreAudio cold start.
    func prewarm() {
        audioEngine.prewarm()
    }

    func startRecording() async {
        guard !audioEngine.isRecording else {
            return
        }
        startGeneration &+= 1
        let generation = startGeneration

        // Single main-actor hop: validate state, snapshot everything the start
        // needs, and optimistically show the recording UI. The indicator must
        // not wait on CoreAudio — engine start (especially a Bluetooth route
        // switch) can take hundreds of ms, and that lag reads as hotkey lag.
        let context: StartContext? = await MainActor.run {
            switch appState.pipelineState {
            case .idle, .error:
                // Entering .recording also resets a stale error (e.g. 400 from
                // the previous attempt) so the next activation isn't blocked.
                appState.pipelineState = .recording
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0

                // Snapshot and classify the target now because focus can move
                // before insertion. Browser titles are inspected only locally
                // and immediately reduced to a coarse writing context.
                let app = NSWorkspace.shared.frontmostApplication
                let bundleID = app?.bundleIdentifier ?? ""
                let windowTitle = Self.focusedWindowTitle(for: app?.processIdentifier)
                return StartContext(
                    writingContext: Self.classifyWritingContext(
                        bundleID: bundleID,
                        windowTitle: windowTitle
                    ),
                    preferredDeviceUID: settings.selectedInputDeviceUID,
                    pauseMediaDuringDictation: settings.pauseMediaDuringDictation
                )
            default:
                return nil
            }
        }
        guard let context else {
            return
        }

        guard generation == startGeneration else {
            // A stop/cancel interleaved during the hop above. If its idle-write
            // ran before our optimistic .recording write nothing else will
            // clear it, so do it here; if it ran after, the guard below makes
            // this a no-op.
            await MainActor.run {
                if case .recording = appState.pipelineState {
                    appState.pipelineState = .idle
                    appState.audioLevels = Array(repeating: 0, count: 15)
                    appState.recordingElapsed = 0
                }
            }
            return
        }

        targetWritingContext = context.writingContext

        do {
            // Async: a Bluetooth route settle can suspend here, so stop/cancel
            // may interleave — the engine aborts via its own captureGeneration,
            // and the check below unwinds anything they couldn't see yet.
            try await audioEngine.startCapture(
                preferredDeviceUID: context.preferredDeviceUID,
                levelCallback: { [weak appState] levels in
                    appState?.audioLevels = levels
                },
                onInterruption: { [weak self] reason in
                    guard let self = self else { return }
                    Task { await self.handleInterruption(reason) }
                }
            )
            guard generation == startGeneration else {
                audioEngine.stopCapture()
                return
            }
            scheduleMaxDurationStop()

            // UI is already showing; the Tink stays truthful — it means "mic
            // is live, start talking", which matters on the Bluetooth retry
            // path where capture start can lag the indicator.
            await MainActor.run {
                appState.playSound("Tink")
            }
            await startElapsedTimer()

            // Pause system media after the recording cue so the helper subprocess
            // doesn't delay the "Tink". We only resume what we pause (`didPauseMedia`).
            if context.pauseMediaDuringDictation {
                let paused = await mediaController.pauseIfPlaying()
                if paused {
                    // The pause is async: a near-instant stop can run (actor
                    // reentrancy) while we await above, find `didPauseMedia`
                    // still false, and skip its resume. If recording already
                    // ended, resume immediately so media isn't left muted.
                    if audioEngine.isRecording {
                        didPauseMedia = true
                    } else {
                        await mediaController.resumeIfWePaused(true)
                    }
                }
            }
        } catch {
            audioEngine.stopCapture()
            cancelMaxDurationStop()
            await resumeMediaIfNeeded()
            Log.pipeline.error("Failed to start capture: \(error.localizedDescription, privacy: .public)")
            // A stop/cancel may have interleaved at the await above; it owns
            // the state now, so don't overwrite its .idle with an error.
            guard generation == startGeneration else {
                return
            }
            await MainActor.run {
                appState.pipelineState = .error("Microphone unavailable")
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
                appState.playSound("Basso")
            }
        }
    }

    func stopRecording() async {
        startGeneration &+= 1
        guard audioEngine.isRecording else {
            await stopElapsedTimer()
            await resumeMediaIfNeeded()
            await MainActor.run {
                if case .recording = appState.pipelineState {
                    appState.pipelineState = .idle
                    appState.audioLevels = Array(repeating: 0, count: 15)
                    appState.recordingElapsed = 0
                }
            }
            return
        }

        cancelMaxDurationStop()
        await stopElapsedTimer()

        let duration = audioEngine.recordingDuration
        let pcmData = audioEngine.stopCapture()

        // Resume media as soon as capture ends — don't wait on transcription.
        await resumeMediaIfNeeded()

        await MainActor.run {
            appState.playSound("Pop")
        }

        guard duration >= Constants.Audio.minRecordingDuration else {
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        }

        processingTask?.cancel()
        processingGeneration &+= 1
        let currentProcessingGeneration = processingGeneration
        processingTask = Task { [weak self] in
            await self?.processCapturedAudio(
                pcmData: pcmData,
                duration: duration,
                generation: currentProcessingGeneration
            )
        }
    }

    /// Resume system media iff we paused it for this dictation. Idempotent.
    private func resumeMediaIfNeeded() async {
        guard didPauseMedia else { return }
        didPauseMedia = false
        await mediaController.resumeIfWePaused(true)
    }

    private func processCapturedAudio(
        pcmData: Data,
        duration: TimeInterval,
        generation: Int
    ) async {
        guard generation == processingGeneration else { return }

        let speechEvidence = SpeechEvidenceAnalyzer.analyze(pcmData: pcmData)
        guard speechEvidence.hasSpeech else {
            Log.pipeline.notice(
                "Skipped no-speech capture (voicedMs=\(speechEvidence.totalVoicedMilliseconds, privacy: .public), longestRunMs=\(speechEvidence.longestVoicedRunMilliseconds, privacy: .public), thresholdDBFS=\(speechEvidence.thresholdDBFS, privacy: .public))"
            )
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        }

        let wavData = WAVEncoder.encode(pcmData: pcmData)

        // Start the 100ms focus-handoff wait NOW, concurrent with upload +
        // refine. By the time we're ready to insert, it's already elapsed.
        let focusHandoffTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        await MainActor.run {
            appState.pipelineState = .transcribing
        }

        let signpostID = Log.pipelineSignpost.makeSignpostID()
        let state = Log.pipelineSignpost.beginInterval("upload", id: signpostID)

        let transcribedText: String
        do {
            try Task.checkCancellation()
            // Snippet cues ride along with the dictionary terms so Whisper
            // transcribes them as written — an invented cue like "pasteclip"
            // otherwise splits into "paste clip" and is harder to match.
            let dictPrompt = await MainActor.run {
                let parts = [dictionaryStore.promptString] + snippetStore.cueTerms
                return parts.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            transcribedText = try await whisperService.transcribe(
                wavData: wavData,
                dictionaryPrompt: dictPrompt
            )
            Log.pipelineSignpost.endInterval("upload", state)
        } catch APIError.emptyTranscription {
            Log.pipelineSignpost.endInterval("upload", state)
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        } catch APIError.cancelled {
            Log.pipelineSignpost.endInterval("upload", state)
            Log.pipeline.notice("Transcription cancelled by user")
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        } catch is CancellationError {
            Log.pipelineSignpost.endInterval("upload", state)
            Log.pipeline.notice("Transcription cancelled by user")
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        } catch {
            Log.pipelineSignpost.endInterval("upload", state)
            await handleError(error)
            return
        }

        guard generation == processingGeneration, !Task.isCancelled else { return }

        // Apply all dictionary aliases locally before either the short-utterance
        // fast path or GPT refinement can change the transcription.
        let rawTranscript = await MainActor.run {
            dictionaryStore.applyCorrections(to: transcribedText)
        }

        var finalText = rawTranscript

        let refinementEnabled = await MainActor.run { settings.refinementEnabled }
        let hasSnippets = await MainActor.run { !snippetStore.snippets.isEmpty }
        // Skip refinement entirely for short clean utterances — cuts ~200-800ms
        // off quick commands like "yes", "next slide", and standalone snippet
        // cues. Snippet bodies are expanded locally after this stage, so a cue
        // never needs a model round-trip merely to substitute its body.
        let skipRefinement = Self.shouldSkipRefinement(rawTranscript: rawTranscript)
        if refinementEnabled && !skipRefinement {
            await MainActor.run {
                appState.pipelineState = .refining
            }

            let refineState = Log.pipelineSignpost.beginInterval("refine", id: signpostID)
            do {
                try Task.checkCancellation()
                let dictContext = await MainActor.run { dictionaryStore.promptString }
                let speedMode = await MainActor.run { settings.refinementSpeedMode }
                let model = Self.resolveGPTOssModel(from: speedMode)
                let effort = Self.resolveReasoningEffort(from: speedMode)
                let appAware = await MainActor.run { settings.appAwareToneEnabled }
                let targetContext = appAware ? targetWritingContext.rawValue : ""
                finalText = try await gptOssService.refine(
                    rawTranscript: rawTranscript,
                    dictionaryContext: dictContext,
                    // Bodies remain local and are expanded verbatim below. The
                    // model never receives snippet bodies or clipboard values.
                    snippetContext: "",
                    targetContext: targetContext,
                    model: model,
                    reasoningEffort: effort,
                    allowsSnippetExpansion: false
                )
            } catch APIError.cancelled, is CancellationError {
                Log.pipelineSignpost.endInterval("refine", refineState)
                Log.pipeline.notice("Refinement cancelled by user")
                await MainActor.run {
                    appState.pipelineState = .idle
                    appState.audioLevels = Array(repeating: 0, count: 15)
                    appState.recordingElapsed = 0
                }
                return
            } catch {
                Log.pipeline.notice("Refinement failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
                finalText = rawTranscript
            }
            Log.pipelineSignpost.endInterval("refine", refineState)
        }

        if Task.isCancelled {
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        }

        // Snippet substitution is deliberately local and one-pass. Running it
        // after cleanup keeps each body byte-for-byte out of the model request
        // and prevents the model from paraphrasing addresses, URLs, or templates.
        if hasSnippets {
            let textToExpand = finalText
            finalText = await MainActor.run {
                snippetStore.expandCues(in: textToExpand)
            }
        }

        // Resolve clipboard placeholders from a locally expanded body immediately
        // before insertion. Clipboard contents never leave this Mac.
        if finalText.contains("{{clipboard}}") {
            let textToResolve = finalText
            finalText = await MainActor.run {
                let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
                return textToResolve.replacingOccurrences(of: "{{clipboard}}", with: clipboard)
            }
        }

        await MainActor.run {
            appState.pipelineState = .inserting
        }

        let insertState = Log.pipelineSignpost.beginInterval("insert", id: signpostID)
        // Wait for the 100ms focus-handoff window we kicked off at the start of
        // processing; by now it has almost certainly already elapsed.
        _ = await focusHandoffTask.value
        await insertText(finalText, generation: generation)
        Log.pipelineSignpost.endInterval("insert", insertState)

        // A cancellation or newer processing pass may have arrived while the
        // target app was accepting the insertion. Let the newer generation own
        // history, statistics, sounds, and the final UI state.
        guard generation == processingGeneration, !Task.isCancelled else {
            return
        }

        let record = TranscriptionRecord(rawText: rawTranscript, refinedText: finalText, durationSeconds: duration)
        let finalOutputText = finalText
        await MainActor.run {
            historyStore.add(record)
            statsStore.record(text: finalOutputText, durationSeconds: duration)
        }

        await MainActor.run {
            appState.pipelineState = .idle
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
            appState.playSound("Glass")
        }
    }

    func cancelRecording() async {
        startGeneration &+= 1
        cancelMaxDurationStop()
        processingTask?.cancel()
        processingTask = nil
        processingGeneration &+= 1
        audioEngine.stopCapture()
        await stopElapsedTimer()
        await resumeMediaIfNeeded()
        await MainActor.run {
            appState.pipelineState = .idle
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
        }
    }

    /// Invoked by AudioEngine when the capture is forcibly terminated
    /// (device change, system sleep, buffer overflow, converter error).
    private func handleInterruption(_ reason: AudioEngineInterruption) async {
        startGeneration &+= 1
        Log.pipeline.notice("Audio capture interrupted: \(String(describing: reason), privacy: .public)")
        cancelMaxDurationStop()
        audioEngine.stopCapture()
        await stopElapsedTimer()
        await resumeMediaIfNeeded()
        let message = reason.userMessage
        await MainActor.run {
            appState.pipelineState = .error(message)
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
            appState.playSound("Basso")
        }
    }

    private func scheduleMaxDurationStop() {
        maxRecordingTask?.cancel()
        maxRecordingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Constants.Audio.maxRecordingDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopRecording()
        }
    }

    private func cancelMaxDurationStop() {
        maxRecordingTask?.cancel()
        maxRecordingTask = nil
    }

    private func startElapsedTimer() async {
        let engine = audioEngine
        let state = appState
        await MainActor.run {
            elapsedTimer.start {
                state.recordingElapsed = engine.recordingDuration
            }
        }
    }

    private func stopElapsedTimer() async {
        await MainActor.run {
            elapsedTimer.stop()
        }
    }

    private func insertText(_ text: String, generation: Int) async {
        // Focus-handoff wait is now overlapped with upload + refine in
        // `processCapturedAudio`, so by the time we reach here the target app
        // has regained focus. No fresh sleep needed.

        guard generation == processingGeneration else {
            Log.pipeline.notice("Skipped stale insertion generation")
            return
        }
        guard !insertionInFlight else {
            Log.pipeline.notice("Skipped insertion because another insertion is in flight")
            return
        }
        insertionInFlight = true
        defer { insertionInFlight = false }

        let insertionResult = await accessibilityInserter.insert(text)
        let diagnostics = insertionResult.diagnostics
        Log.pipeline.notice(
            "Insertion AX result (bundle=\(diagnostics.frontmostBundleID, privacy: .public), status=\(insertionResult.status.rawValue, privacy: .public), method=\(diagnostics.attemptedMethod ?? "none", privacy: .public), polls=\(diagnostics.verificationPolls, privacy: .public), policySkip=\(diagnostics.skippedForBundlePolicy, privacy: .public))"
        )

        if insertionResult.status.preventsFallback {
            await MainActor.run {
                AccessibilityInserter.announceInsertionSuccess()
            }
            return
        }

        guard generation == processingGeneration else {
            Log.pipeline.notice("Skipped clipboard fallback for stale insertion generation")
            return
        }

        // Clipboard is selected up front for browser/Electron bundle policy, or
        // used only when AX definitively failed before accepting any write.
        let pasteOutcome = await clipboardPaster.paste(text, diagnostics: diagnostics)

        switch pasteOutcome {
        case .success:
            await MainActor.run {
                AccessibilityInserter.announceInsertionSuccess()
            }
        case .skippedSecureField, .postEventDenied:
            await MainActor.run {
                Self.presentInsertionFailureAlert(text: text, outcome: pasteOutcome)
            }
        }
    }

    @MainActor
    private static func presentInsertionFailureAlert(text: String, outcome: ClipboardPasteOutcome) {
        let alert = NSAlert()
        switch outcome {
        case .skippedSecureField:
            alert.messageText = "Couldn't insert text"
            alert.informativeText = "Dictify won't paste into a password or secure field. Your transcription is copied below — paste it manually if needed."
        case .postEventDenied:
            alert.messageText = "Couldn't insert text"
            alert.informativeText = "macOS blocked the paste keystroke. Your transcription is copied below — paste it manually with ⌘V."
        case .success:
            return
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    /// Maps the user-facing speed mode to the Groq model name.
    private static func resolveGPTOssModel(from mode: String) -> String {
        switch mode {
        case "fast": return Constants.API.gptOssModelFast
        default: return Constants.API.gptOssModelQuality
        }
    }

    /// Fast prioritizes speed, so use shallower reasoning; Quality keeps medium.
    private static func resolveReasoningEffort(from mode: String) -> String {
        mode == "fast" ? "low" : "medium"
    }

    /// Refinement is only useful when there are fillers, self-corrections, or
    /// long sentences to punctuate. For tiny commands, Whisper's raw output is
    /// already fine — skipping saves the entire GPT-OSS round-trip.
    private static func shouldSkipRefinement(rawTranscript: String) -> Bool {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split { $0.isWhitespace }.count
        guard wordCount <= 6 else { return false }

        let lower = trimmed.lowercased()
        let fillerMarkers = [" um ", " uh ", " like ", " you know ", "i mean", "kind of", "sort of"]
        for marker in fillerMarkers where lower.contains(marker) {
            return false
        }
        // No dictation-command words → nothing for GPT-OSS to convert.
        let commands = ["comma", "period", "question mark", "exclamation point", "new line", "new paragraph"]
        for c in commands where lower.contains(c) {
            return false
        }
        return true
    }

    @MainActor
    private static func focusedWindowTitle(for pid: pid_t?) -> String? {
        guard let pid, pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }

        let window = windowValue as! AXUIElement
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success else { return nil }
        return titleValue as? String
    }

    static func classifyWritingContext(
        bundleID: String,
        windowTitle: String?
    ) -> TargetWritingContext {
        let bundle = bundleID.lowercased()
        let title = windowTitle?.lowercased() ?? ""

        let nativeEmailBundles: Set<String> = [
            "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac"
        ]
        let nativeChatBundles: Set<String> = [
            "com.tinyspeck.slackmacgap", "com.hnc.discord", "com.electron.whatsapp",
            "whatsapp", "com.microsoft.teams", "com.microsoft.teams2"
        ]
        let nativeDocumentBundles: Set<String> = [
            "com.apple.pages", "com.apple.textedit", "com.apple.notes",
            "com.microsoft.word", "notion.id"
        ]
        let nativeCodeBundles: Set<String> = [
            "com.apple.dt.xcode", "com.microsoft.vscode", "com.apple.terminal",
            "com.googlecode.iterm2", "dev.warp.warp-stable"
        ]

        if nativeEmailBundles.contains(bundle) { return .email }
        if nativeChatBundles.contains(bundle) { return .chat }
        if nativeDocumentBundles.contains(bundle) { return .document }
        if nativeCodeBundles.contains(bundle) { return .code }

        guard browserBundleIDs.contains(bundleID) else { return .neutral }
        if ["gmail", "google mail", "outlook", "inbox"].contains(where: title.contains) {
            return .email
        }
        if ["slack", "discord", "teams", "whatsapp", "telegram"].contains(where: title.contains) {
            return .chat
        }
        if ["google docs", "google sheets", "notion", "confluence"].contains(where: title.contains) {
            return .document
        }
        if ["github", "stack overflow", "replit", "codesandbox"].contains(where: title.contains) {
            return .code
        }
        return .neutral
    }

    private func handleError(_ error: Error) async {
        // Cancellation is benign — don't surface as a user-visible error.
        if case APIError.cancelled = error {
            Log.pipeline.notice("Request cancelled — returning to idle")
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        }

        let message: String
        if let apiError = error as? APIError {
            message = apiError.localizedDescription
        } else {
            message = error.localizedDescription
        }
        Log.pipeline.error("Pipeline error: \(message, privacy: .public)")

        await MainActor.run {
            appState.pipelineState = .error(message)
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
            appState.playSound("Basso")
        }
    }
}
