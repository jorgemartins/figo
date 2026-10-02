import FigoCore

/// Decides which key presses are taken away from the shell and handed to the popup.
public struct Interceptor: Sendable {
  /// Actions that work while the popup is hidden, to bring it back.
  private static let globalActions: Set<String> = ["showAutocomplete", "toggleAutocomplete"]

  private var interceptBound = false
  private var interceptGlobal = false
  private var actions: [String: String] = [:]

  public init() {}

  public var isActive: Bool { interceptBound || interceptGlobal }

  public mutating func apply(_ configuration: InterceptConfiguration) {
    interceptBound = configuration.interceptBound
    interceptGlobal = configuration.interceptGlobal
    actions = [:]
    for (binding, action) in configuration.bindings {
      actions[KeyName.normalize(binding)] = action
    }
  }

  /// Stops intercepting until the app sends a new configuration. Called whenever the popup
  /// cannot be on screen any more (a command started, the app went away) so that keys can
  /// never be swallowed with nobody listening.
  public mutating func reset() {
    interceptBound = false
    interceptGlobal = false
  }

  /// The action `key` triggers, or nil when the key belongs to the shell.
  public mutating func action(for key: String) -> String? {
    guard isActive, let action = actions[key], action != "ignore" else {
      // Interrupting or ending input dismisses the popup; do not wait for the app to say so.
      if key == "control+c" || key == "control+d" { reset() }
      return nil
    }
    if interceptBound {
      // Hiding is acted on immediately so the very next key reaches the shell.
      if action == "hideAutocomplete" { interceptBound = false }
      return action
    }
    return Self.globalActions.contains(action) ? action : nil
  }
}
