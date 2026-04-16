import Cocoa
import AVFoundation

@MainActor
final class PermissionManager: ObservableObject {
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    private var accessibilityPollTask: Task<Void, Never>?
    private let systemSettingsBundleIdentifiers = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences"
    ]

    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    init() {
        checkAll()
    }

    func checkAll() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
    }

    func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            microphoneGranted = false
        default:
            microphoneGranted = false
        }
    }

    func requestMicrophonePermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneGranted = granted
        return granted
    }

    func checkAccessibilityPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        checkAccessibilityPermission()
    }

    func openAccessibilitySettings() {
        requestAccessibilityPermission()
        openFirstWorkingURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ])
    }

    func openMicrophoneSettings() {
        openFirstWorkingURL([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ])
    }

    private func openFirstWorkingURL(_ urlStrings: [String]) {
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) {
                bringSystemSettingsToFront()
                return
            }
        }
    }

    private func bringSystemSettingsToFront(attemptsRemaining: Int = 8) {
        guard attemptsRemaining > 0 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }

            if let settingsApp = self.runningSystemSettingsApp() {
                settingsApp.unhide()
                settingsApp.activate(options: [.activateAllWindows])
            } else {
                self.bringSystemSettingsToFront(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func runningSystemSettingsApp() -> NSRunningApplication? {
        for bundleIdentifier in systemSettingsBundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                return app
            }
        }

        return nil
    }

    func startPollingAccessibility(
        timeout: TimeInterval = 30,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = Task { @MainActor [weak self] in
            let startedAt = Date()

            while !Task.isCancelled {
                guard let self = self else { return }

                self.checkAccessibilityPermission()
                if self.accessibilityGranted {
                    self.accessibilityPollTask = nil
                    completion(true)
                    return
                }

                if Date().timeIntervalSince(startedAt) >= timeout {
                    self.accessibilityPollTask = nil
                    completion(false)
                    return
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPollingAccessibility() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
    }

    deinit {
        accessibilityPollTask?.cancel()
    }
}
