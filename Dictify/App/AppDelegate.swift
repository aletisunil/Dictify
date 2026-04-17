import Cocoa
import Combine
import SwiftUI

// NSHostingView subclass that accepts the first mouse click even when its window
// is not the key window. This prevents the common macOS issue where clicking a
// button in a non-focused window only activates the window on the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let appState = AppState()
    private var menuBarManager: MenuBarManager?
    private var indicatorWindow: IndicatorWindow?
    private var keyMonitor: KeyMonitor?
    private var pipeline: TranscriptionPipeline?
    private var permissionManager: PermissionManager?
    private var onboardingWindow: NSWindow?
    private var onboardingWindowLevelBeforeAccessibilityPrompt: NSWindow.Level?
    private var isCompletingOnboarding = false
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        ensureAppSupportDirectory()

        permissionManager = PermissionManager()
        indicatorWindow = IndicatorWindow(appState: appState)

        let keychainManager = KeychainManager()
        let dictionaryStore = DictionaryStore()
        let snippetStore = SnippetStore()
        let historyStore = HistoryStore()
        let statsStore = StatsStore()

        appState.dictionaryStore = dictionaryStore
        appState.snippetStore = snippetStore
        appState.historyStore = historyStore
        appState.statsStore = statsStore
        appState.keychainManager = keychainManager

        menuBarManager = MenuBarManager(
            appState: appState,
            onSettingsClicked: { [weak self] in
                self?.openSettings()
            },
            onConfigureAPIClicked: { [weak self] in
                self?.openSettings(selectedTab: .api, showMissingGroqAPIKeyWarning: true)
            },
            onQuitClicked: {
                NSApplication.shared.terminate(nil)
            }
        )

        pipeline = TranscriptionPipeline(
            appState: appState,
            keychainManager: keychainManager,
            dictionaryStore: dictionaryStore,
            snippetStore: snippetStore,
            historyStore: historyStore,
            statsStore: statsStore
        )

        keyMonitor = KeyMonitor(
            onRecordingStart: { [weak self] in
                Task { await self?.pipeline?.startRecording() }
            },
            onRecordingStop: { [weak self] in
                Task { await self?.pipeline?.stopRecording() }
            },
            onRecordingCancel: { [weak self] in
                Task { await self?.pipeline?.cancelRecording() }
            }
        )

        if permissionManager?.allPermissionsGranted != true {
            showOnboarding()
        } else {
            startKeyMonitor()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionManager?.refreshAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyMonitor?.invalidate()
        permissionManager?.invalidate()
        indicatorWindow?.invalidate()
    }

    private func ensureAppSupportDirectory() {
        let dir = Constants.Storage.appSupportDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.storage.error("Failed to create Application Support dir: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @MainActor
    func openSettings(selectedTab: SettingsTab? = nil, showMissingGroqAPIKeyWarning: Bool = false) {
        let settingsView = SettingsView(
            selectedTab: selectedTab ?? .general,
            showMissingGroqAPIKeyWarning: showMissingGroqAPIKeyWarning
        )
        .environmentObject(appState)

        if let window = settingsWindow {
            if selectedTab != nil || showMissingGroqAPIKeyWarning {
                window.contentView = NSHostingView(rootView: settingsView)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictify Settings"
        window.center()
        window.contentView = NSHostingView(rootView: settingsView)
        window.contentMinSize = NSSize(width: 550, height: 450)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @MainActor
    func showOnboarding() {
        guard let permissionManager else {
            Log.ui.error("showOnboarding called before permissionManager was initialized")
            return
        }

        permissionManager.checkAll()
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = PermissionOnboardingView(
            permissionManager: permissionManager,
            keychainManager: appState.keychainManager,
            onAccessibilityPermissionRequest: { [weak self] in
                self?.prepareOnboardingWindowForAccessibilityPrompt()
            },
            onAPIKeySaved: { [weak self] in
                self?.appState.refreshAPIKeyStatus()
            },
            onComplete: { [weak self] in
                self?.completeOnboarding()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.center()
        // Use a hosting view that accepts the first mouse click even when the window
        // is not key. Without this, after the user switches to System Settings to grant
        // Accessibility permission and returns, the first click on "Get Started" only
        // focuses the window — the button action never fires.
        let hostingView = FirstMouseHostingView(rootView: onboardingView)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window

        // When the accessibility permission is detected as granted (user returns from
        // System Settings), bring the onboarding window back to front so "Get Started"
        // is immediately clickable without needing to click once to focus first.
        permissionManager.$accessibilityGranted
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restoreOnboardingWindowAfterAccessibilityPrompt()
            }
            .store(in: &cancellables)

    }

    @MainActor
    private func completeOnboarding() {
        guard !isCompletingOnboarding else { return }

        permissionManager?.checkAll()
        guard permissionManager?.allPermissionsGranted == true else {
            showOnboarding()
            return
        }

        isCompletingOnboarding = true
        let window = onboardingWindow
        onboardingWindow = nil
        onboardingWindowLevelBeforeAccessibilityPrompt = nil
        window?.orderOut(nil)

        // Close after the SwiftUI button action has unwound. Keeping a local strong
        // reference avoids AppKit/ARC lifetime surprises during teardown.
        DispatchQueue.main.async { [weak self, window] in
            window?.contentView = nil
            window?.close()
            self?.isCompletingOnboarding = false
            self?.startKeyMonitor()
            self?.menuBarManager?.showPopover()
        }
    }

    @MainActor
    private func prepareOnboardingWindowForAccessibilityPrompt() {
        guard let window = onboardingWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func restoreOnboardingWindowAfterAccessibilityPrompt() {
        guard !isCompletingOnboarding else { return }

        if let previousLevel = onboardingWindowLevelBeforeAccessibilityPrompt {
            onboardingWindow?.level = previousLevel
            onboardingWindowLevelBeforeAccessibilityPrompt = nil
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func startKeyMonitor() {
        guard permissionManager?.allPermissionsGranted == true else {
            showOnboarding()
            return
        }

        guard keyMonitor?.start() == true else {
            keyMonitor?.stop()
            permissionManager?.checkAll()
            showOnboarding()
            return
        }
    }
}
