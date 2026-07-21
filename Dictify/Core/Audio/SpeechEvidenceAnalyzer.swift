import Foundation

/// Lightweight, local speech-evidence gate for Dictify's 16 kHz Float32 PCM.
/// It deliberately runs before WAV encoding and network upload so a silent
/// hotkey activation cannot be primed into text by Whisper prompts.
enum SpeechEvidenceAnalyzer {
    struct Result: Sendable, Equatable {
        let hasSpeech: Bool
        let totalVoicedMilliseconds: Int
        let longestVoicedRunMilliseconds: Int
        let thresholdDBFS: Float
    }

    private static let sampleRate = 16_000
    private static let frameMilliseconds = 20
    private static let frameSamples = sampleRate * frameMilliseconds / 1_000
    private static let requiredTotalVoicedMilliseconds = 160
    private static let requiredConsecutiveVoicedMilliseconds = 80

    static func analyze(pcmData: Data) -> Result {
        let sampleCount = pcmData.count / MemoryLayout<Float>.size
        guard sampleCount >= frameSamples else {
            return Result(
                hasSpeech: false,
                totalVoicedMilliseconds: 0,
                longestVoicedRunMilliseconds: 0,
                thresholdDBFS: -50
            )
        }

        let frameLevels: [Float] = pcmData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float.self)
            let completeFrameCount = samples.count / frameSamples
            return (0..<completeFrameCount).map { frameIndex in
                let start = frameIndex * frameSamples
                var sumSquares: Float = 0
                for sampleIndex in start..<(start + frameSamples) {
                    let sample = samples[sampleIndex]
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(frameSamples))
                return 20 * log10(max(rms, 0.000_001))
            }
        }

        guard !frameLevels.isEmpty else {
            return Result(
                hasSpeech: false,
                totalVoicedMilliseconds: 0,
                longestVoicedRunMilliseconds: 0,
                thresholdDBFS: -50
            )
        }

        // The quietest fifth of frames approximates the room/microphone floor.
        // Keep the threshold between -50 and -20 dBFS. That preserves softly
        // spoken short words in quiet rooms while allowing a loud, steady fan
        // or room floor to raise the threshold instead of becoming "speech".
        let sortedLevels = frameLevels.sorted()
        let noiseIndex = min(sortedLevels.count - 1, sortedLevels.count / 5)
        let noiseFloor = sortedLevels[noiseIndex]
        let threshold = min(-20, max(-50, noiseFloor + 10))

        var voicedFrames = 0
        var currentRun = 0
        var longestRun = 0
        for level in frameLevels {
            if level >= threshold {
                voicedFrames += 1
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }

        let totalMilliseconds = voicedFrames * frameMilliseconds
        let longestMilliseconds = longestRun * frameMilliseconds
        return Result(
            hasSpeech: totalMilliseconds >= requiredTotalVoicedMilliseconds
                && longestMilliseconds >= requiredConsecutiveVoicedMilliseconds,
            totalVoicedMilliseconds: totalMilliseconds,
            longestVoicedRunMilliseconds: longestMilliseconds,
            thresholdDBFS: threshold
        )
    }
}
