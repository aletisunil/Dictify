import Foundation

/// What the dictation is being typed into, snapshotted when recording starts.
/// Refinement uses it to pick a register (email vs chat vs code) and to fit the
/// cleaned text to the words already around the cursor.
struct TargetContext: Sendable {
    let appName: String?
    let bundleID: String?
    /// Host of the focused browser tab ("mail.google.com"), nil outside a
    /// browser or when the page URL could not be read in budget. Only the host
    /// is kept - paths and query strings can carry message IDs and tokens.
    let host: String?
    let category: TargetCategory
    let field: FieldContext?
}

/// Text already in the focused field, split at the selection. Each part is
/// truncated around the cursor; see `TargetContextReader`.
struct FieldContext: Sendable {
    let before: String
    let selected: String
    let after: String

    /// Whitespace-only counts as empty: an empty Gmail body reports "\n".
    var isEmpty: Bool {
        (before + selected + after).allSatisfy(\.isWhitespace)
    }

    /// How the dictation joins the text before the cursor. Decided here, not
    /// left to the model: the Fast model capitalizes a sentence start even
    /// when told the field ends mid-sentence.
    enum Join {
        case newSentence
        case midSentence
        /// Right after an opening quote: a quoted sentence starts with a
        /// capital, a quoted term does not, so the case is left alone.
        case undetermined
    }

    var join: Join {
        var chars = Array(before)
        while let last = chars.last, last == " " || last == "\t" {
            chars.removeLast()
        }
        // Closing quotes and brackets are transparent: `"yes"` continues like
        // `yes`, `"Done."` ends like `Done.`.
        while let last = chars.last, Self.isClosing(last, after: chars.dropLast().last) {
            chars.removeLast()
        }
        // A line break before the cursor starts a new line, whatever precedes it.
        guard let last = chars.last, !last.isNewline else { return .newSentence }
        let previous = chars.dropLast().last
        if last.isLetter || last.isNumber || ",;([{".contains(last) {
            return .midSentence
        }
        if Self.isOpeningQuote(last, after: previous) {
            return .undetermined
        }
        if Self.dashes.contains(last) {
            // "self-" continues a word. Otherwise a dash first on its line is
            // a bullet ("- "), and one later in the line is a spaced dash.
            if let previous, !previous.isWhitespace {
                return .midSentence
            }
            let beforeDash = chars.dropLast().last { $0 != " " && $0 != "\t" }
            return beforeDash.map { $0.isNewline } ?? true ? .newSentence : .midSentence
        }
        return .newSentence
    }

    /// The text as it should be inserted at this cursor:
    /// - mid-sentence, a capitalized common word that cannot be a name is
    ///   lowercased ("...and" + "He said" -> "...and he said"). The prompt asks
    ///   for this too, but the Fast model capitalizes a sentence start anyway;
    /// - at a new sentence, a word that was lowercased for a mid-sentence
    ///   cursor gets its capital back. `refinedFor` is the join the text was
    ///   refined for; it differs when the user moved to another field or
    ///   spot while Dictify was transcribing;
    /// - a space is added where the text would otherwise fuse with a word
    ///   before or after the cursor. Insertion pastes at the caret verbatim and
    ///   the refined text is trimmed, so nothing else supplies it.
    func fitted(_ text: String, refinedFor: Join? = nil) -> String {
        guard let first = text.first, let last = text.last else { return text }
        var result = text
        let firstWord = result.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        let key = firstWord.lowercased().replacingOccurrences(of: "’", with: "'")
        let lowercasable = Self.lowercasableWords.contains(key)
            && firstWord.dropFirst().allSatisfy { !$0.isUppercase }
        switch join {
        case .midSentence where firstWord.first?.isUppercase == true && lowercasable:
            result = result.prefix(1).lowercased() + result.dropFirst()
        case .newSentence where refinedFor == .midSentence && firstWord.first?.isLowercase == true && lowercasable:
            result = result.prefix(1).uppercased() + result.dropFirst()
        default:
            break
        }
        if let previous = before.last, needsSpace(after: previous), first.isLetter || first.isNumber {
            result = " " + result
        }
        if let next = after.first, next.isLetter || next.isNumber, !last.isWhitespace {
            result += " "
        }
        return result
    }

    /// False after whitespace and after characters the next word attaches
    /// to: opening brackets and quotes, "/", and a dash that ends a word
    /// ("self-"). A closing quote or apostrophe ends a word, so it needs one.
    private func needsSpace(after previous: Character) -> Bool {
        let beforePrevious = before.dropLast().last
        if previous.isWhitespace || "([{/".contains(previous) {
            return false
        }
        if Self.isOpeningQuote(previous, after: beforePrevious) {
            return false
        }
        if Self.dashes.contains(previous) {
            return beforePrevious.map { $0.isWhitespace } ?? true
        }
        return true
    }

    private static let dashes: Set<Character> = ["-", "–", "—"]

    /// A straight quote opens when it follows whitespace, an opening bracket,
    /// or nothing; after anything else it closes (`"yes"`, `kids'`).
    private static func isOpeningQuote(_ char: Character, after previous: Character?) -> Bool {
        switch char {
        case "“", "‘":
            return true
        case "\"", "'":
            guard let previous else { return true }
            return previous.isWhitespace || "([{“‘".contains(previous)
        default:
            return false
        }
    }

    private static func isClosing(_ char: Character, after previous: Character?) -> Bool {
        switch char {
        case ")", "]", "}", "”", "’":
            return true
        case "\"", "'":
            return !isOpeningQuote(char, after: previous)
        default:
            return false
        }
    }

    /// Closed-class words that are only capitalized because they start a
    /// sentence. Deliberately excludes words that are also names (Will, May,
    /// Bill, Mark, Pat, June) and "I", which stays capitalized.
    private static let lowercasableWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "there", "here", "then", "so", "but",
        "and", "or", "nor", "yet", "because", "if", "when", "while", "after", "before", "since",
        "until", "unless", "although", "though", "also", "maybe", "perhaps", "not", "just", "only",
        "he", "she", "it", "we", "they", "you", "him", "her", "them", "us", "me",
        "my", "our", "your", "his", "its", "their",
        "he's", "she's", "it's", "we're", "they're", "you're", "that's", "there's",
        "to", "for", "with", "in", "on", "at", "by", "from", "as", "of", "about", "into", "over",
        "what", "which", "who", "whom", "whose", "how", "why", "where",
        "is", "was", "are", "were", "be", "been", "being", "do", "does", "did", "has", "have", "had",
        "would", "could", "should", "might", "must", "shall", "can", "cannot",
        "can't", "don't", "doesn't", "didn't", "won't", "wouldn't", "couldn't", "shouldn't",
        "isn't", "aren't", "wasn't", "weren't", "haven't", "hasn't", "hadn't",
        "we'll", "they'll", "you'll", "he'll", "she'll", "it'll", "that'll",
        "we've", "they've", "you've", "we'd", "they'd", "you'd", "he'd", "she'd",
        "please", "thanks", "still", "even", "now", "too", "very", "really", "some", "any", "all",
        "each", "every", "both", "either", "neither", "no", "yes", "let's", "let",
    ]
}

/// Register of the target. Matched by bundle-ID prefix for native apps and by
/// host for web apps, so Gmail in Chrome and Mail.app both classify as email.
enum TargetCategory: String, Sendable {
    case email
    case chat
    case aiOrCode = "ai_or_code"
    case document
    case other

    static func classify(bundleID: String?, host: String?) -> TargetCategory {
        // Host first: in a browser the bundle ID only says "Chrome".
        if let host {
            for (category, domains) in hostRules where domains.contains(where: { matches(host: host, domain: $0) }) {
                return category
            }
        }
        if let bundleID {
            for (category, prefixes) in bundleRules where prefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return category
            }
        }
        return .other
    }

    /// Exact host or any subdomain of it, so "www.notion.so" and
    /// "acme.notion.site" match while "notmail.google.com.evil.io" does not.
    private static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    // Ordered: the first category that matches wins.
    private static let bundleRules: [(TargetCategory, [String])] = [
        (.email, [
            "com.apple.mail",
            "com.microsoft.Outlook",
            "com.superhuman.electron",
            "com.readdle.smartemail",
            "com.readdle.SparkDesktop",
            "com.mimestream.Mimestream",
            "it.bloop.airmail",
            "com.freron.MailMate",
            "org.mozilla.thunderbird",
            "io.canarymail",
        ]),
        (.chat, [
            "com.tinyspeck.slackmacgap",
            "com.microsoft.teams",
            "net.whatsapp.WhatsApp",
            "desktop.WhatsApp",
            "com.apple.MobileSMS",
            "com.hnc.Discord",
            "ru.keepcoder.Telegram",
            "org.telegram.desktop",
            "org.whispersystems.signal-desktop",
            "com.facebook.archon",
            "Mattermost.Desktop",
        ]),
        (.aiOrCode, [
            "com.openai.chat",
            "com.anthropic.claudefordesktop",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92", // Cursor
            "com.exafunction.windsurf",
            "dev.zed.Zed",
            "com.apple.dt.Xcode",
            "com.jetbrains.",
            "com.google.android.studio",
            "com.sublimetext.",
        ] + AXAccess.terminalPrefixes),
        (.document, [
            "com.apple.Notes",
            "com.apple.iWork.Pages",
            "com.apple.TextEdit",
            "com.microsoft.Word",
            "notion.id",
            "md.obsidian",
            "net.shinyfrog.bear",
            "com.ulyssesapp.mac",
            "com.lukilabs.lukiapp", // Craft
            "com.literatureandlatte.scrivener",
        ]),
    ]

    private static let hostRules: [(TargetCategory, [String])] = [
        (.email, [
            "mail.google.com",
            "outlook.live.com",
            "outlook.office.com",
            "outlook.office365.com",
            "mail.yahoo.com",
            "mail.proton.me",
            "app.hey.com",
            "app.fastmail.com",
            "mail.zoho.com",
            "mail.superhuman.com",
        ]),
        (.chat, [
            "app.slack.com",
            "teams.microsoft.com",
            "teams.live.com",
            "web.whatsapp.com",
            "discord.com",
            "web.telegram.org",
            "messenger.com",
            "chat.google.com",
            "messages.google.com",
        ]),
        (.aiOrCode, [
            "chatgpt.com",
            "chat.openai.com",
            "claude.ai",
            "gemini.google.com",
            "aistudio.google.com",
            "perplexity.ai",
            "grok.com",
            "chat.mistral.ai",
            "copilot.microsoft.com",
            "chat.deepseek.com",
            "github.dev",
            "vscode.dev",
            "replit.com",
        ]),
        (.document, [
            "docs.google.com",
            "notion.so",
            "notion.site",
            "coda.io",
            "quip.com",
            "paper.dropbox.com",
            "word.cloud.microsoft",
        ]),
    ]
}
