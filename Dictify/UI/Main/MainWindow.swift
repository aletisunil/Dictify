import SwiftUI
import AppKit

// MARK: - Navigation

enum MainTab: Hashable, Identifiable {
    case home
    case history
    case snippets
    case dictionary
    case general
    case api
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .snippets: return "Snippets"
        case .dictionary: return "Dictionary"
        case .general: return "General"
        case .api: return "API"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .history: return "clock"
        case .snippets: return "text.badge.plus"
        case .dictionary: return "character.book.closed"
        case .general: return "gearshape"
        case .api: return "key"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State var selection: MainTab = .home
    var showMissingGroqAPIKeyWarning: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .frame(minWidth: 640)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                sidebarRow(.home)
                sidebarRow(.history)
            } header: {
                sectionHeader("Activity")
            }

            Section {
                sidebarRow(.snippets)
                sidebarRow(.dictionary)
            } header: {
                sectionHeader("Library")
            }

            Section {
                sidebarRow(.general)
                sidebarRow(.api)
                sidebarRow(.about)
            } header: {
                sectionHeader("Preferences")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            sidebarBrand
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarStatusFooter
        }
    }

    private func sidebarRow(_ tab: MainTab) -> some View {
        Label {
            Text(tab.title)
                .font(.system(size: 13))
        } icon: {
            Image(systemName: tab.icon)
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
        }
        .tag(tab)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .tracking(0.6)
    }

    private var sidebarBrand: some View {
        HStack(spacing: 10) {
            DictifyMarkIcon(size: 28, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text("Dictify")
                    .font(.system(size: 14, weight: .semibold))
                Text("Voice to Text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var sidebarStatusFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)
                Text(statusFooterLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var statusTint: Color {
        switch appState.pipelineState {
        case .idle: return appState.hasAPIKeyConfigured ? .green : .red
        case .recording: return .red
        case .transcribing, .refining, .inserting: return .orange
        case .error: return .red
        }
    }

    private var statusFooterLabel: String {
        if !appState.hasAPIKeyConfigured { return "API key required" }
        switch appState.pipelineState {
        case .idle: return "Ready"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .refining: return "Refining…"
        case .inserting: return "Inserting…"
        case .error(let msg): return msg
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            HomeView(onJumpToHistory: { selection = .history },
                     onJumpToAPI: { selection = .api })
                .environmentObject(appState)
        case .history:
            HistoryView()
                .environmentObject(appState)
        case .snippets:
            SnippetsSettingsView()
                .environmentObject(appState)
                .navigationTitle("Snippets")
        case .dictionary:
            DictionarySettingsView()
                .environmentObject(appState)
                .navigationTitle("Dictionary")
        case .general:
            GeneralSettingsView()
                .environmentObject(appState)
                .navigationTitle("General")
        case .api:
            APISettingsView(showMissingGroqAPIKeyWarning: showMissingGroqAPIKeyWarning)
                .environmentObject(appState)
                .navigationTitle("API")
        case .about:
            AboutSettingsView()
                .navigationTitle("About")
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var permissionManager = PermissionManager()
    @AppStorage("activationKey") private var activationKey: String = "fn"
    let onJumpToHistory: () -> Void
    let onJumpToAPI: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroCard

                if appState.permissionReGrantNeeded {
                    permissionBanner
                }

                if !appState.hasAPIKeyConfigured {
                    apiKeyBanner
                }

                statsRow

                recentSection
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { permissionManager.refreshAll() }
    }

    // Hero: status + activation hint
    private var heroCard: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 56, height: 56)
                Image(systemName: heroIcon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(heroIconTint)
                    .symbolEffect(.pulse, options: .repeating, isActive: appState.pipelineState == .recording)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(heroTitle)
                    .font(.system(size: 18, weight: .semibold))
                Text(heroSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            shortcutChip
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var heroIconTint: Color {
        switch appState.pipelineState {
        case .recording: return .red
        case .transcribing, .refining, .inserting: return .orange
        case .error: return .red
        default: return .primary
        }
    }

    private var heroIcon: String {
        switch appState.pipelineState {
        case .recording: return "waveform"
        case .transcribing, .refining, .inserting: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        default: return "mic.fill"
        }
    }

    private var heroTitle: String {
        switch appState.pipelineState {
        case .idle:
            return appState.hasAPIKeyConfigured ? "Ready to dictate" : "Set up Dictify"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .refining: return "Refining"
        case .inserting: return "Inserting"
        case .error(let msg): return msg
        }
    }

    private var heroSubtitle: String {
        if !appState.hasAPIKeyConfigured {
            return "Add your Groq API key to begin — it is stored in Apple Keychain."
        }
        switch appState.pipelineState {
        case .recording: return "Release to transcribe. Tap the key briefly to cancel."
        case .transcribing: return "Sending audio to Whisper."
        case .refining: return "Polishing text with Llama."
        case .inserting: return "Pasting into the active app."
        case .error: return "Check the status and try again."
        default:
            return "Hold the activation key anywhere on macOS and speak."
        }
    }

    private var shortcutChip: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("ACTIVATION")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Text(activationKeyGlyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
    }

    private var activationKeyGlyph: String {
        switch activationKey {
        case "control": return "⌃ Control"
        case "option": return "⌥ Option"
        case "command": return "⌘ Command"
        case "shift": return "⇧ Shift"
        default: return "fn"
        }
    }

    // Banners
    private var permissionBanner: some View {
        let micMissing = !permissionManager.microphoneGranted
        let axMissing = !permissionManager.accessibilityGranted
        return HomeBanner(
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            title: "Permission needed",
            message: "Re-grant \(missingLabel(mic: micMissing, ax: axMissing)) so Dictify can keep working."
        ) {
            HStack(spacing: 8) {
                if micMissing {
                    Button("Open Mic Settings") { permissionManager.openMicrophoneSettings() }
                }
                if axMissing {
                    Button("Open Accessibility Settings") { permissionManager.openAccessibilitySettings() }
                }
            }
            .controlSize(.small)
        }
    }

    private func missingLabel(mic: Bool, ax: Bool) -> String {
        if mic && ax { return "Microphone and Accessibility" }
        if mic { return "Microphone" }
        return "Accessibility"
    }

    private var apiKeyBanner: some View {
        HomeBanner(
            icon: "key.fill",
            tint: .blue,
            title: "Groq API key required",
            message: "Dictify needs a Groq API key to transcribe. Your key is stored in Apple Keychain."
        ) {
            Button("Configure API Key") { onJumpToAPI() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    // Stats
    private var statsRow: some View {
        HStack(spacing: 14) {
            if let stats = appState.statsStore {
                StatCard(icon: "text.word.spacing",
                         title: "Session words",
                         value: "\(stats.sessionWords)",
                         subtitle: wpmString(stats.sessionWPM) + " wpm")
                StatCard(icon: "sum",
                         title: "Total words",
                         value: "\(stats.totalWords)",
                         subtitle: wpmString(stats.totalWPM) + " wpm")
                StatCard(icon: "clock.arrow.circlepath",
                         title: "Transcriptions",
                         value: "\(appState.historyStore?.records.count ?? 0)",
                         subtitle: "recorded")
            }
        }
    }

    private func wpmString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    // Recent
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let historyStore = appState.historyStore, !historyStore.records.isEmpty {
                    Button("View all") { onJumpToHistory() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.blue)
                }
            }

            if let historyStore = appState.historyStore, !historyStore.records.isEmpty {
                VStack(spacing: 8) {
                    ForEach(historyStore.records.prefix(5)) { record in
                        TranscriptionCardRow(record: record)
                    }
                }
            } else {
                EmptyStateCard(
                    icon: "mic.slash",
                    title: "No transcriptions yet",
                    subtitle: "Hold \(activationKeyGlyph) anywhere on macOS to dictate."
                )
            }
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var confirmClear = false

    private var filtered: [TranscriptionRecord] {
        guard let records = appState.historyStore?.records else { return [] }
        if searchText.isEmpty { return records }
        return records.filter { $0.refinedText.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    TextField("Search transcriptions", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )

                Spacer()

                if let historyStore = appState.historyStore, !historyStore.records.isEmpty {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            if filtered.isEmpty {
                EmptyStateCard(
                    icon: searchText.isEmpty ? "clock" : "magnifyingglass",
                    title: searchText.isEmpty ? "No history yet" : "No matches",
                    subtitle: searchText.isEmpty
                        ? "Your dictation history will appear here."
                        : "Try a different search term."
                )
                .padding(24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { record in
                            TranscriptionCardRow(record: record, expanded: true)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("History")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Clear all transcription history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) { appState.historyStore?.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - Reusable Cards

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct HomeBanner<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tint.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

struct TranscriptionCardRow: View {
    let record: TranscriptionRecord
    var expanded: Bool = false
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.refinedText)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(record.date, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            Button(action: copyText) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? .green : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Copy transcription")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.refinedText, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

// MARK: - Brand Mark

struct DictifyMarkIcon: View {
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 7

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(0.08))
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            WaveformMark()
                .stroke(Color.primary, style: StrokeStyle(lineWidth: max(1.2, size * 0.08), lineCap: .round))
                .padding(size * 0.24)
        }
        .frame(width: size, height: size)
    }
}

private struct WaveformMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let heights: [CGFloat] = [0.40, 0.70, 1.0, 0.55, 0.85, 0.35]
        let count = heights.count
        let spacing = rect.width / CGFloat(count - 1)
        for (i, h) in heights.enumerated() {
            let x = rect.minX + CGFloat(i) * spacing
            let barHeight = rect.height * h
            let y1 = rect.midY - barHeight / 2
            let y2 = rect.midY + barHeight / 2
            path.move(to: CGPoint(x: x, y: y1))
            path.addLine(to: CGPoint(x: x, y: y2))
        }
        return path
    }
}
