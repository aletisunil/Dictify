import SwiftUI
import AppKit

// MARK: - Theme Colors
//
// Light mode swaps macOS's pure-white window/control backgrounds for a warmer
// cream palette; dark mode keeps the system colors so it stays true black-grey.
// Both are dynamic NSColors, so they react to live appearance changes.

extension NSColor {
    /// App window background — cream in light mode, system window grey in dark.
    static let appWindowBackground = NSColor(name: "appWindowBackground") { appearance in
        appearance.isDark
            ? .windowBackgroundColor
            : NSColor(calibratedRed: 0.961, green: 0.925, blue: 0.843, alpha: 1.0) // #F5ECD7
    }

    /// Card / control background — a lighter cream that lifts off the window in
    /// light mode; system control colour in dark. Step widened from the window
    /// so cards read as lifted without leaning entirely on the hairline stroke.
    static let appCardBackground = NSColor(name: "appCardBackground") { appearance in
        appearance.isDark
            ? .controlBackgroundColor
            : NSColor(calibratedRed: 1.0, green: 0.984, blue: 0.945, alpha: 1.0) // #FFFBF1
    }

    /// Sidebar background — a darker cream step below the window in light mode;
    /// system control colour in dark.
    static let appSidebarBackground = NSColor(name: "appSidebarBackground") { appearance in
        appearance.isDark
            ? .windowBackgroundColor
            : NSColor(calibratedRed: 0.933, green: 0.898, blue: 0.816, alpha: 1.0) // #EEE5D0
    }

    /// Brand accent — the system accent (blue by default) in both light and dark
    /// mode, so tinted controls match the blue sidebar selection. Only the
    /// window/card/sidebar backgrounds carry the warm cream palette in light mode;
    /// the accent stays the platform accent rather than a warm clay.
    static let appAccent = NSColor(name: "appAccent") { _ in
        .controlAccentColor
    }

    /// Status: idle/ready — desaturated olive in light mode so it sits on the
    /// cream palette; system green in dark.
    static let appReady = NSColor(name: "appReady") { appearance in
        appearance.isDark
            ? .systemGreen
            : NSColor(calibratedRed: 0.361, green: 0.541, blue: 0.290, alpha: 1.0) // #5C8A4A
    }

    /// Status: in-flight (transcribing/refining/inserting) — warm amber in
    /// light mode; system orange in dark.
    static let appWorking = NSColor(name: "appWorking") { appearance in
        appearance.isDark
            ? .systemOrange
            : NSColor(calibratedRed: 0.788, green: 0.502, blue: 0.227, alpha: 1.0) // #C9803A
    }

    /// Status: recording/error — muted brick in light mode; system red in dark.
    /// Status pipeline only; genuine destructive controls keep the system red
    /// so they read as dangerous per platform convention.
    static let appAlert = NSColor(name: "appAlert") { appearance in
        appearance.isDark
            ? .systemRed
            : NSColor(calibratedRed: 0.753, green: 0.278, blue: 0.235, alpha: 1.0) // #C0473C
    }
}

extension NSAppearance {
    /// True when the effective appearance is one of the dark variants.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Appearance preference

/// The user's appearance choice, persisted as a raw string under
/// `Constants.UI.appearancePreferenceKey`. Centralises the three valid values so
/// the Picker, the launch read, and `applyAppearance` can't drift out of sync.
enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    /// The `NSApp.appearance` to pin. `nil` follows the macOS system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension Color {
    static let appWindowBackground = Color(nsColor: .appWindowBackground)
    static let appCardBackground = Color(nsColor: .appCardBackground)
    static let appSidebarBackground = Color(nsColor: .appSidebarBackground)
    static let appAccent = Color(nsColor: .appAccent)
    static let appReady = Color(nsColor: .appReady)
    static let appWorking = Color(nsColor: .appWorking)
    static let appAlert = Color(nsColor: .appAlert)

    /// The single hairline used on every card/control border.
    static let appHairline = Color.primary.opacity(0.08)
}

// MARK: - Cream form helper

extension View {
    /// Drops a grouped `Form`'s opaque white base so the cream window shows
    /// through, then repaints it with the cream window colour.
    func creamFormBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.appWindowBackground)
    }

    /// Repaints a grouped `Form` section's rows with the cream card colour so
    /// they match the List-based pages (Snippets, Dictionary) instead of
    /// rendering the system near-white control background in light mode.
    func creamFormRow() -> some View {
        listRowBackground(Color.appCardBackground)
    }
}

// MARK: - Search field

/// The single search-field style used everywhere (History, Snippets,
/// Dictionary). A tinted capsule over the cream palette — never an opaque
/// white `.roundedBorder`, which clashed with the warm background.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Secure field

/// A SecureField styled to match the cream palette — a tinted capsule like
/// `SearchField`, never the opaque white `.roundedBorder` that clashed with the
/// warm background.
struct CreamSecureField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.appHairline, lineWidth: 1)
            )
    }
}
