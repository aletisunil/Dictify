import Foundation

/// Plain-UserDefaults wrapper for non-view callers (AppDelegate, pipeline, AppState).
/// Views bind to the same keys via `@AppStorage` directly — nesting `@AppStorage`
/// inside an `ObservableObject` caused overlapping publishes when the same key
/// was observed from multiple instances, producing SwiftUI's "Publishing changes
/// from within view updates" warning.
@MainActor
final class DictifySettings {
    private let defaults = UserDefaults.standard

    var activationKey: String {
        get { defaults.string(forKey: "activationKey") ?? "fn" }
        set { defaults.set(newValue, forKey: "activationKey") }
    }

    var refinementEnabled: Bool {
        get { defaults.object(forKey: "refinementEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "refinementEnabled") }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var soundEffectsEnabled: Bool {
        get { defaults.object(forKey: "soundEffectsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "soundEffectsEnabled") }
    }

    var showElapsedTime: Bool {
        get { defaults.object(forKey: "showElapsedTime") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showElapsedTime") }
    }

    var tapHoldThreshold: Double {
        get { defaults.object(forKey: "tapHoldThreshold") as? Double ?? 0.2 }
        set { defaults.set(newValue, forKey: "tapHoldThreshold") }
    }

    var showInDock: Bool {
        get { defaults.object(forKey: "showInDock") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showInDock") }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// "quality" (llama-3.3-70b-versatile) or "fast" (llama-3.1-8b-instant).
    var refinementSpeedMode: String {
        get { defaults.string(forKey: "refinementSpeedMode") ?? "quality" }
        set { defaults.set(newValue, forKey: "refinementSpeedMode") }
    }

    /// Core Audio UID of the preferred microphone. Empty string means "follow
    /// the macOS system default input device".
    var selectedInputDeviceUID: String {
        get { defaults.string(forKey: "selectedInputDeviceUID") ?? "" }
        set { defaults.set(newValue, forKey: "selectedInputDeviceUID") }
    }
}
