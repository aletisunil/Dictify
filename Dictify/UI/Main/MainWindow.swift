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
        // App-wide accent: clay sidebar selection, toggles, and prominent
        // buttons instead of the cool system blue that fought the cream.
        .tint(Color.appAccent)
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
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            sidebarBrand
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarStatusFooter
        }
        .background(Color.appSidebarBackground)
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
            AppIconImage(size: 28, cornerRadius: 8)
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
        case .idle: return appState.hasAPIKeyConfigured ? .appReady : .appAlert
        case .recording: return .appAlert
        case .transcribing, .refining, .inserting: return .appWorking
        case .error: return .appAlert
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
    @AppStorage("middleMouseEnabled") private var middleMouseEnabled: Bool = false
    @State private var isRequestingMicrophonePermission = false
    @State private var isRequestingAccessibilityPermission = false
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

                if let historyStore = appState.historyStore {
                    ContributionGraphView(records: historyStore.records)
                }

                recentSection
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appWindowBackground)
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
                .fill(Color.appCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appHairline, lineWidth: 1)
        )
    }

    private var heroIconTint: Color {
        switch appState.pipelineState {
        case .recording: return .appAlert
        case .transcribing, .refining, .inserting: return .appWorking
        case .error: return .appAlert
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
        case .refining: return "Polishing text with GPT-OSS."
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
        // Legacy `middleMouse` stored in activationKey means mouse-only.
        if activationKey == KeyMonitor.middleMouseKey { return "Middle Click" }

        let modifier: String
        switch activationKey {
        case "control": modifier = "⌃ Control"
        case "option": modifier = "⌥ Option"
        case "command": modifier = "⌘ Command"
        case "shift": modifier = "⇧ Shift"
        default: modifier = "fn"
        }
        return middleMouseEnabled ? "\(modifier) / Middle Click" : modifier
    }

    // Banners
    private var permissionBanner: some View {
        let micMissing = !permissionManager.microphoneGranted
        let axMissing = !permissionManager.accessibilityGranted
        return HomeBanner(
            icon: "exclamationmark.triangle.fill",
            tint: Color.appAccent,
            title: "Permission needed",
            message: "Re-grant \(missingLabel(mic: micMissing, ax: axMissing)) so Dictify can keep working."
        ) {
            HStack(spacing: 8) {
                if micMissing {
                    Button(micButtonLabel) { handleMicrophoneAction() }
                }
                if axMissing {
                    Button(axButtonLabel) { handleAccessibilityAction() }
                }
            }
            .controlSize(.small)
        }
    }

    private var micButtonLabel: String {
        if permissionManager.microphoneDenied {
            return isRequestingMicrophonePermission ? "Check Again" : "Open Mic Settings"
        }
        return "Enable Microphone"
    }

    private var axButtonLabel: String {
        isRequestingAccessibilityPermission ? "Check Again" : "Open Accessibility Settings"
    }

    private func handleMicrophoneAction() {
        // Mirror the onboarding flow: if the status is `.notDetermined`, show
        // the native TCC popup. If it was previously denied, `requestAccess` is
        // a no-op — send the user to System Settings and poll until they
        // re-grant.
        if permissionManager.microphoneDenied {
            permissionManager.checkMicrophonePermission()
            if permissionManager.microphoneGranted {
                isRequestingMicrophonePermission = false
                return
            }
            permissionManager.openMicrophoneSettings()
            isRequestingMicrophonePermission = true
            permissionManager.startPollingMicrophone { _ in
                isRequestingMicrophonePermission = false
                permissionManager.checkAll()
            }
            return
        }
        Task {
            let granted = await permissionManager.requestMicrophonePermission()
            if granted {
                permissionManager.checkAll()
            } else {
                permissionManager.checkMicrophonePermission()
            }
        }
    }

    private func handleAccessibilityAction() {
        permissionManager.checkAll()
        if permissionManager.accessibilityGranted {
            isRequestingAccessibilityPermission = false
            return
        }
        permissionManager.openAccessibilitySettings()
        isRequestingAccessibilityPermission = true
        permissionManager.startPollingAccessibility { _ in
            isRequestingAccessibilityPermission = false
            permissionManager.checkAll()
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
            tint: .appAccent,
            title: "Groq API key required",
            message: "Dictify needs a Groq API key to transcribe. Your key is stored in Apple Keychain."
        ) {
            Button("Configure API Key") { onJumpToAPI() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    // Stats
    private let statsColumns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    @ViewBuilder
    private var statsRow: some View {
        if let stats = appState.statsStore {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: statsColumns, spacing: 14) {
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
                             value: "\(stats.totalDictations)",
                             subtitle: "recorded")
                    StatCard(icon: "flame",
                             title: "Current streak",
                             value: "\(stats.currentStreak)",
                             subtitle: dayUnit(stats.currentStreak))
                    StatCard(icon: "calendar",
                             title: "Active days",
                             value: "\(stats.activeDays)",
                             subtitle: "dictated")
                    StatCard(icon: "clock",
                             title: "Speaking time",
                             value: durationString(stats.totalSpeakingSeconds),
                             subtitle: "spoken")
                    StatCard(icon: "clock.badge",
                             title: "Peak hour",
                             value: hourString(stats.peakHour),
                             subtitle: "most active")
                    StatCard(icon: "calendar.day.timeline.left",
                             title: "Busiest day",
                             value: weekdayString(stats.busiestWeekday),
                             subtitle: "favorite day")
                }

                if let saved = savedVsTypingString(stats.estimatedMinutesSavedVsTyping) {
                    Text(saved)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func wpmString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    private func dayUnit(_ count: Int) -> String {
        count == 1 ? "day" : "days"
    }

    /// "1h 23m", "23m", or "45s" — em-dash when there's nothing to show.
    private func durationString(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// 24h hour index → "11 PM"; em-dash when nil.
    private func hourString(_ hour: Int?) -> String {
        guard let hour else { return "—" }
        var comps = DateComponents()
        comps.hour = hour
        guard let date = Calendar.current.date(from: comps) else { return "—" }
        return date.formatted(.dateTime.hour())
    }

    /// Calendar weekday (1 = Sunday) → "Mon"; em-dash when nil.
    private func weekdayString(_ weekday: Int?) -> String {
        guard let weekday else { return "—" }
        let symbols = Calendar.current.shortWeekdaySymbols
        guard weekday >= 1, weekday <= symbols.count else { return "—" }
        return symbols[weekday - 1]
    }

    /// Fun comparison line; nil when savings are negligible.
    private func savedVsTypingString(_ minutes: Double) -> String? {
        guard minutes >= 1 else { return nil }
        let value: String
        if minutes >= 60 {
            let hours = minutes / 60
            value = hours.formatted(.number.precision(.fractionLength(hours >= 10 ? 0 : 1))) + "h"
        } else {
            value = "\(Int(minutes.rounded()))m"
        }
        return "You've saved ~\(value) vs typing at 40 wpm."
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
                        .foregroundStyle(Color.appAccent)
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
        return records.filter {
            $0.refinedText.localizedCaseInsensitiveContains(searchText)
                || $0.rawText.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Records grouped by calendar day, newest day first. Records inside each
    /// group keep their store order (newest first).
    private var groupedByDay: [(day: Date, records: [TranscriptionRecord])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { (day: $0, records: groups[$0] ?? []) }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SearchField(placeholder: "Search transcriptions", text: $searchText)

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
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groupedByDay, id: \.day) { group in
                            Text(dayTitle(group.day))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, 10)
                                .padding(.leading, 4)
                            ForEach(group.records) { record in
                                TranscriptionCardRow(record: record, expanded: true,
                                                     editable: true, showsExactTime: true)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("History")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appWindowBackground)
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
                .fill(Color.appCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.appHairline, lineWidth: 1)
        )
    }
}

struct HomeBanner<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    init(icon: String, tint: Color, title: String, message: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.actions = actions
    }

    /// Message-only banner (no action buttons) — used for inline save errors.
    init(icon: String, tint: Color, title: String, message: String) where Actions == EmptyView {
        self.init(icon: icon, tint: tint, title: title, message: message) { EmptyView() }
    }

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
    @EnvironmentObject var appState: AppState
    let record: TranscriptionRecord
    var expanded: Bool = false
    /// When true, the row exposes inline editing of the transcription text
    /// (used in the full History view).
    var editable: Bool = false
    /// Show time-of-day instead of a relative date (History view has day
    /// headers, so the relative date would be redundant).
    var showsExactTime: Bool = false

    @State private var copied = false
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var showComparison = false
    @State private var hovering = false

    /// Records saved before raw text was captured (or where refinement made no
    /// change) have nothing to compare, so the before/after toggle is hidden.
    private var hasComparison: Bool {
        !record.rawText.isEmpty && record.rawText != record.refinedText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if isEditing {
                        TextEditor(text: $draftText)
                            .font(.system(size: 13))
                            .frame(minHeight: 60)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    } else {
                        Text(record.refinedText)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(expanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        if showsExactTime {
                            Text(record.date, format: .dateTime.hour().minute())
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(record.date, style: .relative)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        if record.durationSeconds >= 1 {
                            Text(durationText)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        if record.edited {
                            Label("Edited", systemImage: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if hasComparison {
                            Label("Refined", systemImage: "sparkles")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if copied {
                            Label("Copied", systemImage: "checkmark")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()

                if !isEditing {
                    HStack(spacing: 4) {
                        if editable {
                            IconButton(systemName: "pencil", help: "Edit transcription") {
                                draftText = record.refinedText
                                withMotionAnimation(.easeOut(duration: 0.12)) { isEditing = true }
                            }
                        }
                        IconButton(systemName: copied ? "checkmark" : "doc.on.doc",
                                   tint: copied ? .green : .secondary,
                                   help: "Copy transcription") {
                            copyText()
                        }
                    }
                    .opacity(hovering || copied ? 1 : 0)
                }
            }

            if showComparison && !isEditing {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    if let diff = TranscriptDiff.attributed(from: record.rawText, to: record.refinedText) {
                        ComparisonBlock(label: "Changes", icon: "sparkles", attributed: diff)
                    } else {
                        // Refinement rewrote nearly everything; a word diff
                        // would be noise, so show the original text plainly.
                        ComparisonBlock(label: "Original", icon: "waveform", text: record.rawText)
                    }
                }
            }

            if isEditing {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") {
                        withMotionAnimation(.easeOut(duration: 0.12)) { isEditing = false }
                    }
                    .controlSize(.small)
                    Button("Save") { saveEdit() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appHairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard hasComparison, !isEditing else { return }
            withMotionAnimation(.easeOut(duration: 0.12)) { showComparison.toggle() }
        }
        .onHover { isOver in
            withMotionAnimation(.easeOut(duration: 0.12)) { hovering = isOver }
        }
        .help(hasComparison ? "Click to compare with the original transcription" : "")
    }

    private var durationText: String {
        let seconds = Int(record.durationSeconds.rounded())
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func saveEdit() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed != record.refinedText {
            var updated = record
            updated.refinedText = trimmed
            updated.edited = true
            appState.historyStore?.update(updated)
        }

        withMotionAnimation(.easeOut(duration: 0.12)) { isEditing = false }
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.refinedText, forType: .string)
        withMotionAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withMotionAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

/// One labeled text block inside the before/after refinement comparison.
private struct ComparisonBlock: View {
    let label: String
    let icon: String
    let attributed: AttributedString

    init(label: String, icon: String, attributed: AttributedString) {
        self.label = label
        self.icon = icon
        self.attributed = attributed
    }

    init(label: String, icon: String, text: String) {
        self.init(label: label, icon: icon, attributed: AttributedString(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(attributed)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
        }
    }
}

/// Word-level diff between the raw transcription and the refined text,
/// rendered as one merged block: removed words in red strikethrough,
/// added words in green, unchanged words dimmed.
private enum TranscriptDiff {
    private enum Kind {
        case same, removed, added
    }

    /// Marker token representing a paragraph break, so the diff keeps the
    /// refined text's line structure without diffing raw whitespace (which
    /// makes removed and added words collide when rendered).
    private static let newline = "\n"

    static func attributed(from old: String, to new: String) -> AttributedString? {
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        // Diff cost grows with edit distance; dictation snippets are short,
        // but guard against pathological inputs.
        guard oldTokens.count <= 2000, newTokens.count <= 2000 else { return nil }

        let difference = newTokens.difference(from: oldTokens)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        // If refinement rewrote nearly everything, a merged diff is unreadable.
        let changed = removedOffsets.count + insertedOffsets.count
        let total = oldTokens.count + newTokens.count
        guard total > 0, Double(changed) / Double(total) <= 0.7 else { return nil }

        var result = AttributedString()
        func append(_ token: String, _ kind: Kind) {
            if token == newline {
                result += AttributedString(newline)
                return
            }
            var run = AttributedString(token)
            switch kind {
            case .same:
                run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .secondary
            case .removed:
                run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .red
                run[AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute.self] = .single
            case .added:
                // Underline as well as green so additions survive red-green
                // color blindness (removed text has strikethrough for the same
                // reason).
                run[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .green
                run[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            }
            result += run
            result += AttributedString(" ")
        }

        var i = 0, j = 0
        while i < oldTokens.count || j < newTokens.count {
            if i < oldTokens.count, removedOffsets.contains(i) {
                append(oldTokens[i], .removed)
                i += 1
            } else if j < newTokens.count, insertedOffsets.contains(j) {
                append(newTokens[j], .added)
                j += 1
            } else if i < oldTokens.count, j < newTokens.count {
                append(newTokens[j], .same)
                i += 1
                j += 1
            } else {
                // Offsets from CollectionDifference always consume both
                // sequences fully, so this is unreachable; bail defensively.
                return nil
            }
        }

        while let last = result.characters.last, last == " " || last == "\n" {
            result.removeSubrange(result.index(beforeCharacter: result.endIndex)..<result.endIndex)
        }
        return result
    }

    /// Splits text into word tokens, with a marker token for whitespace runs
    /// containing a line break so paragraph structure survives the diff.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        var whitespaceHadNewline = false
        func flushWord() {
            if !word.isEmpty {
                tokens.append(word)
                word = ""
            }
        }
        for char in text {
            if char.isWhitespace {
                flushWord()
                if char.isNewline { whitespaceHadNewline = true }
            } else {
                if whitespaceHadNewline {
                    tokens.append(newline)
                    whitespaceHadNewline = false
                }
                word.append(char)
            }
        }
        flushWord()
        return tokens
    }
}

/// Small square icon button with its own hover highlight, so each button in a
/// row reacts independently rather than sharing one hover state.
private struct IconButton: View {
    let systemName: String
    var tint: Color = .secondary
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        // Icon-only: without this VoiceOver reads the SF Symbol name or nothing.
        .accessibilityLabel(help)
    }
}

// MARK: - Contribution Graph

/// GitHub-style activity heatmap: one cell per day for the last year, tinted by
/// how many transcriptions happened that day. Derived entirely from history, so
/// it needs no separate tracking.
struct ContributionGraphView: View {
    let records: [TranscriptionRecord]

    private let weeks = 53
    private let scrollEndID = "contribution-graph-end"
    private let cell: CGFloat = 11
    private let spacing: CGFloat = 3
    private let monthRowHeight: CGFloat = 15
    private let headerGap: CGFloat = 5

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = .current // otherwise month symbols fall back to "M01"…"M12"
        cal.firstWeekday = 1 // Sunday-led columns, like GitHub
        return cal
    }

    /// Transcriptions per calendar day, keyed by start-of-day.
    private var countsByDay: [Date: Int] {
        let cal = calendar
        var dict: [Date: Int] = [:]
        for record in records {
            let day = cal.startOfDay(for: record.date)
            dict[day, default: 0] += 1
        }
        return dict
    }

    /// Sunday of the first (leftmost) column.
    private var startSunday: Date {
        let cal = calendar
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1 = Sunday
        let thisWeekSunday = cal.date(byAdding: .day, value: -(weekday - 1), to: today)!
        return cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeekSunday)!
    }

    private func date(week: Int, row: Int) -> Date {
        calendar.date(byAdding: .day, value: week * 7 + row, to: startSunday)!
    }

    private var totalInWindow: Int {
        let cal = calendar
        let start = startSunday
        return records.reduce(0) { sum, record in
            cal.startOfDay(for: record.date) >= start ? sum + 1 : sum
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                weekdayColumn
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: headerGap) {
                            monthLabels
                            grid
                        }
                        .id(scrollEndID)
                    }
                    .onAppear {
                        // Open anchored to the current month on the right edge,
                        // not the oldest column ~52 weeks back on the left.
                        proxy.scrollTo(scrollEndID, anchor: .trailing)
                    }
                }
            }
            footer
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.appHairline, lineWidth: 1)
        )
    }

    private var weekdayColumn: some View {
        VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                Text(weekdayLabel(row))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, height: cell, alignment: .trailing)
            }
        }
        .padding(.top, monthRowHeight + headerGap)
    }

    private func weekdayLabel(_ row: Int) -> String {
        switch row {
        case 1: return "Mon"
        case 3: return "Wed"
        case 5: return "Fri"
        default: return ""
        }
    }

    private var monthLabels: some View {
        let cal = calendar
        return HStack(spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { week in
                let columnStart = date(week: week, row: 0)
                let month = cal.component(.month, from: columnStart)
                let prevMonth = week > 0
                    ? cal.component(.month, from: date(week: week - 1, row: 0))
                    : -1
                Text(month != prevMonth ? monthAbbrev(month) : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .frame(width: cell, height: monthRowHeight, alignment: .leading)
            }
        }
    }

    private func monthAbbrev(_ month: Int) -> String {
        let symbols = calendar.shortMonthSymbols
        guard month >= 1, month <= symbols.count else { return "" }
        return symbols[month - 1]
    }

    private var grid: some View {
        let today = calendar.startOfDay(for: Date())
        let counts = countsByDay
        return HStack(spacing: spacing) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { row in
                        let day = date(week: week, row: row)
                        if day > today {
                            Color.clear.frame(width: cell, height: cell)
                        } else {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(tint(counts[day] ?? 0))
                                .frame(width: cell, height: cell)
                                .help(helpText(day: day, count: counts[day] ?? 0))
                                // Color-only cells: expose the same date+count
                                // text the tooltip shows to VoiceOver.
                                .accessibilityLabel(helpText(day: day, count: counts[day] ?? 0))
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(totalInWindow) dictation\(totalInWindow == 1 ? "" : "s") in the last year")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("Less")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            ForEach([0, 1, 3, 6, 10], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint(level))
                    .frame(width: cell, height: cell)
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func tint(_ count: Int) -> Color {
        switch count {
        case 0: return Color.primary.opacity(0.06)
        case 1...2: return Color.appReady.opacity(0.35)
        case 3...5: return Color.appReady.opacity(0.55)
        case 6...9: return Color.appReady.opacity(0.78)
        default: return Color.appReady
        }
    }

    private func helpText(day: Date, count: Int) -> String {
        let formatted = day.formatted(.dateTime.month(.abbreviated).day().year())
        if count == 0 { return "No dictations on \(formatted)" }
        return "\(count) dictation\(count == 1 ? "" : "s") on \(formatted)"
    }
}

// MARK: - Brand Mark

/// The real app icon (matches Dock/Finder), used everywhere the brand mark
/// appears so the sidebar and About page stay in sync.
struct AppIconImage: View {
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 7

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
