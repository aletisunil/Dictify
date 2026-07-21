import AppKit
import Combine
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Owns the update lifecycle:
/// automatic background checks (SUEnableAutomaticChecks in Info.plist) plus
/// user-initiated checks from the menu bar and General settings. The feed
/// (SUFeedURL) points at the appcast.xml asset attached to the latest GitHub
/// release, signed in CI with the EdDSA key matching SUPublicEDKey.
@MainActor
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    /// False while Sparkle is starting or an update check is already running.
    @Published private(set) var canCheckForUpdates = false

    /// Sparkle persists this preference and schedules the background checks.
    /// Mirroring it through KVO keeps every updater control in sync.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }

    private let controller: SPUStandardUpdaterController
    private var started = false

    private static let relaunchMarkerURL = Constants.Storage.appSupportDirectory
        .appendingPathComponent(".sparkle-relaunch")
    private static let relaunchMarkerLifetime: TimeInterval = 5 * 60

    private init() {
        // startingUpdater: false - scheduled checks are deferred until start()
        // so a first-run user is never interrupted by an update alert while
        // onboarding is still on screen.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)

        // UpdaterManager is a process-lifetime singleton, and NotificationCenter
        // retains block observers, so this observer intentionally lives until exit.
        _ = NotificationCenter.default.addObserver(
            forName: .SUUpdaterWillRestart,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.writeRelaunchMarker()
            }
        }
    }

    /// Consumes Sparkle's cross-process relaunch marker. A short validity window
    /// prevents a failed or abandoned update from suppressing a later user launch.
    static func consumeRecentRelaunchMarker(now: Date = Date()) -> Bool {
        let markerURL = relaunchMarkerURL
        guard let data = try? Data(contentsOf: markerURL),
              let value = String(data: data, encoding: .utf8),
              let timestamp = TimeInterval(value) else {
            return false
        }

        try? FileManager.default.removeItem(at: markerURL)
        let age = now.timeIntervalSince1970 - timestamp
        return age >= 0 && age <= relaunchMarkerLifetime
    }

    private static func writeRelaunchMarker(now: Date = Date()) {
        let value = String(now.timeIntervalSince1970)
        do {
            try FileManager.default.createDirectory(
                at: Constants.Storage.appSupportDirectory,
                withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: relaunchMarkerURL, options: .atomic)
        } catch {
            Log.ui.error("Failed to write updater relaunch marker: \(error.localizedDescription, privacy: .public)")
        }
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
