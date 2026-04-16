import SwiftUI
import ServiceManagement
import AVFoundation

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var settings = DictifySettings()
    @StateObject private var permissionManager = PermissionManager()
    @State private var isRecordingShortcut = false
    @State private var eventMonitor: Any?

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
                        Text(displayName(for: settings.activationKey))
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

                if let warning = shortcutWarning(for: settings.activationKey) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Transcription") {
                Toggle("AI Text Refinement", isOn: $settings.refinementEnabled)
                Text("When enabled, transcriptions are cleaned up by AI to remove fillers, fix punctuation, and resolve backtracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Toggle("Sound Effects", isOn: $settings.soundEffectsEnabled)

                Toggle("Show Elapsed Time", isOn: $settings.showElapsedTime)
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

                HStack {
                    Button("Open Microphone Settings") {
                        permissionManager.openMicrophoneSettings()
                    }
                    Button("Open Accessibility Settings") {
                        permissionManager.openAccessibilitySettings()
                    }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
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
        switch key {
        case "command":
            return "Command is used by most system and app shortcuts — may cause conflicts"
        case "shift":
            return "Shift is used for capitalization — may interfere with typing"
        default:
            return nil
        }
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
                settings.activationKey = key
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
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
