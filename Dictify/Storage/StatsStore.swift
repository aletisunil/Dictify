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

    // MARK: Lifetime activity metrics (derived from history, never stored)

    /// Distinct calendar days that have at least one dictation.
    var activeDays: Int {
        distinctDays.count
    }

    /// Consecutive days, counting back from today, with at least one dictation.
    /// Stays alive if today has none but yesterday did (grace for "today not yet").
    var currentStreak: Int {
        let days = distinctDays
        guard !days.isEmpty else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if let yesterday = cal.date(byAdding: .day, value: -1, to: today), days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Hour of day (0–23) with the most dictations, or nil if no history.
    var peakHour: Int? {
        modeComponent(.hour)
    }

    /// Weekday (1 = Sunday … 7 = Saturday) with the most dictations, or nil.
    var busiestWeekday: Int? {
        modeComponent(.weekday)
    }

    /// Minutes saved versus typing the same words at ~40 wpm. Clamped at 0.
    var estimatedMinutesSavedVsTyping: Double {
        let typingMinutes = Double(totalWords) / 40.0
        let speakingMinutes = totalSpeakingSeconds / 60
        return max(0, typingMinutes - speakingMinutes)
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

    /// Set of distinct calendar days (start-of-day) present in history.
    private var distinctDays: Set<Date> {
        guard let records = historyStore?.records else { return [] }
        let cal = Calendar.current
        return Set(records.map { cal.startOfDay(for: $0.date) })
    }

    /// Most frequent value of a date component across all records.
    private func modeComponent(_ component: Calendar.Component) -> Int? {
        guard let records = historyStore?.records, !records.isEmpty else { return nil }
        let cal = Calendar.current
        var counts: [Int: Int] = [:]
        for record in records {
            let value = cal.component(component, from: record.date)
            counts[value, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
