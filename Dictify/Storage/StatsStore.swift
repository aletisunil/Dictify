import Foundation

/// Session stats live in-memory only. Lifetime totals are derived from
/// `HistoryStore` so the two can never drift — clearing history also zeros
/// the totals, and a fresh install shows zero even if stale UserDefaults
/// survived a previous install.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var sessionWords: Int = 0
    @Published private(set) var sessionSpeakingSeconds: Double = 0

    private weak var historyStore: HistoryStore?

    init(historyStore: HistoryStore? = nil) {
        self.historyStore = historyStore
    }

    func bind(historyStore: HistoryStore) {
        self.historyStore = historyStore
    }

    var totalWords: Int {
        guard let records = historyStore?.records else { return 0 }
        return records.reduce(0) { $0 + Self.wordCount(in: $1.refinedText) }
    }

    var totalSpeakingSeconds: Double {
        guard let records = historyStore?.records else { return 0 }
        return records.reduce(0) { $0 + $1.durationSeconds }
    }

    var sessionWPM: Double? {
        wpm(words: sessionWords, speakingSeconds: sessionSpeakingSeconds)
    }

    var totalWPM: Double? {
        wpm(words: totalWords, speakingSeconds: totalSpeakingSeconds)
    }

    func record(text: String, durationSeconds: Double) {
        let wordCount = Self.wordCount(in: text)
        sessionWords += wordCount
        sessionSpeakingSeconds += durationSeconds
    }

    private func wpm(words: Int, speakingSeconds: Double) -> Double? {
        guard speakingSeconds > 0 else { return nil }
        return Double(words) / (speakingSeconds / 60)
    }

    private static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
