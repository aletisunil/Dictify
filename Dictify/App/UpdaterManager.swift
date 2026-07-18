import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Owns the update lifecycle:
/// automatic background checks (SUEnableAutomaticChecks in Info.plist) plus
/// user-initiated checks from the menu bar and the About tab. The feed
/// (SUFeedURL) points at the appcast.xml asset attached to the latest GitHub
/// release, signed in CI with the EdDSA key matching SUPublicEDKey.
@MainActor
final class UpdaterManager {
    private let controller: SPUStandardUpdaterController
    private var started = false

    init() {
        // startingUpdater: false - scheduled checks are deferred until start()
        // so a first-run user is never interrupted by an update alert while
        // onboarding is still on screen.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Begins Sparkle's scheduled background checks. Idempotent. Called once
    /// onboarding is durably complete (immediately on launch for returning
    /// users, or when onboarding finishes on first run).
    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        start()
        controller.checkForUpdates(nil)
    }

    /// Menu item wired directly to Sparkle's controller. With the controller
    /// as target, AppKit menu validation consults the updater and disables
    /// the item automatically while a check is already in flight.
    func makeCheckForUpdatesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = controller
        return item
    }
}
