import Foundation

/// Immutable lookup table for spoken emoji names. The bundled data is pinned to
/// Unicode Emoji 15.0 so every emitted glyph is supported by Dictify's macOS 14
/// deployment target.
struct EmojiCatalog: Sendable {
    static let version = "15.0"

    let emojiByCue: [String: String]
    let maxCueWordCount: Int

    static let shared: EmojiCatalog = {
        do {
            guard let url = Bundle.main.url(forResource: "emoji-catalog", withExtension: "json") else {
                throw CatalogError.missingResource
            }
            return try EmojiCatalog(contentsOf: url)
        } catch {
            // Keep the common voice commands available if a damaged bundle ever
            // omits the generated resource. The build normally catches this.
            Log.pipeline.error("Failed to load emoji catalog: \(error.localizedDescription, privacy: .public)")
            return EmojiCatalog(cues: Self.curatedAliases)
        }
    }()

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(CatalogDocument.self, from: data)
        guard document.version == Self.version else {
            throw CatalogError.unsupportedVersion(document.version)
        }

        var cues: [String: String] = [:]
        for entry in document.entries {
            guard !entry.emoji.isEmpty else { throw CatalogError.emptyEmoji }
            for name in entry.names {
                let key = Self.cueKey(name)
                guard !key.isEmpty else { throw CatalogError.emptyCue }
                if let existing = cues[key], existing != entry.emoji {
                    throw CatalogError.duplicateCue(name)
                }
                cues[key] = entry.emoji
            }
        }

        // Canonical CLDR names win if a future Unicode release introduces a
        // name that overlaps one of Dictify's broad colloquial aliases.
        for (name, emoji) in Self.curatedAliases where cues[Self.cueKey(name)] == nil {
            cues[Self.cueKey(name)] = emoji
        }
        self.init(cues: cues)
    }

    init(cues: [String: String]) {
        var normalized: [String: String] = [:]
        var longest = 0
        for (cue, emoji) in cues {
            let key = Self.cueKey(cue)
            guard !key.isEmpty, !emoji.isEmpty else { continue }
            normalized[key] = emoji
            longest = max(longest, key.split(separator: " ").count)
        }
        emojiByCue = normalized
        maxCueWordCount = longest
    }

    fileprivate func emoji(for words: ArraySlice<SpokenEmojiReplacer.Token>) -> String? {
        emojiByCue[words.map(\.normalized).joined(separator: " ")]
    }

    fileprivate static func cueKey(_ value: String) -> String {
        SpokenEmojiReplacer.normalizedWords(in: value).joined(separator: " ")
    }

    /// Predictable defaults for common, conversational names. Specific CLDR
    /// names (for example "crying face") remain authoritative.
    private static let curatedAliases: [String: String] = [
        "happy": "😊", "happy face": "😊", "smile": "😊", "smiling": "😊",
        "smiley": "😊", "smiley face": "😊",
        "sad": "😢", "sad face": "😢",
        "laugh": "😂", "laughing": "😂", "laughing face": "😂", "lol": "😂",
        "rofl": "🤣", "crying": "😭",
        "angry": "😡", "angry face": "😡", "mad": "😡",
        "love": "❤️", "heart": "❤️", "broken heart": "💔",
        "fire": "🔥", "flame": "🔥",
        "cool": "😎", "cool face": "😎", "wink": "😉", "wink face": "😉",
        "thinking": "🤔", "confused": "😕", "shocked": "😱", "shocked face": "😱",
        "scream": "😱", "eye roll": "🙄", "hug": "🤗", "kiss": "😘",
        "heart eyes": "😍", "love eyes": "😍",
        "party": "🎉", "celebrate": "🎉", "celebration": "🎉", "party face": "🥳",
        "prayer": "🙏", "pray": "🙏",
        "thumbs up": "👍", "like": "👍", "thumbs down": "👎", "dislike": "👎",
        "clap": "👏", "applause": "👏", "strong": "💪", "muscle": "💪",
        "okay hand": "👌", "peace": "✌️", "raised hands": "🙌", "praise": "🙌",
        "shrug": "🤷", "facepalm": "🤦",
        "hundred": "💯", "one hundred": "💯", "sparkle": "✨", "sparkles": "✨",
        "check": "✅", "check mark": "✅", "warning": "⚠️",
        "question mark": "❓", "exclamation mark": "❗",
        "rocket": "🚀", "poop": "💩", "skull": "💀", "dead": "💀", "eyes": "👀",
        "hashtag": "#️⃣", "asterisk": "*️⃣",
    ]

    private struct CatalogDocument: Decodable {
        let version: String
        let entries: [CatalogEntry]
    }

    private struct CatalogEntry: Decodable {
        let emoji: String
        let names: [String]
    }

    private enum CatalogError: LocalizedError {
        case missingResource
        case unsupportedVersion(String)
        case emptyEmoji
        case emptyCue
        case duplicateCue(String)

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "emoji-catalog.json is missing from the app bundle"
            case .unsupportedVersion(let version):
                return "unsupported emoji catalog version \(version)"
            case .emptyEmoji:
                return "emoji catalog contains an empty glyph"
            case .emptyCue:
                return "emoji catalog contains an empty spoken name"
            case .duplicateCue(let cue):
                return "emoji catalog contains conflicting cue \(cue)"
            }
        }
    }
}

/// Deterministic local replacement for explicitly dictated emoji names.
///
/// Supported grammar:
/// - `<cue> emoji`
/// - `insert <cue> [emoji]`
/// - `add <cue> [emoji]`
///
/// Bare names are intentionally left untouched so ordinary prose such as
/// "I ate pizza" never turns into an emoji unexpectedly.
enum SpokenEmojiReplacer {
    fileprivate struct Token {
        let range: Range<String.Index>
        let normalized: String
        let continuesCue: Bool
    }

    private struct Match {
        let tokenCount: Int
        let emoji: String
    }

    static func replace(in text: String, catalog: EmojiCatalog = .shared) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty, catalog.maxCueWordCount > 0 else { return text }

        var pieces: [String] = []
        var cursor = text.startIndex
        var tokenIndex = 0
        var replacedAny = false

        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex].normalized
            let isCommand = token == "insert" || token == "add"

            if isCommand,
               tokenIndex + 1 < tokens.count,
               tokens[tokenIndex + 1].continuesCue,
               let match = longestMatch(in: tokens, startingAt: tokenIndex + 1, catalog: catalog) {
                var lastTokenIndex = tokenIndex + match.tokenCount
                let suffixIndex = lastTokenIndex + 1
                if suffixIndex < tokens.count,
                   tokens[suffixIndex].continuesCue,
                   tokens[suffixIndex].normalized == "emoji" {
                    lastTokenIndex = suffixIndex
                }
                appendReplacement(
                    match.emoji,
                    fromToken: tokenIndex,
                    throughToken: lastTokenIndex,
                    in: text,
                    tokens: tokens,
                    cursor: &cursor,
                    pieces: &pieces
                )
                tokenIndex = lastTokenIndex + 1
                replacedAny = true
                continue
            }

            if let match = longestMatch(in: tokens, startingAt: tokenIndex, catalog: catalog) {
                let suffixIndex = tokenIndex + match.tokenCount
                if suffixIndex < tokens.count,
                   tokens[suffixIndex].continuesCue,
                   tokens[suffixIndex].normalized == "emoji" {
                    appendReplacement(
                        match.emoji,
                        fromToken: tokenIndex,
                        throughToken: suffixIndex,
                        in: text,
                        tokens: tokens,
                        cursor: &cursor,
                        pieces: &pieces
                    )
                    tokenIndex = suffixIndex + 1
                    replacedAny = true
                    continue
                }
            }

            tokenIndex += 1
        }

        guard replacedAny else { return text }
        pieces.append(String(text[cursor...]))
        return pieces.joined()
    }

    fileprivate static func normalizedWords(in text: String) -> [String] {
        tokenize(text).map(\.normalized)
    }

    private static func longestMatch(
        in tokens: [Token],
        startingAt start: Int,
        catalog: EmojiCatalog
    ) -> Match? {
        guard start < tokens.count else { return nil }
        let available = min(catalog.maxCueWordCount, tokens.count - start)
        var best: Match?
        for count in 1...available {
            if count > 1, !tokens[start + count - 1].continuesCue {
                break
            }
            let words = tokens[start..<(start + count)]
            if let emoji = catalog.emoji(for: words) {
                best = Match(tokenCount: count, emoji: emoji)
            }
        }
        return best
    }

    private static func appendReplacement(
        _ emoji: String,
        fromToken firstTokenIndex: Int,
        throughToken lastTokenIndex: Int,
        in text: String,
        tokens: [Token],
        cursor: inout String.Index,
        pieces: inout [String]
    ) {
        let replacementStart = tokens[firstTokenIndex].range.lowerBound
        let replacementEnd = tokens[lastTokenIndex].range.upperBound
        pieces.append(String(text[cursor..<replacementStart]))
        pieces.append(emoji)
        cursor = replacementEnd
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }

            let start = index
            while index < text.endIndex, text[index].isLetter || text[index].isNumber {
                index = text.index(after: index)
            }
            let value = String(text[start..<index]).lowercased()
            let continuesCue: Bool
            if let previous = tokens.last {
                let separator = text[previous.range.upperBound..<start]
                continuesCue = separator.allSatisfy { character in
                    character.isWhitespace || character == "-" || character == "‐"
                        || character == "‑" || character == "'" || character == "’"
                } && !separator.contains(where: { $0 == "\n" || $0 == "\r" })
            } else {
                continuesCue = false
            }
            tokens.append(Token(range: start..<index, normalized: value, continuesCue: continuesCue))
        }

        return tokens
    }
}
