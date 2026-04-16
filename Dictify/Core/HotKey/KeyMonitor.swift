import Cocoa

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
            let newActivationKey = UserDefaults.standard.string(forKey: "activationKey") ?? "fn"
            self?.activationKey = newActivationKey
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
            self?.handleFlagsChanged(event)
        }) else {
            return false
        }

        globalMonitor = monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
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

    func resetRecordingState() {
        isRecording = false
        fnPressTime = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyPressed = isActivationKeyPressed(flags)

        if keyPressed && !isRecording {
            fnPressTime = Date()
            isRecording = true
            onRecordingStart()
        } else if !keyPressed && isRecording {
            isRecording = false
            let elapsed = fnPressTime.map { Date().timeIntervalSince($0) } ?? 0

            if elapsed < Constants.Audio.tapHoldThreshold {
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
        stop()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
