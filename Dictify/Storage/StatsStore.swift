import Foundation

@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var sessionWords: Int = 0
    @Published private(set) var sessionSpeakingSeconds: Double = 0
    @Published private(set) var totalWords: Int
    @Published private(set) var totalSpeakingSeconds: Double

    private let userDefaults: UserDefaults

    private enum DefaultsKey {
        static let totalWords = "stats.totalWords"
        static let totalSpeakingSeconds = "stats.totalSpeakingSeconds"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.totalWords = userDefaults.integer(forKey: DefaultsKey.totalWords)
        self.totalSpeakingSeconds = userDefaults.double(forKey: DefaultsKey.totalSpeakingSeconds)
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
        totalWords += wordCount
        totalSpeakingSeconds += durationSeconds

        userDefaults.set(totalWords, forKey: DefaultsKey.totalWords)
        userDefaults.set(totalSpeakingSeconds, forKey: DefaultsKey.totalSpeakingSeconds)
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
