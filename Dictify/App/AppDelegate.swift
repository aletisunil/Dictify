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
    private var indicatorWindow: IndicatorWindow?
    private var keyMonitor: KeyMonitor?
    private var pipeline: TranscriptionPipeline?
    private var permissionManager: PermissionManager?
    private var onboardingWindow: NSWindow?
    private var isCompletingOnboarding = false
    private var mainWindow: NSWindow?
    private var menuBarManager: MenuBarManager?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        Log.ui.notice("Dictify launched — v\(version, privacy: .public) (build \(build, privacy: .public)) on \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
        ensureAppSupportDirectory()
        applyAppearance(UserDefaults.standard.string(forKey: Constants.UI.appearancePreferenceKey) ?? AppearancePreference.system.rawValue)
        applyDockVisibility(showInDock: appState.settings.showInDock)

        permissionManager = PermissionManager()
        indicatorWindow = IndicatorWindow(appState: appState)

        let keychainManager = KeychainManager()
        let dictionaryStore = DictionaryStore()
        let snippetStore = SnippetStore()
        let historyStore = HistoryStore()
        let statsStore = StatsStore(historyStore: historyStore)

        appState.dictionaryStore = dictionaryStore
        appState.snippetStore = snippetStore
        appState.historyStore = historyStore
        appState.statsStore = statsStore
        appState.keychainManager = keychainManager

        pipeline = TranscriptionPipeline(
            appState: appState,
            keychainManager: keychainManager,
            dictionaryStore: dictionaryStore,
            snippetStore: snippetStore,
            historyStore: historyStore,
            statsStore: statsStore
        )

        menuBarManager = MenuBarManager(
            onOpen: { [weak self] in
                guard let self else { return }
                if self.hasOnboardedDurably() {
                    self.showMainWindow()
                } else {
                    self.showOnboarding()
                }
            },
            onQuit: {
                NSApp.terminate(nil)
            }
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

        // A login-item / reopen launch is not a "default" launch. When the app
        // auto-starts at login we stay quietly in the menu bar instead of
        // throwing the main window in the user's face on every reboot.
        let isLoginLaunch = !(notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool ?? true)
        decideLaunchFlow(isLoginLaunch: isLoginLaunch)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissionManager?.refreshAll()
        if appState.settings.hasCompletedOnboarding,
           permissionManager?.allPermissionsGranted == true,
           appState.permissionReGrantNeeded {
            appState.permissionReGrantNeeded = false
            _ = keyMonitor?.start()
        }
    }

    /// True if onboarding has finished. The stored flag is a plain UserDefaults
    /// bool, and a write can be lost if cfprefsd doesn't flush before a system
    /// shutdown — which made onboarding replay after a restart. Fall back to
    /// durable proof: a Groq API key in the Keychain is saved during onboarding
    /// and survives reboots. When the fallback fires, repair the flag so later
    /// launches trust it directly.
    @MainActor
    private func hasOnboardedDurably() -> Bool {
        if appState.settings.hasCompletedOnboarding { return true }
        if appState.keychainManager?.hasAPIKey == true {
            appState.settings.hasCompletedOnboarding = true
            return true
        }
        return false
    }

    @MainActor
    private func decideLaunchFlow(isLoginLaunch: Bool) {
        let completed = hasOnboardedDurably()
        let granted = permissionManager?.allPermissionsGranted == true

        if !completed {
            activateApp()
            showOnboarding()
            return
        }

        if granted {
            startKeyMonitor()
            // Login launches stay in the menu bar; only user-initiated launches
            // surface the main window.
            if !isLoginLaunch { showMainWindow() }
            return
        }

        // Fully-onboarded user launched without permissions — could be a real
        // revocation, or just TCC still warming up after reboot. Poll briefly
        // before surfacing anything intrusive.
        waitForPermissionsOrSurfaceBanner(isLoginLaunch: isLoginLaunch)
    }

    @MainActor
    private func waitForPermissionsOrSurfaceBanner(isLoginLaunch: Bool) {
        guard let permissionManager else { return }

        let deadline = Date().addingTimeInterval(3.0)
        let checkInterval: TimeInterval = 0.5

        func poll() {
            permissionManager.checkAll()
            if permissionManager.allPermissionsGranted {
                appState.permissionReGrantNeeded = false
                startKeyMonitor()
                if !isLoginLaunch { showMainWindow() }
                return
            }
            if Date() >= deadline {
                appState.permissionReGrantNeeded = true
                if !isLoginLaunch { showMainWindow() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + checkInterval) {
                MainActor.assumeIsolated { poll() }
            }
        }

        poll()
    }

    /// Forces the app-wide appearance. "system" follows macOS; "light"/"dark"
    /// pin the aqua/darkAqua appearance regardless of the system setting. The
    /// dynamic theme NSColors react automatically once NSApp.appearance changes.
    @MainActor
    func applyAppearance(_ preference: String) {
        NSApp.appearance = (AppearancePreference(rawValue: preference) ?? .system).nsAppearance
    }

    @MainActor
    func applyDockVisibility(showInDock: Bool) {
        let desired: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if showInDock {
            NSApp.activate()
        }
    }

    @MainActor
    func replayOnboarding() {
        appState.settings.hasCompletedOnboarding = false
        appState.permissionReGrantNeeded = false
        keyMonitor?.stop()
        mainWindow?.orderOut(nil)
        activateApp()
        showOnboarding()
    }

    @MainActor
    private func activateApp() {
        NSRunningApplication.current.activate()
    }

    /// Reliably brings a window to the foreground. `ignoringOtherApps: true`
    /// forces app activation even when another app is frontmost, and
    /// `orderFrontRegardless()` raises the window even before activation lands —
    /// needed because cooperative activation (and the `.accessory` policy) can
    /// otherwise leave the window opening behind the active app.
    @MainActor
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the main window must not quit — the global hotkey and
        // pipeline keep running in the background. The dock icon stays present.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in
                if !hasOnboardedDurably() {
                    showOnboarding()
                } else {
                    showMainWindow()
                }
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyMonitor?.invalidate()
        permissionManager?.invalidate()
        indicatorWindow?.invalidate()
        menuBarManager?.invalidate()
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

    // MARK: - Main Window

    @MainActor
    func showMainWindow(selectedTab: MainTab = .home, showMissingGroqAPIKeyWarning: Bool = false) {
        let rootView = MainWindowView(
            selection: selectedTab,
            showMissingGroqAPIKeyWarning: showMissingGroqAPIKeyWarning
        )
        .environmentObject(appState)

        if let window = mainWindow {
            window.contentView = NSHostingView(rootView: rootView)
            bringToFront(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictify"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .appWindowBackground
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
        mainWindow = window
        bringToFront(window)
    }

    /// Legacy alias — some call sites still ask to open "Settings".
    /// Routes to the main window on the matching tab.
    @MainActor
    func openSettings(selectedTab: SettingsTab? = nil, showMissingGroqAPIKeyWarning: Bool = false) {
        let mainTab: MainTab = {
            switch selectedTab {
            case .general: return .general
            case .api: return .api
            case .about: return .about
            case .snippets: return .snippets
            case .dictionary: return .dictionary
            case nil: return .general
            }
        }()
        showMainWindow(selectedTab: mainTab, showMissingGroqAPIKeyWarning: showMissingGroqAPIKeyWarning)
    }

    // MARK: - Onboarding

    @MainActor
    func showOnboarding() {
        guard let permissionManager else {
            Log.ui.error("showOnboarding called before permissionManager was initialized")
            return
        }

        permissionManager.checkAll()
        if let window = onboardingWindow {
            bringToFront(window)
            return
        }

        let onboardingView = PermissionOnboardingView(
            permissionManager: permissionManager,
            keychainManager: appState.keychainManager,
            onAPIKeySaved: { [weak self] in
                self?.appState.refreshAPIKeyStatus()
            },
            onComplete: { [weak self] in
                self?.completeOnboarding()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .normal
        window.hidesOnDeactivate = false
        window.center()
        let hostingView = FirstMouseHostingView(rootView: onboardingView)
        window.contentView = hostingView
        onboardingWindow = window
        bringToFront(window)
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
        appState.settings.hasCompletedOnboarding = true
        appState.permissionReGrantNeeded = false
        let window = onboardingWindow
        onboardingWindow = nil
        window?.orderOut(nil)

        // Close after the SwiftUI button action has unwound. Keeping a local strong
        // reference avoids AppKit/ARC lifetime surprises during teardown.
        DispatchQueue.main.async { [weak self, window] in
            window?.contentView = nil
            window?.close()
            self?.isCompletingOnboarding = false
            self?.startKeyMonitor()
            self?.showMainWindow()
        }
    }

    @MainActor
    private func startKeyMonitor() {
        guard permissionManager?.allPermissionsGranted == true else {
            if appState.settings.hasCompletedOnboarding {
                appState.permissionReGrantNeeded = true
                showMainWindow()
            } else {
                showOnboarding()
            }
            return
        }

        guard keyMonitor?.start() == true else {
            keyMonitor?.stop()
            permissionManager?.checkAll()
            if appState.settings.hasCompletedOnboarding {
                appState.permissionReGrantNeeded = true
                showMainWindow()
            } else {
                showOnboarding()
            }
            return
        }

        // Permissions granted and the hotkey is live — front-load the CoreAudio
        // graph so the first dictation doesn't pay the engine cold start.
        Task { [weak self] in
            await self?.pipeline?.prewarm()
        }
    }
}
