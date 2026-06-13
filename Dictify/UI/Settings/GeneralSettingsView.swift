import SwiftUI
import ServiceManagement
import AVFoundation

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var permissionManager = PermissionManager()
    @State private var isRecordingShortcut = false
    @State private var eventMonitor: Any?

    @AppStorage("activationKey") private var activationKey: String = "fn"
    @AppStorage("middleMouseEnabled") private var middleMouseEnabled: Bool = false
    @AppStorage("refinementEnabled") private var refinementEnabled: Bool = true
    @AppStorage("refinementSpeedMode") private var refinementSpeedMode: String = "quality"
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("soundEffectsEnabled") private var soundEffectsEnabled: Bool = true
    @AppStorage("showElapsedTime") private var showElapsedTime: Bool = true
    @AppStorage("tapHoldThreshold") private var tapHoldThreshold: Double = 0.2
    @AppStorage("showInDock") private var showInDock: Bool = true
    @AppStorage("selectedInputDeviceUID") private var selectedInputDeviceUID: String = ""
    @AppStorage("appearancePreference") private var appearancePreference: String = "system"

    /// Human-readable name of the current selection, shown on the collapsed menu.
    @State private var selectedDisplayName: String = "System Default"

    var body: some View {
        SettingsScaffold {
            SettingsHeaderCard(
                icon: "gearshape",
                title: "General",
                subtitle: "Activation, transcription, and permissions."
            )

            activationCard
            microphoneCard
            transcriptionCard
            appearanceCard
            systemCard

            SettingsSectionLabel(text: "Permissions")
            permissionsCard

            onboardingCard
        }
        .onAppear {
            migrateLegacyMiddleMouseSelection()
            permissionManager.checkAll()
            syncLaunchAtLoginState()
            refreshSelectedDisplayName()
        }
        .onChange(of: selectedInputDeviceUID) { _, _ in
            refreshSelectedDisplayName()
        }
        .onDisappear { stopRecordingShortcut() }
    }

    // MARK: Activation

    private var activationCard: some View {
        SettingsCard {
            SettingsRow("Activation Key") {
                HStack(spacing: 8) {
                    if isRecordingShortcut {
                        Text("Press a modifier key…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.appAccent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(displayName(for: activationKey))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    }

                    Button(isRecordingShortcut ? "Cancel" : "Record") {
                        if isRecordingShortcut { stopRecordingShortcut() }
                        else { startRecordingShortcut() }
                    }
                    .controlSize(.small)
                }
            }

            RowDivider()

            SettingsRow("Middle Mouse Button",
                        subtitle: "Use either trigger to dictate — both stay active.") {
                Toggle("", isOn: $middleMouseEnabled).labelsHidden()
            }

            if let warning = shortcutWarning(for: activationKey) {
                RowDivider()
                warningRow(warning)
            }
            if middleMouseEnabled, let warning = shortcutWarning(for: KeyMonitor.middleMouseKey) {
                RowDivider()
                warningRow(warning)
            }

            RowDivider()

            SettingsRow("Tap/Hold Threshold",
                        subtitle: "Hold longer than this to dictate; shorter taps are cancelled.") {
                Text(String(format: "%.2fs", tapHoldThreshold))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $tapHoldThreshold, in: 0.1...0.5, step: 0.05)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
    }

    private func warningRow(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
    }

    // MARK: Microphone

    private var microphoneCard: some View {
        SettingsCard {
            SettingsRow("Input Device",
                        subtitle: "Choose which microphone Dictify records from. \"System Default\" follows your macOS sound input setting.") {
                Menu {
                    let devices = AudioDeviceManager.inputDevices()
                    let defaultName = AudioDeviceManager.defaultInputDeviceName()

                    deviceMenuItem(
                        title: defaultName.map { "System Default (\($0))" } ?? "System Default",
                        uid: "")

                    if !devices.isEmpty { Divider() }

                    ForEach(devices) { device in
                        deviceMenuItem(title: device.name, uid: device.uid)
                    }
                } label: {
                    Text(selectedDisplayName)
                }
                .fixedSize()
            }
        }
    }

    // MARK: Transcription

    private var transcriptionCard: some View {
        SettingsCard {
            SettingsRow("AI Text Refinement",
                        subtitle: "When enabled, transcriptions are cleaned up by AI to remove fillers, fix punctuation, and resolve backtracks.") {
                Toggle("", isOn: $refinementEnabled).labelsHidden()
            }

            RowDivider()

            SettingsRow("Refinement Speed",
                        subtitle: refinementSpeedMode == "fast"
                            ? "Fast uses llama-3.1-8b-instant — ~3-5× faster, slightly less polish."
                            : "Quality uses llama-3.3-70b-versatile — best cleanup, ~500-900ms per utterance.") {
                Picker("", selection: $refinementSpeedMode) {
                    Text("Quality").tag("quality")
                    Text("Fast").tag("fast")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!refinementEnabled)
            }
        }
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        SettingsCard {
            SettingsRow("Appearance",
                        subtitle: "\"System\" follows your macOS setting. Light mode uses Dictify's cream palette; dark mode keeps system colors.") {
                Picker("", selection: $appearancePreference) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: appearancePreference) { _, newValue in
                    AppDelegate.shared?.applyAppearance(newValue)
                }
            }
        }
    }

    // MARK: System

    private var systemCard: some View {
        SettingsCard {
            SettingsRow("Launch at Login") {
                Toggle("", isOn: $launchAtLogin).labelsHidden()
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
            RowDivider()
            SettingsRow("Sound Effects") {
                Toggle("", isOn: $soundEffectsEnabled).labelsHidden()
            }
            RowDivider()
            SettingsRow("Show Elapsed Time") {
                Toggle("", isOn: $showElapsedTime).labelsHidden()
            }
            RowDivider()
            SettingsRow("Show App in Dock",
                        subtitle: "When off, Dictify keeps running in the menu bar but its Dock icon is hidden.") {
                Toggle("", isOn: $showInDock).labelsHidden()
                    .onChange(of: showInDock) { _, newValue in
                        AppDelegate.shared?.applyDockVisibility(showInDock: newValue)
                    }
            }
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        SettingsCard {
            SettingsRow("Microphone") {
                permissionPill(granted: permissionManager.microphoneGranted)
            }
            RowDivider()
            SettingsRow("Accessibility") {
                permissionPill(granted: permissionManager.accessibilityGranted)
            }
            RowDivider()
            HStack(spacing: 8) {
                Button("Open Microphone Settings") {
                    Task { await permissionManager.promptOrOpenMicrophoneSettings() }
                }
                Button("Open Accessibility Settings") {
                    permissionManager.openAccessibilitySettings()
                }
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
    }

    private func permissionPill(granted: Bool) -> some View {
        StatusPill(text: granted ? "Granted" : "Not granted",
                   tint: granted ? .appReady : .appAlert)
    }

    // MARK: Onboarding

    private var onboardingCard: some View {
        SettingsCard {
            SettingsRow("Replay the welcome tour") {
                Button("Replay Onboarding") {
                    AppDelegate.shared?.replayOnboarding()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func displayName(for key: String) -> String {
        switch key {
        case "control": return "⌃ Control"
        case "option": return "⌥ Option"
        case "command": return "⌘ Command"
        case "shift": return "⇧ Shift"
        case KeyMonitor.middleMouseKey: return "Middle Click"
        default: return "fn"
        }
    }

    private func shortcutWarning(for key: String) -> String? {
        KeyMonitor.detectConflict(for: key)
    }

    /// Older builds stored `middleMouse` directly in `activationKey`, where it
    /// *replaced* the modifier. Split that into the new additive model: enable
    /// the mouse trigger and fall the modifier back to fn.
    private func migrateLegacyMiddleMouseSelection() {
        guard activationKey == KeyMonitor.middleMouseKey else { return }
        middleMouseEnabled = true
        activationKey = "fn"
    }

    private func startRecordingShortcut() {
        isRecordingShortcut = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var detected: String?

            if flags.contains(.command) {
                detected = "command"
            } else if flags.contains(.shift) {
                detected = "shift"
            } else if flags.contains(.control) {
                detected = "control"
            } else if flags.contains(.option) {
                detected = "option"
            } else if flags.contains(.function) {
                detected = "fn"
            }

            if let key = detected {
                activationKey = key
                stopRecordingShortcut()
            }
            return event
        }
    }

    private func stopRecordingShortcut() {
        isRecordingShortcut = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {}
        }
    }

    @ViewBuilder
    private func deviceMenuItem(title: String, uid: String) -> some View {
        Button {
            selectedInputDeviceUID = uid
        } label: {
            if selectedInputDeviceUID == uid {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Resolves the stored UID to a display name for the collapsed menu label.
    private func refreshSelectedDisplayName() {
        if selectedInputDeviceUID.isEmpty {
            let name = AudioDeviceManager.defaultInputDeviceName()
            selectedDisplayName = name.map { "System Default (\($0))" } ?? "System Default"
        } else if let device = AudioDeviceManager.inputDevices().first(where: { $0.uid == selectedInputDeviceUID }) {
            selectedDisplayName = device.name
        } else {
            selectedDisplayName = "Unavailable device"
        }
    }

    private func syncLaunchAtLoginState() {
        guard #available(macOS 13.0, *) else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
