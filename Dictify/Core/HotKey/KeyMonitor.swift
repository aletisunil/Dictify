import Cocoa

/// Main-actor isolated. NSEvent monitor callbacks and UserDefaults notifications
/// are re-dispatched onto the main actor explicitly to avoid relying on
/// AppKit's undocumented callback-thread guarantees.
@MainActor
final class KeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnPressTime: Date?
    private var isRecording = false
    private var activationKey: String = UserDefaults.standard.string(forKey: "activationKey") ?? "fn"
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
                let newActivationKey = UserDefaults.standard.string(forKey: "activationKey") ?? "fn"
                self?.activationKey = newActivationKey
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        if globalMonitor != nil || localMonitor != nil {
            return true
        }

        isRecording = false
        fnPressTime = nil
        activationKey = UserDefaults.standard.string(forKey: "activationKey") ?? "fn"

        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }) else {
            return false
        }

        globalMonitor = monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }
        return true
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isRecording = false
        fnPressTime = nil
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
        default:
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyPressed = isActivationKeyPressed(flags)
        let threshold = UserDefaults.standard.object(forKey: "tapHoldThreshold") as? Double
            ?? Constants.Audio.tapHoldThreshold

        if keyPressed && !isRecording {
            fnPressTime = Date()
            isRecording = true
            onRecordingStart()
        } else if !keyPressed && isRecording {
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
