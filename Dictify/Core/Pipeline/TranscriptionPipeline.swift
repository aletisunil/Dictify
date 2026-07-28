import AppKit
import Foundation
import os

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
    /// Monotonic token identifying the latest start/stop/cancel/interruption
    /// transition. `startRecording` snapshots it and re-checks after suspension
    /// points: a mismatch means another transition interleaved via actor
    /// reentrancy and now owns the pipeline state.
    private var startGeneration = 0
    /// Inputs `startRecording` needs from the main actor, snapshotted in a
    /// single hop so the hotkey→capture path pays one context switch, not four.
    private struct StartContext {
        let frontmostAppName: String?
        let preferredDeviceUID: String
        let pauseMediaDuringDictation: Bool
    }
    /// True when we paused system media for the current dictation, so we only
    /// resume what we actually paused.
    private var didPauseMedia = false
    /// Name of the app focused when this dictation started — the app the text
    /// will be inserted into. Snapshotted at start because focus can move by
    /// insertion time. Used to tune refinement tone when app-aware tone is on.
    private var frontmostAppName: String?
    /// Browsers whose window is a web app, not a native app — the bundle name
    /// tells us nothing about the register, so tone stays neutral for these.
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

                // Snapshot the app being dictated into now — focus may move to
                // Dictify's UI or elsewhere before insertion time. NSWorkspace
                // is main-thread only. Browsers are left nil: the real target
                // is whatever web app is loaded, which the app name can't
                // reveal, so refinement stays neutral there.
                let app = NSWorkspace.shared.frontmostApplication
                let appName: String?
                if let bundleID = app?.bundleIdentifier, Self.browserBundleIDs.contains(bundleID) {
                    appName = nil
                } else {
                    appName = app?.localizedName
                }
                return StartContext(
                    frontmostAppName: appName,
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

        frontmostAppName = context.frontmostAppName

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
        processingTask = Task { [weak self] in
            await self?.processCapturedAudio(pcmData: pcmData, duration: duration)
        }
    }

    /// Resume system media iff we paused it for this dictation. Idempotent.
    private func resumeMediaIfNeeded() async {
        guard didPauseMedia else { return }
        didPauseMedia = false
        await mediaController.resumeIfWePaused(true)
    }

    private func processCapturedAudio(pcmData: Data, duration: TimeInterval) async {
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

        let rawTranscript: String
        do {
            try Task.checkCancellation()
            // Snippet cues ride along with the dictionary terms so Whisper
            // transcribes them as written — an invented cue like "pasteclip"
            // otherwise splits into "paste clip" and is harder to match.
            let dictPrompt = await MainActor.run {
                let parts = [dictionaryStore.promptString] + snippetStore.cueTerms
                return parts.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            rawTranscript = try await whisperService.transcribe(
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

        var finalText = rawTranscript
        var refinementSucceeded = false

        let refinementEnabled = await MainActor.run { settings.refinementEnabled }
        let hasSnippets = await MainActor.run { !snippetStore.snippets.isEmpty }
        // Skip refinement entirely for short clean utterances — cuts ~200-800ms
        // off quick commands like "yes", "next slide", "ok sounds good". With
        // snippets, stay on the refinement path only when a cue plausibly
        // appears in the transcript: short junk transcripts (Whisper
        // hallucinating on silence/noise) otherwise reach GPT-OSS with nothing
        // to clean, and it can parrot a few-shot exemplar into the output. The
        // local matcher already catches split/reformatted cues ("paste clip"),
        // so only a badly misheard cue inside a ≤6-word utterance loses model
        // expansion — far cheaper than inserting hallucinated text.
        var skipRefinement = Self.shouldSkipRefinement(rawTranscript: rawTranscript)
        if skipRefinement && hasSnippets {
            let cuePresent = await MainActor.run { snippetStore.containsCue(in: rawTranscript) }
            skipRefinement = !cuePresent
        }
        if refinementEnabled && !skipRefinement {
            await MainActor.run {
                appState.pipelineState = .refining
            }

            let refineState = Log.pipelineSignpost.beginInterval("refine", id: signpostID)
            do {
                try Task.checkCancellation()
                let dictContext = await MainActor.run { dictionaryStore.promptString }
                // Built on the main actor: resolves {{date}}/{{time}}/{{clipboard}}
                // before the prompt is sent. Empty string when no snippets exist.
                let snippetCtx = await MainActor.run { snippetStore.snippetContext() }
                let speedMode = await MainActor.run { settings.refinementSpeedMode }
                let model = Self.resolveGPTOssModel(from: speedMode)
                let effort = Self.resolveReasoningEffort(from: speedMode)
                let appAware = await MainActor.run { settings.appAwareToneEnabled }
                let targetApp = appAware ? (frontmostAppName ?? "") : ""
                finalText = try await gptOssService.refine(
                    rawTranscript: rawTranscript,
                    dictionaryContext: dictContext,
                    snippetContext: snippetCtx,
                    targetAppName: targetApp,
                    model: model,
                    reasoningEffort: effort
                )
                refinementSucceeded = true
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

        // Snippet expansion: the refinement model handles misheard/reformatted
        // cues (SnippetStore.snippetContext / GPTOssService); this deterministic
        // pass catches cues the model left literal — small models skip them —
        // and covers the refinement-disabled/failed paths. After successful
        // refinement the text may already contain spliced bodies, so cues that
        // also occur inside a snippet body are skipped there — expanding them
        // again would duplicate the body.
        if hasSnippets {
            let textToExpand = finalText
            let skipEmbedded = refinementSucceeded
            finalText = await MainActor.run {
                snippetStore.expandCues(in: textToExpand, skippingCuesEmbeddedInBodies: skipEmbedded)
            }
        }

        // The refinement prompt carries {{clipboard}} as a literal placeholder —
        // clipboard contents never leave the Mac — so resolve whatever the model
        // (or a body spliced above) left behind, locally, right before insertion.
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
        await insertText(finalText)
        Log.pipelineSignpost.endInterval("insert", insertState)

        let record = TranscriptionRecord(rawText: rawTranscript, refinedText: finalText, durationSeconds: duration)
        let transcribedText = finalText
        await MainActor.run {
            historyStore.add(record)
            statsStore.record(text: transcribedText, durationSeconds: duration)
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

    private func insertText(_ text: String) async {
        // Focus-handoff wait is now overlapped with upload + refine in
        // `processCapturedAudio`, so by the time we reach here the target app
        // has regained focus. No fresh sleep needed.

        let insertionResult = await accessibilityInserter.insert(text)

        if insertionResult.inserted {
            await MainActor.run {
                AccessibilityInserter.announceInsertionSuccess()
            }
            return
        }

        // Fallback to clipboard paste — works with Electron apps (WhatsApp, Slack, etc.)
        let paster = clipboardPaster
        let diagnostics = insertionResult.diagnostics
        let pasteOutcome: ClipboardPasteOutcome = await MainActor.run {
            paster.paste(text, diagnostics: diagnostics)
        }

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
