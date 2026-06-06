import Cocoa
import AVFoundation

@MainActor
final class PermissionManager: ObservableObject {
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    /// True when microphone access was previously denied — asking again via
    /// AVCaptureDevice.requestAccess is a no-op, so the UI must send the user
    /// to System Settings instead.
    @Published var microphoneDenied = false
    private var accessibilityPollTask: Task<Void, Never>?
    private var microphonePollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private let systemSettingsBundleIdentifiers = [
        "com.apple.systempreferences",
        "com.apple.SystemPreferences"
    ]

    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    init() {
        checkAll()
        // When Dictify regains focus (user returning from System Settings),
        // re-check both permissions immediately — no timer needed.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAll()
            }
        }
    }

    /// Called from `AppDelegate.applicationDidBecomeActive(_:)` and anywhere
    /// else that should prompt a full permission re-check. Idempotent.
    func refreshAll() {
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
            microphoneDenied = false
        case .notDetermined:
            microphoneGranted = false
            microphoneDenied = false
        default:
            microphoneGranted = false
            microphoneDenied = true
        }
    }

    func requestMicrophonePermission() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneGranted = granted
        Log.permissions.notice("Microphone permission \(granted ? "granted" : "denied", privacy: .public)")
        return granted
    }

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted {
            Log.permissions.notice("Accessibility permission changed → \(trusted ? "granted" : "not granted", privacy: .public)")
        }
        accessibilityGranted = trusted
    }

    func requestAccessibilityPermission() {
        // Only show the system "grant access" alert when we're actually not trusted.
        // AXIsProcessTrustedWithOptions(prompt:true) will re-show the dialog even
        // after the user already granted permission, which is what they see as a
        // "stuck" popup when returning from System Settings.
        guard !AXIsProcessTrusted() else {
            checkAccessibilityPermission()
            return
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        checkAccessibilityPermission()
    }

    func openAccessibilitySettings(showSystemPrompt: Bool = false) {
        // Opening the pane is silent by default. The system Accessibility alert
        // should only appear from an explicit onboarding permission action.
        if showSystemPrompt && !AXIsProcessTrusted() {
            requestAccessibilityPermission()
        }
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

    /// If microphone access has never been asked, show the system TCC prompt.
    /// Otherwise (granted/denied/restricted) send the user to System Settings,
    /// since AVCaptureDevice.requestAccess is a no-op in those states.
    func promptOrOpenMicrophoneSettings() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await requestMicrophonePermission()
            checkMicrophonePermission()
            return
        }
        openMicrophoneSettings()
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

    func startPollingMicrophone(
        timeout: TimeInterval = 60,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        microphonePollTask?.cancel()
        microphonePollTask = Task { @MainActor [weak self] in
            let startedAt = Date()

            while !Task.isCancelled {
                guard let self = self else { return }

                self.checkMicrophonePermission()
                if self.microphoneGranted {
                    self.microphonePollTask = nil
                    completion(true)
                    return
                }

                if Date().timeIntervalSince(startedAt) >= timeout {
                    self.microphonePollTask = nil
                    completion(false)
                    return
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPollingMicrophone() {
        microphonePollTask?.cancel()
        microphonePollTask = nil
    }

    func invalidate() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        microphonePollTask?.cancel()
        microphonePollTask = nil
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }
}
