import Foundation

/// Session stats live in-memory only. Lifetime stats are persisted as small
/// aggregates in `stats.json`, independent of `HistoryStore` — history is
/// capped at `Constants.UI.maxHistoryItems` records, so deriving lifetime
/// numbers from it would make totals shrink once old records roll off.
///
/// On first launch after the aggregate file is introduced (or if it is
/// quarantined as corrupt), the aggregates are seeded from whatever history
/// still exists — the best available approximation of lifetime activity.
@MainActor
final class StatsStore: ObservableObject {

    /// Persisted lifetime aggregates. Per-day counts are keyed by local
    /// calendar day ("yyyy-MM-dd") — one entry per active day, so growth is
    /// negligible. Hour/weekday histograms are fixed-size arrays.
    private struct LifetimeStats: Codable {
        var version: Int = 1
        var totalWords: Int = 0
        var totalSpeakingSeconds: Double = 0
        var totalDictations: Int = 0
        var dayCounts: [String: Int] = [:]
        /// Index = hour of day (0–23).
        var hourCounts: [Int] = Array(repeating: 0, count: 24)
        /// Index = Calendar weekday (1 = Sunday … 7 = Saturday); index 0 unused.
        var weekdayCounts: [Int] = Array(repeating: 0, count: 8)

        // Resilient decoding so a file written by a different app version
        // (missing or extra fields) loads instead of being quarantined.
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            totalWords = try c.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
            totalSpeakingSeconds = try c.decodeIfPresent(Double.self, forKey: .totalSpeakingSeconds) ?? 0
            totalDictations = try c.decodeIfPresent(Int.self, forKey: .totalDictations) ?? 0
            dayCounts = try c.decodeIfPresent([String: Int].self, forKey: .dayCounts) ?? [:]
            let hours = try c.decodeIfPresent([Int].self, forKey: .hourCounts) ?? []
            hourCounts = hours.count == 24 ? hours : Array(repeating: 0, count: 24)
            let weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdayCounts) ?? []
            weekdayCounts = weekdays.count == 8 ? weekdays : Array(repeating: 0, count: 8)
        }
    }

    @Published private(set) var sessionWords: Int = 0
    @Published private(set) var sessionSpeakingSeconds: Double = 0
    @Published private var lifetime = LifetimeStats()
    @Published private(set) var lastSaveError: Error?

    private weak var historyStore: HistoryStore?
    private let fileURL = Constants.Storage.statsFileURL

    init(historyStore: HistoryStore? = nil) {
        self.historyStore = historyStore
        load()
    }

    var totalWords: Int { lifetime.totalWords }

    var totalSpeakingSeconds: Double { lifetime.totalSpeakingSeconds }

    var totalDictations: Int { lifetime.totalDictations }

    var sessionWPM: Double? {
        wpm(words: sessionWords, speakingSeconds: sessionSpeakingSeconds)
    }

    var totalWPM: Double? {
        wpm(words: totalWords, speakingSeconds: totalSpeakingSeconds)
    }

    // MARK: Lifetime activity metrics

    /// Distinct calendar days that have at least one dictation.
    var activeDays: Int {
        lifetime.dayCounts.count
    }

    /// Consecutive days, counting back from today, with at least one dictation.
    /// Stays alive if today has none but yesterday did (grace for "today not yet").
    var currentStreak: Int {
        guard !lifetime.dayCounts.isEmpty else { return 0 }
        let cal = Calendar.current
        var cursor = cal.startOfDay(for: Date())
        if lifetime.dayCounts[Self.dayKey(for: cursor)] == nil {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
                  lifetime.dayCounts[Self.dayKey(for: yesterday)] != nil else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while lifetime.dayCounts[Self.dayKey(for: cursor)] != nil {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Hour of day (0–23) with the most dictations, or nil if none recorded.
    var peakHour: Int? {
        maxIndex(in: lifetime.hourCounts)
    }

    /// Weekday (1 = Sunday … 7 = Saturday) with the most dictations, or nil.
    var busiestWeekday: Int? {
        maxIndex(in: lifetime.weekdayCounts)
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
        apply(words: wordCount, durationSeconds: durationSeconds, date: Date())
        save()
    }

    // MARK: - Aggregation

    private func apply(words: Int, durationSeconds: Double, date: Date) {
        lifetime.totalWords += words
        lifetime.totalSpeakingSeconds += durationSeconds
        lifetime.totalDictations += 1
        lifetime.dayCounts[Self.dayKey(for: date), default: 0] += 1
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        if lifetime.hourCounts.indices.contains(hour) {
            lifetime.hourCounts[hour] += 1
        }
        let weekday = cal.component(.weekday, from: date)
        if lifetime.weekdayCounts.indices.contains(weekday) {
            lifetime.weekdayCounts[weekday] += 1
        }
    }

    /// Index of the largest positive count, or nil when all counts are zero.
    private func maxIndex(in counts: [Int]) -> Int? {
        guard let maxCount = counts.max(), maxCount > 0 else { return nil }
        return counts.firstIndex(of: maxCount)
    }

    private func wpm(words: Int, speakingSeconds: Double) -> Double? {
        guard speakingSeconds > 0 else { return nil }
        return Double(words) / (speakingSeconds / 60)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    private static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in
            count += 1
        }
        return count
    }

    // MARK: - Persistence

    private func load() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                lifetime = try JSONDecoder().decode(LifetimeStats.self, from: data)
                return
            } catch {
                Log.storage.error("Failed to load stats.json: \(error.localizedDescription, privacy: .public)")
                StorageQuarantine.quarantine(fileURL, reason: "decode_failed")
            }
        }
        seedFromHistory()
        save()
    }

    /// One-time migration: rebuild aggregates from whatever history records
    /// survive the history cap. Under-counts true lifetime activity if more
    /// than `maxHistoryItems` dictations ever existed, but it is the best
    /// information still available.
    private func seedFromHistory() {
        lifetime = LifetimeStats()
        guard let records = historyStore?.records else { return }
        for record in records {
            apply(
                words: Self.wordCount(in: record.refinedText),
                durationSeconds: record.durationSeconds,
                date: record.date
            )
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(lifetime)
            try data.write(to: fileURL, options: .atomic)
            lastSaveError = nil
        } catch {
            Log.storage.error("Failed to save stats.json (attempt 1): \(error.localizedDescription, privacy: .public)")
            do {
                let data = try encoder.encode(lifetime)
                try data.write(to: fileURL, options: .atomic)
                lastSaveError = nil
            } catch {
                Log.storage.error("Failed to save stats.json (retry): \(error.localizedDescription, privacy: .public)")
                lastSaveError = error
            }
        }
    }
}
