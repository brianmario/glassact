import AppKit
import GlassActSession

/// Display choice (§4.10): which of the Mac's displays the session shows, when it has more
/// than one and the session's mode lets a pick take effect (`DisplayPicker.isVisible`).
/// A pull-down in the session window's title bar, and the same list in View ▸ Displays,
/// which also reaches it in full screen. A checkmark is on the display the Mac says it
/// shares; a pick waiting for its answer says "Switching…".
@MainActor final class DisplaysMenu: NSObject {
    /// The person picked a display.
    var onPick: ((UInt32) -> Void)?

    /// View ▸ Displays (hidden while there's nothing to pick).
    let viewMenuItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
    private let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 44, height: 22), pullsDown: true)
    private let accessory = NSTitlebarAccessoryViewController()
    private weak var window: NSWindow?
    private var picker = DisplayPicker()

    override init() {
        super.init()
        viewMenuItem.submenu = NSMenu(title: "Displays")
        viewMenuItem.isHidden = true
        button.bezelStyle = .toolbar
        button.controlSize = .regular
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        button.toolTip = "Choose which of the Mac’s displays to show"
        button.setAccessibilityLabel("Displays")
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 52, height: 28))
        button.frame = NSRect(x: 0, y: 3, width: 44, height: 22)
        holder.addSubview(button)
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        accessory.isHidden = true
    }

    /// The session window, once it opens (and again when it's replaced).
    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        if let index = self.window?.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            self.window?.removeTitlebarAccessoryViewController(at: index)
        }
        self.window = window
        if let window { window.addTitlebarAccessoryViewController(accessory) }
        update(picker)
    }

    func update(_ picker: DisplayPicker) {
        self.picker = picker
        let visible = picker.isVisible && window != nil
        accessory.isHidden = !visible
        viewMenuItem.isHidden = !visible
        let items = picker.items

        let menu = NSMenu()
        // A pull-down's first item is its face: the display symbol, never shown in the menu.
        let face = NSMenuItem()
        face.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Displays")
        menu.addItem(face)
        let header = NSMenuItem.sectionHeader(title: "Show Display")
        menu.addItem(header)
        for item in items { menu.addItem(menuItem(item)) }
        button.menu = menu

        let submenu = viewMenuItem.submenu!
        submenu.removeAllItems()
        for item in items { submenu.addItem(menuItem(item)) }
    }

    private func menuItem(_ item: DisplayPicker.Item) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.name, action: #selector(picked(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.tag = Int(item.id)
        menuItem.state = item.isShown ? .on : .off
        menuItem.subtitle = item.isPending ? "Switching…" : item.detail
        menuItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        return menuItem
    }

    @objc private func picked(_ sender: NSMenuItem) {
        onPick?(UInt32(truncatingIfNeeded: sender.tag))
    }
}
