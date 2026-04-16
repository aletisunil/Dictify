@preconcurrency import AVFoundation
import Accelerate

final class AudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var audioBuffer = Data()
    private var recordingStartTime: Date?
    private var tapInstalled = false
    private let bufferLock = NSLock()

    private let targetSampleRate: Double = Constants.Audio.sampleRate
    private let targetChannels: AVAudioChannelCount = AVAudioChannelCount(Constants.Audio.channels)

    var isRecording: Bool { engine.isRunning && tapInstalled }

    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func startCapture(levelCallback: @escaping @MainActor @Sendable ([Float]) -> Void) throws {
        guard !isRecording else {
            throw AudioEngineError.alreadyRecording
        }

        bufferLock.lock()
        audioBuffer = Data()
        audioBuffer.reserveCapacity(Int(targetSampleRate * Double(Constants.Audio.maxRecordingDuration)) * MemoryLayout<Float>.size)
        bufferLock.unlock()
        recordingStartTime = Date()

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

        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(
                max(1, ceil(Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate))
            )
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, let channelData = convertedBuffer.floatChannelData {
                let frameLength = Int(convertedBuffer.frameLength)
                let samples = channelData[0]
                let byteCount = frameLength * MemoryLayout<Float>.size

                self.bufferLock.lock()
                samples.withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
                    self.audioBuffer.append(bytes, count: byteCount)
                }
                self.bufferLock.unlock()

                let levels = self.computeLevels(from: samples, count: frameLength)
                Task { @MainActor in
                    levelCallback(levels)
                }
            }
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            recordingStartTime = nil
            throw error
        }
    }

    @discardableResult
    func stopCapture() -> Data {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }

        bufferLock.lock()
        let result = audioBuffer
        audioBuffer = Data()
        bufferLock.unlock()
        recordingStartTime = nil
        return result
    }

    private func computeLevels(from samples: UnsafePointer<Float>, count: Int, barCount: Int = 15) -> [Float] {
        guard count > 0 else { return Array(repeating: 0, count: barCount) }

        let chunkSize = max(count / barCount, 1)
        var levels = Array(repeating: Float(0), count: barCount)

        for i in 0..<barCount {
            let start = i * chunkSize
            let end = min(start + chunkSize, count)
            guard start < end else {
                continue
            }

            var rms: Float = 0
            vDSP_measqv(samples.advanced(by: start), 1, &rms, vDSP_Length(end - start))
            rms = sqrtf(rms)

            let normalized = min(rms * 5.0, 1.0)
            levels[i] = normalized
        }

        return levels
    }

    deinit {
        stopCapture()
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
