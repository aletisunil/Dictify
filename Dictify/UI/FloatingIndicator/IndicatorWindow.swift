import Cocoa
import SwiftUI
import Combine

@MainActor
final class IndicatorWindow {
    private var panel: NSPanel?
    private let appState: AppState
    private var cancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        setupObserver()
    }

    private func setupObserver() {
        cancellable = appState.$pipelineState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .idle:
                    self?.hidePanel()
                case .recording, .transcribing, .refining, .inserting, .done:
                    self?.showPanel()
                case .error:
                    self?.showPanel()
                }
            }
    }

    private func showPanel() {
        if panel == nil {
            createPanel()
        }
        panel?.orderFront(nil)
    }

    private func hidePanel() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
                self?.panel?.alphaValue = 1
            }
        })
    }

    private func createPanel() {
        let contentView = IndicatorView(appState: appState)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.borderWidth = 0
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: Constants.UI.indicatorWidth,
            height: Constants.UI.indicatorHeight
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Constants.UI.indicatorWidth, height: Constants.UI.indicatorHeight),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.borderWidth = 0

        // Position at bottom-center of the active screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - Constants.UI.indicatorWidth / 2
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }
}
