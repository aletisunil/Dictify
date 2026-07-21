import Foundation
import XCTest
@testable import Dictify

@MainActor
final class ReliabilityTests: XCTestCase {
    func testDigitalSilenceHasNoSpeechEvidence() {
        let samples = [Float](repeating: 0, count: 16_000)
        let result = SpeechEvidenceAnalyzer.analyze(pcmData: pcmData(samples))

        XCTAssertFalse(result.hasSpeech)
        XCTAssertEqual(result.totalVoicedMilliseconds, 0)
    }

    func testShortSpokenToneHasSpeechEvidence() {
        var samples = [Float](repeating: 0, count: 16_000)
        for index in 4_000..<7_200 {
            samples[index] = 0.06 * sin(Float(index) * 0.19)
        }

        let result = SpeechEvidenceAnalyzer.analyze(pcmData: pcmData(samples))

        XCTAssertTrue(result.hasSpeech)
        XCTAssertGreaterThanOrEqual(result.totalVoicedMilliseconds, 160)
        XCTAssertGreaterThanOrEqual(result.longestVoicedRunMilliseconds, 80)
    }

    func testSteadyRoomNoiseFanAndMusicLikeToneAreRejected() {
        let roomNoise = deterministicNoise(sampleCount: 16_000, amplitude: 0.012)
        XCTAssertFalse(SpeechEvidenceAnalyzer.analyze(pcmData: pcmData(roomNoise)).hasSpeech)

        let fan = (0..<16_000).map { index in
            Float(0.018 * sin(Double(index) * 0.031))
        }
        XCTAssertFalse(SpeechEvidenceAnalyzer.analyze(pcmData: pcmData(fan)).hasSpeech)

        let sustainedMusicLikeTone = (0..<16_000).map { index in
            Float(
                0.025 * sin(Double(index) * 0.11)
                    + 0.012 * sin(Double(index) * 0.23)
            )
        }
        XCTAssertFalse(
            SpeechEvidenceAnalyzer.analyze(pcmData: pcmData(sustainedMusicLikeTone)).hasSpeech
        )
    }

    func testKeyboardTapsDoNotMeetMinimumVoicedDuration() {
        var samples = [Float](repeating: 0, count: 16_000)
        let tap = deterministicNoise(sampleCount: 240, amplitude: 0.2)
        for start in [2_000, 7_000, 12_000] {
            for offset in tap.indices {
                samples[start + offset] = tap[offset]
            }
        }

        let result = SpeechEvidenceAnalyzer.analyze(pcmData: pcmData(samples))

        XCTAssertFalse(result.hasSpeech)
        XCTAssertLessThan(result.totalVoicedMilliseconds, 160)
    }

    func testAcceptedAccessibilityWriteNeverFallsBack() {
        XCTAssertTrue(
            AccessibilityInserter.InsertionResult.Status.acceptedUnverified.preventsFallback
        )
        XCTAssertTrue(
            AccessibilityInserter.InsertionResult.Status.committed.preventsFallback
        )
        XCTAssertFalse(
            AccessibilityInserter.InsertionResult.Status.failedBeforeWrite.preventsFallback
        )
    }

    func testLegacyDictionaryEntryDecodesWithEmptyAliases() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "term": "Dictify",
          "category": "brand",
          "addedAt": "2026-07-20T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let entry = try decoder.decode(DictionaryEntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.aliases, [])
        XCTAssertEqual(entry.useCount, 0)
        XCTAssertNil(entry.lastUsedAt)
    }

    func testDictionaryAliasesApplyOnceWithWordBoundariesAndTrackUse() {
        let store = DictionaryStore(fileURL: temporaryFile(named: "dictionary.json"))
        let entry = DictionaryEntry(
            term: "CanonicalCluster",
            aliases: ["cooper netties", "kuber netties"]
        )
        XCTAssertTrue(store.add(entry))

        let corrected = store.applyCorrections(
            to: "Use cooper netties, but leave cooper nettiesville unchanged."
        )

        XCTAssertEqual(
            corrected,
            "Use CanonicalCluster, but leave cooper nettiesville unchanged."
        )
        let saved = store.entries.first { $0.id == entry.id }
        XCTAssertEqual(saved?.useCount, 1)
        XCTAssertNotNil(saved?.lastUsedAt)
    }

    func testDictionaryUsesLongestAliasAndMatchesCaseInsensitively() {
        let store = DictionaryStore(fileURL: temporaryFile(named: "dictionary.json"))
        XCTAssertTrue(store.add(DictionaryEntry(term: "Kube", aliases: ["cooper"])))
        XCTAssertTrue(
            store.add(DictionaryEntry(term: "CanonicalPlatform", aliases: ["cooper netties"]))
        )

        XCTAssertEqual(
            store.applyCorrections(to: "COOPER NETTIES and Cooper."),
            "CanonicalPlatform and Kube."
        )
    }

    func testSnippetRejectsNormalizedCueCollisionAndExpandsOnce() {
        let store = SnippetStore(fileURL: temporaryFile(named: "snippets.json"))
        XCTAssertFalse(store.add(Snippet(cue: "paste-clip", body: "duplicate")))

        let snippet = Snippet(cue: "launchsequence", body: "Alpha launchsequence")
        XCTAssertTrue(store.add(snippet))
        XCTAssertEqual(
            store.expandCues(in: "Launch sequence."),
            "Alpha launchsequence."
        )
    }

    func testAppContextClassifiesGmailWithoutExposingTitle() {
        XCTAssertEqual(
            TranscriptionPipeline.classifyWritingContext(
                bundleID: "com.google.Chrome",
                windowTitle: "Inbox (3) - private subject - Gmail"
            ),
            .email
        )
        XCTAssertEqual(
            TranscriptionPipeline.classifyWritingContext(
                bundleID: "com.google.Chrome",
                windowTitle: "Example Domain"
            ),
            .neutral
        )
        XCTAssertEqual(
            TranscriptionPipeline.classifyWritingContext(
                bundleID: "com.apple.mail",
                windowTitle: "Private message subject"
            ),
            .email
        )
    }

    func testRefinementGuardRejectsGeneratedAnswerAndAllowsCleanup() {
        XCTAssertEqual(
            RefinementOutputGuard.rejection(
                for: "Kubernetes is a container orchestration platform.",
                raw: "What is Kubernetes?",
                allowsSnippetExpansion: false
            ),
            .questionWasAnswered
        )
        XCTAssertNil(
            RefinementOutputGuard.rejection(
                for: "Let's meet tomorrow at three.",
                raw: "um lets meet tomorrow at three",
                allowsSnippetExpansion: false
            )
        )
    }

    private func pcmData(_ samples: [Float]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private func deterministicNoise(sampleCount: Int, amplitude: Float) -> [Float] {
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        return (0..<sampleCount).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let normalized = Float(state >> 40) / Float(1 << 24)
            return (normalized * 2 - 1) * amplitude
        }
    }

    private func temporaryFile(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
