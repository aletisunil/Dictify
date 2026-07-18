import AppKit

@MainActor
final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private let onOpen: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private let iconSize = NSSize(width: 18, height: 18)

    init(onOpen: @escaping @MainActor () -> Void, onQuit: @escaping @MainActor () -> Void) {
        self.onOpen = onOpen
        self.onQuit = onQuit
        setup()
    }

    private func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Unique autosave name. macOS 26 keys menu-bar-item visibility by this
        // name alone (com.apple.controlcenter "NSStatusItem Visible <name>"),
        // so the AppKit default "Item-0" collides with every other app that
        // never set one - hiding another app's icon hid ours too.
        item.autosaveName = "DictifyMenuBar"
        if let button = item.button {
            button.image = makeIcon()
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "Dictify"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Dictify", action: #selector(openClicked), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Dictify", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openClicked() {
        onOpen()
    }

    @objc private func quitClicked() {
        onQuit()
    }

    private func makeIcon() -> NSImage? {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let barWidth = rect.width * 0.14
            let spacing = rect.width * 0.07
            let totalWidth = (barWidth * 7) + (spacing * 6)
            let startX = rect.midX - (totalWidth / 2)
            let heights = [0.34, 0.58, 0.86, 0.68, 1.0, 0.86, 0.58]

            NSColor.labelColor.setFill()

            for (index, heightRatio) in heights.enumerated() {
                let height = rect.height * heightRatio
                let x = startX + (CGFloat(index) * (barWidth + spacing))
                let y = rect.midY - (height / 2)
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func invalidate() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }
}
