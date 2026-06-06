import Cocoa

/// Main-actor isolated. NSEvent monitor callbacks and UserDefaults notifications
/// are re-dispatched onto the main actor explicitly to avoid relying on
/// AppKit's undocumented callback-thread guarantees.
@MainActor
final class KeyMonitor {
    /// Activation-key value selecting the middle mouse button instead of a
    /// modifier key. Useful on compact keyboards (e.g. 75% layouts) with no fn.
    static let middleMouseKey = "middleMouse"

    /// UserDefaults flag enabling the middle-mouse trigger *in addition to* the
    /// modifier-key trigger. The two are independent — either (or both) may be
    /// active at once.
    static let middleMouseEnabledKey = "middleMouseEnabled"

    /// Identifies which input started a hold. Tracked as a set so overlapping
    /// holds (e.g. fn pressed, then middle-click) don't stop recording until the
    /// last source is released.
    private enum TriggerSource { case modifier, mouse }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var fnPressTime: Date?
    private var isRecording = false
    private var activeTriggers: Set<TriggerSource> = []
    private var activationKey: String = KeyMonitor.loadActivationKey()
    private var middleMouseEnabled: Bool = KeyMonitor.loadMiddleMouseEnabled()
    private var defaultsObserver: NSObjectProtocol?

    private let onRecordingStart: () -> Void
    private let onRecordingStop: () -> Void
    private let onRecordingCancel: () -> Void

    init(onRecordingStart: @escaping () -> Void,
         onRecordingStop: @escaping () -> Void,
         onRecordingCancel: @escaping () -> Void) {
        self.onRecordingStart = onRecordingStart
        self.onRecordingStop = onRecordingStop
        self.onRecordingCancel = onRecordingCancel

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.activationKey = KeyMonitor.loadActivationKey()
                self?.middleMouseEnabled = KeyMonitor.loadMiddleMouseEnabled()
            }
        }
    }

    /// Reads the modifier activation key. A legacy `middleMouse` value (from when
    /// middle-click *replaced* the modifier) is normalised to `fn`; the mouse
    /// trigger is now carried separately by `middleMouseEnabledKey`.
    private static func loadActivationKey() -> String {
        let stored = UserDefaults.standard.string(forKey: "activationKey") ?? "fn"
        return stored == middleMouseKey ? "fn" : stored
    }

    private static func loadMiddleMouseEnabled() -> Bool {
        // Honour the explicit flag, but also treat the legacy `middleMouse`
        // activationKey as "enabled" so existing users keep their trigger.
        if UserDefaults.standard.bool(forKey: middleMouseEnabledKey) { return true }
        return UserDefaults.standard.string(forKey: "activationKey") == middleMouseKey
    }

    @discardableResult
    func start() -> Bool {
        if globalMonitor != nil || localMonitor != nil {
            return true
        }

        isRecording = false
        fnPressTime = nil
        activeTriggers = []
        activationKey = KeyMonitor.loadActivationKey()
        middleMouseEnabled = KeyMonitor.loadMiddleMouseEnabled()

        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }) else {
            Log.hotkey.error("Failed to register global flags-changed monitor (Accessibility not trusted?)")
            return false
        }

        globalMonitor = monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }

        // Mouse monitors run unconditionally; the handler ignores events unless
        // the middle-mouse trigger is enabled. Other mouse buttons map to higher
        // buttonNumbers and are filtered out in handleMouseEvent.
        let mouseMask: NSEvent.EventTypeMask = [.otherMouseDown, .otherMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseEvent(event)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseEvent(event)
            }
            return event
        }
        Log.hotkey.notice("Key monitors registered (activationKey: \(self.activationKey, privacy: .public), middleMouse: \(self.middleMouseEnabled, privacy: .public))")
        return true
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        globalMouseMonitor = nil
        localMouseMonitor = nil
        isRecording = false
        fnPressTime = nil
        activeTriggers = []
    }

    func invalidate() {
        stop()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
    }

    func resetRecordingState() {
        isRecording = false
        fnPressTime = nil
        activeTriggers = []
    }

    /// Enumerates active system hotkeys via Carbon's `CopySymbolicHotKeys` and
    /// flags a conflict with the configured activation key. Only well-known
    /// system shortcuts involving the same modifier are reported.
    static func detectConflict(for activationKey: String) -> String? {
        // Modifier-only activation keys (fn/command/shift/control/option)
        // aren't symbolic system hotkeys by themselves, but the documented
        // system behaviours below do consume them at the OS level.
        switch activationKey {
        case "fn":
            // macOS "Press 🌐 to" handler (Emoji & Symbols / Input Source).
            // Surfaced to the user as a soft warning — not a hard block.
            return "Fn may trigger the system globe key action (Input Source / Emoji). Consider disabling 'Press 🌐 to' in Keyboard settings."
        case "command":
            return "Command is used by most system and app shortcuts — may cause conflicts."
        case "shift":
            return "Shift is used for capitalization — may interfere with typing."
        case middleMouseKey:
            return "Middle click is consumed by some apps (e.g. browser tab actions, pasting in terminals) — it may not reach Dictify there."
        default:
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        updateRecordingState(.modifier, pressed: isActivationKeyPressed(flags))
    }

    /// Middle mouse button is `buttonNumber == 2`. Down begins a hold, up ends it.
    private func handleMouseEvent(_ event: NSEvent) {
        guard middleMouseEnabled, event.buttonNumber == 2 else { return }
        updateRecordingState(.mouse, pressed: event.type == .otherMouseDown)
    }

    /// Shared press/release transition used by both the modifier-key and
    /// middle-mouse handlers. Both triggers feed one recording session: it starts
    /// when the first source presses and stops when the last source releases, so
    /// the two can overlap freely. A release shorter than the tap/hold threshold
    /// is treated as an accidental tap and cancels instead of transcribing.
    private func updateRecordingState(_ source: TriggerSource, pressed: Bool) {
        let wasActive = !activeTriggers.isEmpty
        if pressed {
            activeTriggers.insert(source)
        } else {
            activeTriggers.remove(source)
        }
        let isActive = !activeTriggers.isEmpty

        let threshold = UserDefaults.standard.object(forKey: "tapHoldThreshold") as? Double
            ?? Constants.Audio.tapHoldThreshold

        if isActive && !wasActive {
            fnPressTime = Date()
            isRecording = true
            onRecordingStart()
        } else if !isActive && wasActive && isRecording {
            isRecording = false
            let elapsed = fnPressTime.map { Date().timeIntervalSince($0) } ?? 0

            if elapsed < threshold {
                onRecordingCancel()
            } else {
                onRecordingStop()
            }
            fnPressTime = nil
        }
    }

    private func isActivationKeyPressed(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch activationKey {
        case "control": return flags.contains(.control)
        case "option": return flags.contains(.option)
        case "command": return flags.contains(.command)
        case "shift": return flags.contains(.shift)
        default: return flags.contains(.function)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }
}
