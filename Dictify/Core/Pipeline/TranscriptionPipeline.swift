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
    private let llamaService: LlamaService
    private let accessibilityInserter: AccessibilityInserter
    private let clipboardPaster: ClipboardPaster
    private let dictionaryStore: DictionaryStore
    private let snippetStore: SnippetStore
    private let historyStore: HistoryStore
    private let statsStore: StatsStore
    private let settings: DictifySettings
    private let elapsedTimer: ElapsedTimer

    private var maxRecordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?

    init(appState: AppState,
         keychainManager: KeychainManager,
         dictionaryStore: DictionaryStore,
         snippetStore: SnippetStore,
         historyStore: HistoryStore,
         statsStore: StatsStore) {
        self.appState = appState
        self.audioEngine = AudioEngine()
        self.groqClient = GroqClient(keychainManager: keychainManager)
        self.whisperService = WhisperService(client: groqClient)
        self.llamaService = LlamaService(client: groqClient)
        self.accessibilityInserter = AccessibilityInserter()
        self.clipboardPaster = ClipboardPaster()
        self.dictionaryStore = dictionaryStore
        self.snippetStore = snippetStore
        self.historyStore = historyStore
        self.statsStore = statsStore
        self.settings = appState.settings
        self.elapsedTimer = MainActor.assumeIsolated { ElapsedTimer() }
    }

    func startRecording() async {
        guard !audioEngine.isRecording else {
            return
        }
        let canStart = await MainActor.run {
            switch appState.pipelineState {
            case .idle, .error:
                // Reset a stale error (e.g. 400 from the previous attempt) so
                // the next activation isn't blocked.
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
                return true
            default:
                return false
            }
        }
        guard canStart else {
            return
        }

        let preferredDeviceUID = await MainActor.run { settings.selectedInputDeviceUID }

        do {
            try audioEngine.startCapture(
                preferredDeviceUID: preferredDeviceUID,
                levelCallback: { [weak appState] levels in
                    appState?.audioLevels = levels
                },
                onInterruption: { [weak self] reason in
                    guard let self = self else { return }
                    Task { await self.handleInterruption(reason) }
                }
            )
            scheduleMaxDurationStop()

            await MainActor.run {
                appState.pipelineState = .recording
                appState.playSound("Tink")
            }
            await startElapsedTimer()
        } catch {
            audioEngine.stopCapture()
            cancelMaxDurationStop()
            Log.pipeline.error("Failed to start capture: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                appState.pipelineState = .error("Microphone unavailable")
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
                appState.playSound("Basso")
            }
        }
    }

    func stopRecording() async {
        guard audioEngine.isRecording else {
            await stopElapsedTimer()
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
            let dictPrompt = await MainActor.run { dictionaryStore.promptString }
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

        let refinementEnabled = await MainActor.run { settings.refinementEnabled }
        // Skip refinement entirely for short clean utterances — cuts ~200-800ms
        // off quick commands like "yes", "next slide", "ok sounds good".
        let skipRefinement = Self.shouldSkipRefinement(rawTranscript: rawTranscript)
        if refinementEnabled && !skipRefinement {
            await MainActor.run {
                appState.pipelineState = .refining
            }

            let refineState = Log.pipelineSignpost.beginInterval("refine", id: signpostID)
            do {
                try Task.checkCancellation()
                let context = await MainActor.run { snippetStore.snippetContext }
                let speedMode = await MainActor.run { settings.refinementSpeedMode }
                let model = Self.resolveLlamaModel(from: speedMode)
                finalText = try await llamaService.refine(
                    rawTranscript: rawTranscript,
                    snippetContext: context,
                    model: model
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
        cancelMaxDurationStop()
        processingTask?.cancel()
        processingTask = nil
        audioEngine.stopCapture()
        await stopElapsedTimer()
        await MainActor.run {
            appState.pipelineState = .idle
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
        }
    }

    /// Invoked by AudioEngine when the capture is forcibly terminated
    /// (device change, system sleep, buffer overflow, converter error).
    private func handleInterruption(_ reason: AudioEngineInterruption) async {
        Log.pipeline.notice("Audio capture interrupted: \(String(describing: reason), privacy: .public)")
        cancelMaxDurationStop()
        audioEngine.stopCapture()
        await stopElapsedTimer()
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
    private static func resolveLlamaModel(from mode: String) -> String {
        switch mode {
        case "fast": return Constants.API.llamaModelFast
        default: return Constants.API.llamaModelQuality
        }
    }

    /// Refinement is only useful when there are fillers, self-corrections, or
    /// long sentences to punctuate. For tiny commands, Whisper's raw output is
    /// already fine — skipping saves the entire Llama round-trip.
    private static func shouldSkipRefinement(rawTranscript: String) -> Bool {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split { $0.isWhitespace }.count
        guard wordCount <= 6 else { return false }

        let lower = trimmed.lowercased()
        let fillerMarkers = [" um ", " uh ", " like ", " you know ", "i mean", "kind of", "sort of"]
        for marker in fillerMarkers where lower.contains(marker) {
            return false
        }
        // No dictation-command words → nothing for Llama to convert.
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
