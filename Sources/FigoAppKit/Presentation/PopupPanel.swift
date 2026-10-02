import AppKit

/// The popup's window: a borderless, transparent, non-activating panel. It never becomes key or
/// main, so the terminal keeps keyboard focus even while a row is clicked.
final class PopupPanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    // Visible over every Space, including other apps' full-screen Spaces, and kept out of
    // Mission Control and the window cycle.
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    // The page draws its own shadow.
    hasShadow = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    isMovable = false
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Shows the web view in a `PopupPanel` at the frames the presenter computes.
@MainActor
final class PopupWindowController: PopupWindowing {
  let panel = PopupPanel()

  init(content: NSView) {
    content.frame = panel.contentView?.bounds ?? .zero
    content.autoresizingMask = [.width, .height]
    panel.contentView = content
  }

  func show(frame: CGRect, level: Int) {
    apply(frame: frame, level: level)
    panel.orderFrontRegardless()
  }

  func move(to frame: CGRect, level: Int) {
    apply(frame: frame, level: level)
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func apply(frame: CGRect, level: Int) {
    if panel.level.rawValue != level { panel.level = NSWindow.Level(rawValue: level) }
    if panel.frame != frame { panel.setFrame(frame, display: true) }
  }
}
