import AppKit

/// The menu-bar item: a status line, Settings…, Restart and Quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let statusText: () -> String
  private var actions: [NSMenuItem: () -> Void] = [:]

  init(statusText: @escaping () -> String, settings: @escaping () -> Void, restart: @escaping () -> Void) {
    self.statusText = statusText
    super.init()

    if let button = item.button {
      let image = NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: "Figo")
        ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Figo")
      image?.isTemplate = true
      button.image = image
      button.toolTip = "Figo"
    }

    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    statusLine.isEnabled = false
    menu.addItem(statusLine)
    menu.addItem(.separator())
    menu.addItem(action("Settings…", key: ",", settings))
    menu.addItem(action("Restart", key: "", restart))
    menu.addItem(.separator())
    menu.addItem(action("Quit Figo", key: "q") { NSApp.terminate(nil) })
    item.menu = menu
    refresh()
  }

  var isVisible: Bool {
    get { item.isVisible }
    set { item.isVisible = newValue }
  }

  func refresh() {
    statusLine.title = statusText()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    refresh()
  }

  private func action(_ title: String, key: String, _ body: @escaping () -> Void) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
    menuItem.target = self
    actions[menuItem] = body
    return menuItem
  }

  @objc private func runAction(_ sender: NSMenuItem) {
    actions[sender]?()
  }
}
