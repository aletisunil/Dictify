import SwiftUI
import ServiceManagement
import AVFoundation

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var permissionManager = PermissionManager()
    @State private var isRecordingShortcut = false
    @State private var eventMonitor: Any?

    @AppStorage("activationKey") private var activationKey: String = "fn"
    @AppStorage("refinementEnabled") private var refinementEnabled: Bool = true
    @AppStorage("refinementSpeedMode") private var refinementSpeedMode: String = "quality"
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("soundEffectsEnabled") private var soundEffectsEnabled: Bool = true
    @AppStorage("showElapsedTime") private var showElapsedTime: Bool = true
    @AppStorage("tapHoldThreshold") private var tapHoldThreshold: Double = 0.2
    @AppStorage("showInDock") private var showInDock: Bool = true

    var body: some View {
        Form {
            Section("Activation") {
                HStack {
                    Text("Activation Key")
                    Spacer()
                    if isRecordingShortcut {
                        Text("Press a modifier key...")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(displayName(for: activationKey))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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

                if let warning = shortcutWarning(for: activationKey) {
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
        }
        .formStyle(.grouped)
        .onAppear {
            permissionManager.checkAll()
            syncLaunchAtLoginState()
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
        default: return "fn"
        }
    }

    private func shortcutWarning(for key: String) -> String? {
        KeyMonitor.detectConflict(for: key)
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

    private func syncLaunchAtLoginState() {
        guard #available(macOS 13.0, *) else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
