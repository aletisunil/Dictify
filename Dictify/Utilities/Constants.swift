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
        static let gptOssModelQuality = "openai/gpt-oss-120b"
        static let gptOssModelFast = "openai/gpt-oss-20b"
        static let whisperPromptMaxTokens = 200
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
            // Debug builds use a separate folder so running from Xcode never
            // reads or overwrites the installed release's dictionary/snippets/
            // history. The app isn't sandboxed, so both share the same bundle id
            // and would otherwise clobber each other's data.
            #if DEBUG
            return appSupport.appendingPathComponent("Dictify-Debug")
            #else
            return appSupport.appendingPathComponent("Dictify")
            #endif
        }
        static var dictionaryFileURL: URL { appSupportDirectory.appendingPathComponent("dictionary.json") }
        static var snippetsFileURL: URL { appSupportDirectory.appendingPathComponent("snippets.json") }
        static var historyFileURL: URL { appSupportDirectory.appendingPathComponent("history.json") }
    }

    enum Diagnostics {
        /// How far back to read unified-log entries when building a shareable bundle.
        static let captureWindow: TimeInterval = 30 * 60
        /// Hard ceiling on collected entries — keeps OSLogStore reads fast and
        /// bundles email-sized even if logging is chatty.
        static let maxEntries = 2000
        /// Per-line character cap applied during redaction — backstop against a
        /// stray large payload (e.g. an accidental transcript dump) bloating a bundle.
        static let maxLineLength = 2000
        /// Developer support address used by the "Email Logs" action.
        static let supportEmail = "iam@sunilaleti.dev"
    }

    enum UI {
        static let indicatorWidth: CGFloat = 176
        static let indicatorHeight: CGFloat = 42
        static let indicatorCornerRadius: CGFloat = 21
        static let maxHistoryItems = 500
        /// UserDefaults key backing the System/Light/Dark appearance picker.
        static let appearancePreferenceKey = "appearancePreference"
    }
}
