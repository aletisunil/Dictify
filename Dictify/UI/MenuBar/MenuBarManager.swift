import Cocoa
import SwiftUI
import Combine

@MainActor
final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let appState: AppState
    private let onSettingsClicked: @MainActor () -> Void
    private let onConfigureAPIClicked: @MainActor () -> Void
    private let onQuitClicked: @MainActor () -> Void
    private var cancellable: AnyCancellable?
    private let iconSize = NSSize(width: 16, height: 16)

    init(appState: AppState, onSettingsClicked: @escaping @MainActor () -> Void, onConfigureAPIClicked: @escaping @MainActor () -> Void, onQuitClicked: @escaping @MainActor () -> Void) {
        self.appState = appState
        self.onSettingsClicked = onSettingsClicked
        self.onConfigureAPIClicked = onConfigureAPIClicked
        self.onQuitClicked = onQuitClicked
        setupStatusItem()
        setupPopover()
        observeState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            configureButton(button)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        let popoverView = MenuBarPopover(
            appState: appState,
            onSettingsClicked: onSettingsClicked,
            onConfigureAPIClicked: onConfigureAPIClicked,
            onQuitClicked: onQuitClicked
        )
        let hostingController = NSHostingController(rootView: popoverView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.black.cgColor
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 400)
        self.popover = popover
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown != true {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func observeState() {
        cancellable = appState.$pipelineState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
    }

    private func updateIcon(for state: PipelineState) {
        if let button = statusItem?.button {
            configureButton(button, state: state)
        }
    }

    private func configureButton(_ button: NSStatusBarButton, state: PipelineState? = nil) {
        button.image = makeDictifyMenuBarIcon()
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = tooltip(for: state ?? appState.pipelineState)
    }

    private func makeDictifyMenuBarIcon() -> NSImage? {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let barWidth = rect.width * 0.14
            let spacing = rect.width * 0.07
            let totalWidth = (barWidth * 7) + (spacing * 6)
            let startX = rect.midX - (totalWidth / 2)
            let heights = [0.34, 0.58, 0.86, 0.68, 1.0, 0.86, 0.58]

            NSColor.black.setFill()

            for (index, heightRatio) in heights.enumerated() {
                let height = rect.height * heightRatio
                let x = startX + (CGFloat(index) * (barWidth + spacing))
                let y = rect.midY - (height / 2)
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                let radius = barWidth / 2
                NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius).fill()
            }

            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = "Dictify"
        return image
    }

    private func tooltip(for state: PipelineState) -> String {
        let status = state.statusLabel
        return status.isEmpty ? "Dictify" : "Dictify - \(status)"
    }
}
