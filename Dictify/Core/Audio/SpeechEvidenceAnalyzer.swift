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

        // The quietest fifth approximates the room/microphone floor when the
        // capture has meaningful level variation. A nearly uniform, moderate
        // signal has no trustworthy noise-only population: it may be continuous
        // speech. Fail open for that case instead of raising the threshold above
        // every frame and silently discarding the dictation. Very quiet uniform
        // signals still use the adaptive threshold and remain rejected.
        let sortedLevels = frameLevels.sorted()
        let lowIndex = min(sortedLevels.count - 1, sortedLevels.count / 5)
        let highIndex = min(sortedLevels.count - 1, sortedLevels.count * 4 / 5)
        let lowLevel = sortedLevels[lowIndex]
        let highLevel = sortedLevels[highIndex]
        let dynamicRange = highLevel - lowLevel
        let threshold: Float
        if dynamicRange < 6, highLevel >= -32 {
            threshold = -32
        } else {
            threshold = min(-20, max(-50, lowLevel + 6))
        }

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
