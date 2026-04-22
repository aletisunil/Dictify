import Cocoa
import SwiftUI
import Combine

@MainActor
final class IndicatorWindow {
    private var panel: NSPanel?
    private let appState: AppState
    private var cancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var hideGeneration = 0
    private var errorDismissTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        setupObserver()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionIfVisible()
            }
        }
    }

    private func setupObserver() {
        cancellable = appState.$pipelineState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle:
                    self.errorDismissTask?.cancel()
                    self.errorDismissTask = nil
                    self.hidePanel()
                case .recording, .transcribing, .refining, .inserting:
                    self.errorDismissTask?.cancel()
                    self.errorDismissTask = nil
                    self.showPanel()
                case .error:
                    self.showPanel()
                    self.scheduleErrorDismiss()
                }
            }
    }

    private func showPanel() {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }
        hideGeneration += 1

        if panel.isVisible {
            panel.alphaValue = 1
            return
        }

        positionPanel()
        panel.alphaValue = 1
        panel.orderFront(nil)
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        hideGeneration += 1
        let generation = hideGeneration

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard self?.hideGeneration == generation else { return }
                self?.panel?.orderOut(nil)
                self?.panel?.alphaValue = 1
            }
        })
    }

    private func scheduleErrorDismiss() {
        errorDismissTask?.cancel()
        errorDismissTask = Task { @MainActor [weak self, appState] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if case .error = appState.pipelineState {
                appState.pipelineState = .idle
            }
            self.errorDismissTask = nil
        }
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        positionPanel()
    }

    private func createPanel() {
        let contentRect = NSRect(
            x: 0, y: 0,
            width: Constants.UI.indicatorWidth,
            height: Constants.UI.indicatorHeight
        )
        let contentView = IndicatorView(appState: appState)
            .frame(width: Constants.UI.indicatorWidth, height: Constants.UI.indicatorHeight)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.borderWidth = 0
        hostingView.frame = contentRect

        let containerView = NSView(frame: contentRect)
        containerView.translatesAutoresizingMaskIntoConstraints = true
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.borderWidth = 0
        containerView.addSubview(hostingView)

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentMinSize = contentRect.size
        panel.contentMaxSize = contentRect.size
        panel.contentView = containerView

        self.panel = panel
    }

    /// Resolve the target screen for the indicator. Preference order:
    /// 1. Screen containing the frontmost app's key window.
    /// 2. Screen under the mouse cursor.
    /// 3. `NSScreen.main` as last resort.
    private func positionPanel() {
        guard let panel else { return }
        let screen = resolveTargetScreen()
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - Constants.UI.indicatorWidth / 2
        let y = screenFrame.minY + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func resolveTargetScreen() -> NSScreen {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let window = Self.keyWindow(forPID: frontApp.processIdentifier),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(window) }) {
            return screen
        }

        let cursor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// Get the bounds of the key window for a given PID via CoreGraphics
    /// window server queries (no AX permission required for bounds-only).
    private static func keyWindow(forPID pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            return rect
        }
        return nil
    }

    func invalidate() {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        cancellable?.cancel()
        cancellable = nil
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }
}
