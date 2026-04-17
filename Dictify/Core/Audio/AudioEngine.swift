@preconcurrency import AVFoundation
import Accelerate
import AppKit
import os

/// Reason why an in-flight recording was forcibly terminated.
///
/// The pipeline surfaces these to the user as recoverable errors — none are crashes.
enum AudioEngineInterruption: Sendable, Equatable {
    case deviceChanged
    case systemSleep
    case bufferOverflow
    case conversionFailed(String)

    var userMessage: String {
        switch self {
        case .deviceChanged: return "Audio device changed. Please try again."
        case .systemSleep: return "Recording interrupted by sleep."
        case .bufferOverflow: return "Recording too long — please try again."
        case .conversionFailed: return "Audio conversion failed. Please try again."
        }
    }
}

final class AudioEngine: @unchecked Sendable {
    // Serial queue guarding *all* mutable state below. Never block the audio
    // thread on it for long — only short `sync` appends + state reads.
    private let stateQueue = DispatchQueue(label: "com.dictify.audioengine.state")

    private let engine = AVAudioEngine()

    // --- state guarded by stateQueue ---
    private var audioBuffer = Data()
    private var recordingStartTime: Date?
    private var tapInstalled = false
    private var currentConverter: AVAudioConverter?
    private var currentTargetFormat: AVAudioFormat?
    private var currentInputSampleRate: Double = 0
    private var overflowed = false
    // ------------------------------------

    private var configObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var interruptionHandler: (@Sendable (AudioEngineInterruption) -> Void)?

    private let targetSampleRate: Double = Constants.Audio.sampleRate
    private let targetChannels: AVAudioChannelCount = AVAudioChannelCount(Constants.Audio.channels)

    /// Belt-and-braces cap on captured PCM. The primary safeguard is the
    /// `maxRecordingDuration` timer in `TranscriptionPipeline`; this protects
    /// against a runaway tap callback if the timer is delayed or leaks.
    private static let maxBufferBytes: Int = 50 * 1024 * 1024

    var isRecording: Bool {
        let tapped = stateQueue.sync { tapInstalled }
        return tapped && engine.isRunning
    }

    var recordingDuration: TimeInterval {
        stateQueue.sync {
            guard let start = recordingStartTime else { return 0 }
            return Date().timeIntervalSince(start)
        }
    }

    /// Begin capture. `onInterruption` is invoked (on main) when the engine is
    /// torn down due to a device/route change, system sleep, buffer overflow,
    /// or converter error. Callers should treat it as a terminal error signal
    /// for the current recording.
    func startCapture(
        levelCallback: @escaping @MainActor @Sendable ([Float]) -> Void,
        onInterruption: @escaping @Sendable (AudioEngineInterruption) -> Void
    ) throws {
        let already = stateQueue.sync { tapInstalled }
        guard !already else { throw AudioEngineError.alreadyRecording }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioEngineError.inputUnavailable
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioEngineError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioEngineError.converterCreationFailed
        }

        stateQueue.sync {
            audioBuffer = Data()
            audioBuffer.reserveCapacity(
                Int(targetSampleRate * Double(Constants.Audio.maxRecordingDuration)) * MemoryLayout<Float>.size
            )
            recordingStartTime = Date()
            currentConverter = converter
            currentTargetFormat = targetFormat
            currentInputSampleRate = inputFormat.sampleRate
            overflowed = false
        }
        interruptionHandler = onInterruption

        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, levelCallback: levelCallback)
        }
        stateQueue.sync { tapInstalled = true }

        installObservers()

        do {
            try engine.start()
        } catch {
            // Roll back partial state; do not fire interruption handler for a
            // start failure — the throw is the signal.
            inputNode.removeTap(onBus: 0)
            removeObservers()
            stateQueue.sync {
                tapInstalled = false
                recordingStartTime = nil
                currentConverter = nil
                currentTargetFormat = nil
                currentInputSampleRate = 0
                audioBuffer = Data()
            }
            interruptionHandler = nil
            throw error
        }
    }

    private func handleTap(
        buffer: AVAudioPCMBuffer,
        levelCallback: @escaping @MainActor @Sendable ([Float]) -> Void
    ) {
        let (converter, targetFormat, inputSampleRate, isOverflowed) = stateQueue.sync {
            (currentConverter, currentTargetFormat, currentInputSampleRate, overflowed)
        }
        guard !isOverflowed else { return }
        guard let converter = converter,
              let targetFormat = targetFormat,
              inputSampleRate > 0 else { return }

        let frameCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * self.targetSampleRate / inputSampleRate))
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            Log.audio.error("Audio converter failed: \(error.localizedDescription, privacy: .public)")
            fireInterruption(.conversionFailed(error.localizedDescription))
            return
        }

        guard let channelData = converted.floatChannelData else { return }
        let frameLength = Int(converted.frameLength)
        guard frameLength > 0 else { return }

        let byteCount = frameLength * MemoryLayout<Float>.size
        let samples = channelData[0]

        var didOverflow = false
        stateQueue.sync {
            let projected = audioBuffer.count + byteCount
            if projected > AudioEngine.maxBufferBytes {
                overflowed = true
                didOverflow = true
                return
            }
            samples.withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
                audioBuffer.append(bytes, count: byteCount)
            }
        }

        if didOverflow {
            Log.audio.error("Audio buffer exceeded \(AudioEngine.maxBufferBytes) bytes — stopping capture")
            fireInterruption(.bufferOverflow)
            return
        }

        let levels = computeLevels(from: samples, count: frameLength)
        Task { @MainActor in
            levelCallback(levels)
        }
    }

    private func fireInterruption(_ reason: AudioEngineInterruption) {
        // Always deliver on main so the pipeline can mutate UI state safely.
        let handler = interruptionHandler
        DispatchQueue.main.async {
            handler?(reason)
        }
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        configObserver = nc.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Log.audio.notice("AVAudioEngine configuration change — tearing down capture")
            self.tearDown(reason: .deviceChanged)
        }

        let wsNC = NSWorkspace.shared.notificationCenter
        sleepObserver = wsNC.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Log.audio.notice("System will sleep — tearing down capture")
            self.tearDown(reason: .systemSleep)
        }
    }

    private func removeObservers() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
    }

    /// Force-stop the engine and notify the pipeline with `reason`.
    private func tearDown(reason: AudioEngineInterruption) {
        let tapped = stateQueue.sync { tapInstalled }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        stateQueue.sync {
            tapInstalled = false
        }
        removeObservers()

        let handler = interruptionHandler
        handler?(reason)
    }

    @discardableResult
    func stopCapture() -> Data {
        let tapped = stateQueue.sync { tapInstalled }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }
        removeObservers()
        interruptionHandler = nil

        return stateQueue.sync {
            tapInstalled = false
            let result = audioBuffer
            audioBuffer = Data()
            recordingStartTime = nil
            currentConverter = nil
            currentTargetFormat = nil
            currentInputSampleRate = 0
            overflowed = false
            return result
        }
    }

    private func computeLevels(from samples: UnsafePointer<Float>, count: Int, barCount: Int = 15) -> [Float] {
        guard count > 0 else { return Array(repeating: 0, count: barCount) }

        let chunkSize = max(count / barCount, 1)
        var levels = Array(repeating: Float(0), count: barCount)

        for i in 0..<barCount {
            let start = i * chunkSize
            let end = min(start + chunkSize, count)
            guard start < end else { continue }

            var rms: Float = 0
            vDSP_measqv(samples.advanced(by: start), 1, &rms, vDSP_Length(end - start))
            rms = sqrtf(rms)

            let normalized = min(rms * 5.0, 1.0)
            levels[i] = normalized
        }

        return levels
    }

    deinit {
        removeObservers()
        if engine.isRunning { engine.stop() }
    }
}

enum AudioEngineError: Error, LocalizedError {
    case alreadyRecording
    case formatCreationFailed
    case converterCreationFailed
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Recording is already in progress"
        case .formatCreationFailed: return "Failed to create target audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        case .inputUnavailable: return "Microphone input is unavailable"
        }
    }
}
