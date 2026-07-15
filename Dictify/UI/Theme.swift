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

// MARK: - Design tokens
//
// One spacing/radius/type scale so every screen shares the same rhythm. Pages
// (Snippets, Dictionary, About, Home) and the shared components below all draw
// from these instead of hand-picking magic numbers, which is what made the
// pages drift apart visually.

enum DS {
    /// Spacing scale (4-pt base).
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Corner radii.
    enum Radius {
        static let control: CGFloat = 8
        static let card: CGFloat = 12
    }

    /// Page content inset — matches the grouped Form inset so Form-based pages
    /// (General/API) and card-based pages (Snippets/Dictionary) line up.
    static let pageInset: CGFloat = 20
}

// Sizes mirror the scale already used on Home/History so every page reads the
// same: row text 13, supporting 11, card/section titles 14, hero 18.
extension Font {
    /// App-identity / hero title (matches Home hero).
    static let dsTitle = Font.system(size: 18, weight: .semibold)
    /// Card / section header.
    static let dsHeadline = Font.system(size: 14, weight: .semibold)
    /// Primary row text.
    static let dsBody = Font.system(size: 13)
    /// Emphasised row text.
    static let dsBodyMedium = Font.system(size: 13, weight: .medium)
    /// Secondary / supporting text.
    static let dsCaption = Font.system(size: 11)
    /// Badge / pill text — matches the inline labels used on Home/History.
    static let dsBadge = Font.system(size: 11, weight: .medium)
    /// Monospaced bodies (snippet text, keys).
    static let dsMono = Font.system(size: 12, design: .monospaced)
}

// MARK: - Reduced motion

/// `withAnimation` that honors the system Reduce Motion preference: the state
/// change still happens, just without the animated transition. Use for every
/// decorative animation; matches the NSWorkspace pattern in IndicatorWindow.
func withMotionAnimation(_ animation: Animation? = .default, _ body: () -> Void) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        body()
    } else {
        withAnimation(animation, body)
    }
}

// MARK: - Card surface

extension View {
    /// The single card surface used across the app: cream card fill, hairline
    /// border, card radius. A soft shadow lifts it off the warm window without
    /// the heavy drop-shadow that read as cheap.
    func dsCard(padding: CGFloat = DS.Space.lg, radius: CGFloat = DS.Radius.card) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.appCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.appHairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Section header

/// A page/section header: title + optional supporting subtitle. Used at the top
/// of card-based pages so they read with the same hierarchy as Form sections.
struct DSSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                // Matches the grouped-Form section header prominence on
                // General/API so card-based pages share the same hierarchy.
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Badge

/// The single capsule badge (snippet/dictionary category, "Learned"), replacing
/// the hand-rolled, hardcoded capsules that differed page to page.
struct Badge: View {
    let text: String
    var tint: Color = .appAccent

    var body: some View {
        Text(text)
            .font(.dsBadge)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

// MARK: - Inline hint

/// A quiet inline note (e.g. "Snippets require refinement enabled"). Lower-key
/// than `HomeBanner` — for in-context guidance rather than alerts.
struct InlineHint: View {
    let icon: String
    let text: String
    var tint: Color = .appWorking

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(text)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

// MARK: - Library toolbar

/// Shared toolbar for the list pages (Snippets, Dictionary): a search field and
/// a prominent add button, aligned to the page inset.
struct LibraryToolbar: View {
    let searchPlaceholder: String
    @Binding var searchText: String
    let addTitle: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.md) {
            SearchField(placeholder: searchPlaceholder, text: $searchText)
            Spacer()
            Button(action: onAdd) {
                Label(addTitle, systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }
}

// MARK: - Library row

/// One row in a card-based list page (Snippets, Dictionary). Title, an optional
/// subtitle, a trailing badge cluster, and edit/delete actions — the single row
/// layout both pages share instead of two divergent hand-built `HStack`s.
struct LibraryRow<Badges: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var badges: () -> Badges
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .font(.dsBody)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: DS.Space.sm) { badges() }
            }
            Spacer(minLength: 0)
            HStack(spacing: DS.Space.xs) {
                IconActionButton(systemName: "pencil", action: onEdit)
                IconActionButton(systemName: "trash", tint: .secondary, action: onDelete)
            }
        }
        .padding(.vertical, DS.Space.sm)
    }
}

/// Small hover-highlighting icon button used for row actions.
struct IconActionButton: View {
    let systemName: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : tint)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Wraps a set of rows in the shared card surface, inserting hairline dividers
/// between them — visually equivalent to a grouped Form section, so card-based
/// pages match General/API.
struct CardGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .dsCard(padding: DS.Space.md)
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
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))

            Button { isRevealed.toggle() } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Hide key" : "Show key")
            // Icon-only: give VoiceOver the same text as the tooltip.
            .accessibilityLabel(isRevealed ? "Hide key" : "Show key")
        }
        .creamFieldCapsule()
    }
}

// MARK: - Text field

/// A TextField styled to match the cream palette — a tinted capsule with a
/// hairline border like `CreamSecureField`, so the editable area (and the
/// cursor / spaces being typed) is clearly bounded instead of blending into
/// the surrounding form row.
struct CreamTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        // AppKit-backed so a typed trailing space renders and advances the caret
        // immediately. SwiftUI's TextField on macOS defers drawing a trailing
        // space until a following glyph gives it width, making it look like the
        // space wasn't registered.
        AppKitSingleLineField(placeholder: placeholder, text: $text)
            .frame(maxWidth: .infinity)
            .creamFieldCapsule()
    }
}

private struct CreamFieldCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
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

private extension View {
    func creamFieldCapsule() -> some View {
        modifier(CreamFieldCapsule())
    }
}

/// Borderless single-line `NSTextField` wrapper. Used by `CreamTextField` so the
/// caret tracks trailing whitespace the way every native macOS text field does.
private struct AppKitSingleLineField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
