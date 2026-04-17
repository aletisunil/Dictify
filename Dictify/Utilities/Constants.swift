import Foundation

enum Constants {
    static let appName = "Dictify"
    static let bundleIdentifier = "com.dictify.app"

    enum API {
        static let baseURL = "https://api.groq.com/openai/v1"
        static let transcriptionEndpoint = "\(baseURL)/audio/transcriptions"
        static let chatCompletionEndpoint = "\(baseURL)/chat/completions"
        static let modelsEndpoint = "\(baseURL)/models"
        static let whisperModel = "whisper-large-v3-turbo"
        static let llamaModel = "llama-3.3-70b-versatile"
        static let whisperPromptMaxTokens = 200
        static let snippetContextMaxTokens = 1500
    }

    enum Audio {
        static let sampleRate: Double = 16000
        static let channels: UInt32 = 1
        static let minRecordingDuration: TimeInterval = 0.5
        static let maxRecordingDuration: TimeInterval = 120
        /// Default only. Overridable via `DictifySettings.tapHoldThreshold`.
        static let tapHoldThreshold: TimeInterval = 0.2
    }

    enum Keychain {
        static let service = "com.dictify.api"
        static let apiKeyAccount = "groq-api-key"
        static let hasAPIKeyDefaultsKey = "dictify.hasAPIKey"
    }

    enum Storage {
        static var appSupportDirectory: URL {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return appSupport.appendingPathComponent("Dictify")
        }
        static var dictionaryFileURL: URL { appSupportDirectory.appendingPathComponent("dictionary.json") }
        static var snippetsFileURL: URL { appSupportDirectory.appendingPathComponent("snippets.json") }
        static var historyFileURL: URL { appSupportDirectory.appendingPathComponent("history.json") }
    }

    enum UI {
        static let indicatorWidth: CGFloat = 176
        static let indicatorHeight: CGFloat = 42
        static let indicatorCornerRadius: CGFloat = 21
        static let maxHistoryItems = 10
    }
}
