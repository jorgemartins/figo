import AppKit
import FigoCore
import InputMethodKit

/// One instance per text input context. It never handles keys (it implements none of the
/// `handle(_:client:)` / `inputText` family), so every keystroke passes through untouched; it
/// only reports focus changes and answers where the caret is.
///
/// The Objective-C name must match `InputMethodServerControllerClass` in the helper's Info.plist.
@objc(FigoInputController)
final class FigoInputController: IMKInputController {
  /// The controller whose client currently has keyboard focus. Only touched on the main thread.
  nonisolated(unsafe) static weak var active: FigoInputController?

  /// winit (Alacritty) only turns on its IME handling once it has seen marked text.
  private static let alacrittyBundleIds: Set<String> = ["org.alacritty", "io.alacritty"]

  override func activateServer(_ sender: Any!) {
    super.activateServer(sender)
    Self.active = self
    let client = (sender as? (IMKTextInput & NSObjectProtocol)) ?? self.client()
    let bundleId = client?.bundleIdentifier()
    if let client, let bundleId, Self.alacrittyBundleIds.contains(bundleId) {
      let empty = NSRange(location: 0, length: 0)
      client.setMarkedText(" ", selectionRange: empty, replacementRange: empty)
      client.setMarkedText("", selectionRange: empty, replacementRange: empty)
    }
    MainActor.assumeIsolated { InputMethodService.shared.focusChanged(bundleId: bundleId, active: true) }
  }

  override func deactivateServer(_ sender: Any!) {
    if Self.active === self { Self.active = nil }
    let client = (sender as? (IMKTextInput & NSObjectProtocol)) ?? self.client()
    let bundleId = client?.bundleIdentifier()
    MainActor.assumeIsolated { InputMethodService.shared.focusChanged(bundleId: bundleId, active: false) }
    super.deactivateServer(sender)
  }

  var clientBundleId: String? {
    client()?.bundleIdentifier()
  }

  /// The insertion point in Cocoa screen coordinates, or nil when the client reports nothing.
  func caretRect() -> NSRect? {
    guard let client = client() else { return nil }
    var rect = NSRect.zero
    _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    if rect.width <= 0 && rect.height <= 0 {
      var actual = NSRange(location: NSNotFound, length: 0)
      rect = client.firstRect(forCharacterRange: client.selectedRange(), actualRange: &actual)
    }
    guard rect.height > 0 || rect.width > 0, !(rect.origin == .zero && rect.height <= 0) else { return nil }
    return rect
  }
}

/// Connects the controllers to the app.
@MainActor
final class InputMethodService {
  static let shared = InputMethodService()

  private let link = AppLink(path: FigoPaths.appSocket.path)
  /// Re-sent after a reconnect so the app knows who has focus.
  private var lastActivation: InputMethodMessage?

  func start() {
    link.onConnect = { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let activation = self.lastActivation else { return }
        self.link.send(activation)
      }
    }
    link.onCommand = { [weak self] command in
      MainActor.assumeIsolated { self?.handle(command) }
    }
    link.start()
  }

  func focusChanged(bundleId: String?, active: Bool) {
    let message = InputMethodMessage.focus(bundleId: bundleId, pid: pid(of: bundleId), active: active)
    if active {
      lastActivation = message
    } else if case .focus(let lastBundle, _, _)? = lastActivation, lastBundle == bundleId {
      lastActivation = nil
    }
    IMLog.debug("focus \(active ? "gained" : "lost"): \(bundleId ?? "unknown")")
    link.send(message)
  }

  private func handle(_ command: InputMethodCommand) {
    switch command {
    case .queryCaret(let id):
      let controller = FigoInputController.active
      let rect = controller?.caretRect()
      IMLog.debug("caret \(id): \(rect.map { NSStringFromRect($0) } ?? "none")")
      link.send(
        .caret(
          id: id, rect: rect.map { ScreenRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
          bundleId: controller?.clientBundleId))
    }
  }

  /// The text input client does not say which process it is; the app that just got focus is
  /// almost always the frontmost one.
  private func pid(of bundleId: String?) -> Int32? {
    guard let bundleId else { return nil }
    if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleId {
      return front.processIdentifier
    }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier
  }
}
