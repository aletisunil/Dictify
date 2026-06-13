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
        Form {
            Section("Activation Triggers") {
                HStack {
                    Text("Activation Key")
                    Spacer()
                    if isRecordingShortcut {
                        Text("Press a modifier key...")
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
                        if isRecordingShortcut {
                            stopRecordingShortcut()
                        } else {
                            startRecordingShortcut()
                        }
                    }
                    .controlSize(.small)
                }

                // Middle click can't be captured via the modifier-key recorder,
                // so it's an independent, additive trigger: the modifier key
                // above and middle click both work at once. Handy on compact
                // (e.g. 75%) keyboards that lack an fn key.
                Toggle("Middle Mouse Button", isOn: $middleMouseEnabled)
                Text("Use either trigger to dictate — both stay active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = shortcutWarning(for: activationKey) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if middleMouseEnabled, let warning = shortcutWarning(for: KeyMonitor.middleMouseKey) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("Tap/Hold Threshold")
                    Spacer()
                    Text(String(format: "%.2fs", tapHoldThreshold))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $tapHoldThreshold, in: 0.1...0.5, step: 0.05)
                Text("Hold longer than this to dictate; shorter taps are cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .creamFormRow()

            Section("Microphone") {
                HStack {
                    Text("Input Device")
                    Spacer()
                    Menu {
                        // The content closure re-runs each time the menu opens,
                        // so the list reflects devices connected/removed since
                        // the window was last shown — no manual refresh needed.
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
                Text("Choose which microphone Dictify records from. \"System Default\" follows your macOS sound input setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .creamFormRow()

            Section("Transcription") {
                Toggle("AI Text Refinement", isOn: $refinementEnabled)
                Text("When enabled, transcriptions are cleaned up by AI to remove fillers, fix punctuation, and resolve backtracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Refinement Speed")
                    Spacer()
                    Picker("", selection: $refinementSpeedMode) {
                        Text("Quality").tag("quality")
                        Text("Fast").tag("fast")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!refinementEnabled)

                Text(refinementSpeedMode == "fast"
                     ? "Fast uses llama-3.1-8b-instant — ~3-5× faster, slightly less polish."
                     : "Quality uses llama-3.3-70b-versatile — best cleanup, ~500-900ms per utterance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .creamFormRow()

            Section("Appearance") {
                HStack {
                    Text("Appearance")
                    Spacer()
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
                Text("\"System\" follows your macOS setting. Light mode uses Dictify's cream palette; dark mode keeps system colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .creamFormRow()

            Section("System") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Toggle("Sound Effects", isOn: $soundEffectsEnabled)

                Toggle("Show Elapsed Time", isOn: $showElapsedTime)

                Toggle("Show App in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, newValue in
                        AppDelegate.shared?.applyDockVisibility(showInDock: newValue)
                    }
                Text("When off, Dictify keeps running in the menu bar but its Dock icon is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .creamFormRow()

            Section("Permissions") {
                HStack {
                    Label("Microphone", systemImage: "mic.fill")
                    Spacer()
                    permissionBadge(granted: permissionManager.microphoneGranted)
                }

                HStack {
                    Label("Accessibility", systemImage: "accessibility")
                    Spacer()
                    permissionBadge(granted: permissionManager.accessibilityGranted)
                }

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
            }
            .creamFormRow()

            Section("Onboarding") {
                HStack {
                    Text("Replay the welcome tour")
                    Spacer()
                    Button("Replay Onboarding") {
                        AppDelegate.shared?.replayOnboarding()
                    }
                    .controlSize(.small)
                }
            }
            .creamFormRow()
        }
        .formStyle(.grouped)
        .creamFormBackground()
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

    @ViewBuilder
    private func permissionBadge(granted: Bool) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Not Granted", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

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
