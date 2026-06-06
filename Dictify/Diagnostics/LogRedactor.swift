import Foundation

/// Scrubs sensitive content out of log text before it can be copied, saved, or
/// emailed.
///
/// This is a **security boundary**, not a nicety. We do not trust `os.Logger`'s
/// `privacy:` redaction to survive a same-process `OSLogStore` read, so every
/// line bound for a shareable bundle passes through here. The rules are
/// deliberately conservative — over-redaction is preferred to any leak — and the
/// transform is pure, deterministic, and idempotent so its behavior is easy to
/// reason about and verify by hand.
///
/// Guarantees:
///   * Groq API keys (`gsk_…`) and bearer tokens are removed.
///   * `Authorization: Bearer …` header values are removed.
///   * Email addresses are masked.
///   * Absolute user home paths (`/Users/<name>/…`) have the username removed.
///   * Lines longer than the cap are truncated (backstop against payload dumps).
///   * Redacting already-redacted text is a no-op.
enum LogRedactor {
    private static let keyPlaceholder = "<redacted-key>"
    private static let tokenPlaceholder = "<redacted-token>"
    private static let emailPlaceholder = "<redacted-email>"

    /// Patterns are ordered most-specific first so, e.g., a bearer header is
    /// caught before the generic long-token rule.
    private static let patterns: [(regex: NSRegularExpression, replacement: String)] = {
        let specs: [(String, String)] = [
            // Authorization: Bearer <token>
            ("(?i)(authorization\\s*:\\s*bearer\\s+)[A-Za-z0-9._\\-]+", "$1\(tokenPlaceholder)"),
            // Groq-style secret keys: gsk_ followed by a long token body.
            ("gsk_[A-Za-z0-9]{20,}", keyPlaceholder),
            // Generic OpenAI-style keys: sk- / sk-proj- prefixes.
            ("sk-(proj-)?[A-Za-z0-9_\\-]{20,}", keyPlaceholder),
            // Email addresses.
            ("[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}", emailPlaceholder),
            // Absolute home paths — keep the path shape, drop the username.
            ("/Users/[^/\\s]+", "/Users/<redacted>"),
            // Long bare tokens (JWT-ish / opaque secrets) as a final backstop.
            ("\\b[A-Za-z0-9_\\-]{40,}\\b", tokenPlaceholder),
        ]
        return specs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    /// Redact a single log message.
    static func redact(_ message: String) -> String {
        var result = message
        for (regex, replacement) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return truncate(result)
    }

    /// Redact a whole record's message in place.
    static func redact(_ record: LogRecord) -> LogRecord {
        LogRecord(
            date: record.date,
            category: record.category,
            level: record.level,
            message: redact(record.message)
        )
    }

    private static func truncate(_ line: String) -> String {
        let cap = Constants.Diagnostics.maxLineLength
        guard line.count > cap else { return line }
        let prefix = line.prefix(cap)
        return "\(prefix)…[truncated]"
    }
}
