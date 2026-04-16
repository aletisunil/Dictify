import Foundation

enum Constants {
    static let appName = "Dictify"
    static let bundleIdentifier = "com.dictify.app"

    enum API {
        static let baseURL = "https://api.groq.com/openai/v1"
        static let transcriptionEndpoint = "\(baseURL)/audio/transcriptions"
        static let chatCompletionEndpoint = "\(baseURL)/chat/completions"
        static let whisperModel = "whisper-large-v3-turbo"
        static let llamaModel = "llama-3.3-70b-versatile"
    }

    enum Audio {
        static let sampleRate: Double = 16000
        static let channels: UInt32 = 1
        static let minRecordingDuration: TimeInterval = 0.5
        static let maxRecordingDuration: TimeInterval = 120
        static let tapHoldThreshold: TimeInterval = 0.2
    }

    enum Keychain {
        static let service = "com.dictify.api"
        static let apiKeyAccount = "groq-api-key"
    }

    enum Storage {
        static var appSupportDirectory: URL {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                fatalError("Application Support directory not available")
            }
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
        static let doneDismissDelay: TimeInterval = 0.8
        static let maxHistoryItems = 10
    }
}
