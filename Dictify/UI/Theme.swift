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
            : NSColor(calibratedRed: 0.957, green: 0.933, blue: 0.878, alpha: 1.0) // #F4EEE0
    }

    /// Card / control background — a lighter cream that lifts off the window in
    /// light mode; system control colour in dark. Step widened from the window
    /// so cards read as lifted without leaning entirely on the hairline stroke.
    static let appCardBackground = NSColor(name: "appCardBackground") { appearance in
        appearance.isDark
            ? .controlBackgroundColor
            : NSColor(calibratedRed: 1.0, green: 0.992, blue: 0.973, alpha: 1.0) // #FFFDF8
    }

    /// Sidebar background — a darker cream step below the window in light mode;
    /// system control colour in dark.
    static let appSidebarBackground = NSColor(name: "appSidebarBackground") { appearance in
        appearance.isDark
            ? .windowBackgroundColor
            : NSColor(calibratedRed: 0.929, green: 0.906, blue: 0.851, alpha: 1.0) // #EDE7D9
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

extension Color {
    static let appWindowBackground = Color(nsColor: .appWindowBackground)
    static let appCardBackground = Color(nsColor: .appCardBackground)
    static let appSidebarBackground = Color(nsColor: .appSidebarBackground)
    /// Brand accent — follows the system accent in both modes. (An earlier build
    /// used a warm clay accent; reverted to system blue to match the reference
    /// settings design.)
    static let appAccent = Color.accentColor
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

// MARK: - Settings layout
//
// A card-based layout language for the Preferences pages: a page header card
// (icon tile + title + subtitle), grouped content cards holding inline rows
// separated by hairlines, bold section labels that sit *outside* the cards, and
// a status pill. Pages compose these inside `SettingsScaffold`.

private enum SettingsMetrics {
    static let cardRadius: CGFloat = 16
    static let headerRadius: CGFloat = 18
    static let rowH: CGFloat = 18
    static let rowV: CGFloat = 13
    static let contentMaxWidth: CGFloat = 820
}

/// Scrollable cream page that centers and width-caps its stack of cards.
struct SettingsScaffold<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .frame(maxWidth: SettingsMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appWindowBackground)
    }
}

/// Page header: a grey icon tile beside the page title and a one-line subtitle.
struct SettingsHeaderCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.48)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 60, height: 60)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.headerRadius, style: .continuous)
                .fill(Color.appCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.headerRadius, style: .continuous)
                .stroke(Color.appHairline, lineWidth: 1)
        )
    }
}

/// A bold label that sits above a card (e.g. "Permissions"), outside its frame.
struct SettingsSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded content card. Rows are stacked vertically; callers insert
/// `RowDivider()` between them.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .fill(Color.appCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .stroke(Color.appHairline, lineWidth: 1)
            )
    }
}

/// Hairline between rows inside a `SettingsCard`, inset to clear the card edge.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.appHairline)
            .frame(height: 1)
            .padding(.horizontal, SettingsMetrics.rowH)
    }
}

/// One row: title (+ optional subtitle) on the left, a trailing accessory on the
/// right (toggle, picker, button, pill…).
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let accessory: () -> Accessory

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    /// Row with no trailing accessory (e.g. a tappable settings row).
    init(_ title: String, subtitle: String? = nil) where Accessory == EmptyView {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, SettingsMetrics.rowH)
        .padding(.vertical, SettingsMetrics.rowV)
    }
}

/// A compact status capsule: a coloured dot + label on a neutral pill.
struct StatusPill: View {
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.appHairline, lineWidth: 1))
    }
}
