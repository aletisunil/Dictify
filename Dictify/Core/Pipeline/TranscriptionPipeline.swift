import Foundation

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

    private nonisolated(unsafe) var elapsedTimer: Timer?
    private var maxRecordingTask: Task<Void, Never>?

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
    }

    func startRecording() async {
        guard !audioEngine.isRecording else {
            return
        }
        let canStart = await MainActor.run { appState.pipelineState == .idle }
        guard canStart else {
            return
        }

        await MainActor.run {
            appState.recordingElapsed = 0
        }

        do {
            try audioEngine.startCapture { [weak appState] levels in
                appState?.audioLevels = levels
            }
            scheduleMaxDurationStop()

            await MainActor.run {
                appState.pipelineState = .recording
                appState.playSound("Tink")
                self.startElapsedTimer()
            }
        } catch {
            audioEngine.stopCapture()
            cancelMaxDurationStop()
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
            await MainActor.run {
                stopElapsedTimer()
                if case .recording = appState.pipelineState {
                    appState.pipelineState = .idle
                    appState.audioLevels = Array(repeating: 0, count: 15)
                    appState.recordingElapsed = 0
                }
            }
            return
        }

        cancelMaxDurationStop()

        await MainActor.run {
            stopElapsedTimer()
        }

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

        let wavData = WAVEncoder.encode(pcmData: pcmData)

        // Transcription
        await MainActor.run {
            appState.pipelineState = .transcribing
        }

        let rawTranscript: String
        do {
            let dictPrompt = await MainActor.run { dictionaryStore.promptString }
            rawTranscript = try await whisperService.transcribe(wavData: wavData, dictionaryPrompt: dictPrompt)
        } catch APIError.emptyTranscription {
            // No speech detected — silently dismiss instead of showing an error
            await MainActor.run {
                appState.pipelineState = .idle
                appState.audioLevels = Array(repeating: 0, count: 15)
                appState.recordingElapsed = 0
            }
            return
        } catch {
            await handleError(error)
            return
        }

        // Refinement
        var finalText = rawTranscript

        let refinementEnabled = await MainActor.run { settings.refinementEnabled }
        if refinementEnabled {
            await MainActor.run {
                appState.pipelineState = .refining
            }

            do {
                let context = await MainActor.run { snippetStore.snippetContext }
                finalText = try await llamaService.refine(rawTranscript: rawTranscript, snippetContext: context)
            } catch {
                // If refinement fails, use raw transcript
                finalText = rawTranscript
            }
        }

        // Text Insertion
        await MainActor.run {
            appState.pipelineState = .inserting
        }

        await insertText(finalText)

        // Save to history
        let record = TranscriptionRecord(rawText: rawTranscript, refinedText: finalText, durationSeconds: duration)
        let transcribedText = finalText
        await MainActor.run {
            historyStore.add(record)
            statsStore.record(text: transcribedText, durationSeconds: duration)
        }

        // Done
        await MainActor.run {
            appState.pipelineState = .done
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
            appState.playSound("Glass")
        }

        try? await Task.sleep(nanoseconds: UInt64(Constants.UI.doneDismissDelay * 1_000_000_000))

        await MainActor.run {
            if case .done = appState.pipelineState {
                appState.pipelineState = .idle
            }
        }
    }

    func cancelRecording() async {
        cancelMaxDurationStop()
        audioEngine.stopCapture()
        await MainActor.run {
            stopElapsedTimer()
            appState.pipelineState = .idle
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
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

    @MainActor
    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak appState, weak audioEngine] _ in
            Task { @MainActor in
                appState?.recordingElapsed = audioEngine?.recordingDuration ?? 0
            }
        }
    }

    @MainActor
    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func insertText(_ text: String) async {
        // Small delay to ensure the target app has regained focus after fn key release
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let insertionResult = await accessibilityInserter.insert(text)

        if !insertionResult.inserted {
            // Fallback to clipboard paste — works with Electron apps (WhatsApp, Slack, etc.)
            await MainActor.run {
                clipboardPaster.paste(text, diagnostics: insertionResult.diagnostics)
            }
        }
    }

    private func handleError(_ error: Error) async {
        let message: String
        if let apiError = error as? APIError {
            message = apiError.localizedDescription
        } else {
            message = error.localizedDescription
        }

        await MainActor.run {
            appState.pipelineState = .error(message)
            appState.audioLevels = Array(repeating: 0, count: 15)
            appState.recordingElapsed = 0
            appState.playSound("Basso")
        }
    }
}
