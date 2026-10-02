import Foundation

/// The popup's default key bindings (research doc 04 §3.2) and the user's overrides, which are
/// stored one per key as `autocomplete.keybindings.<key>` = `<action>` and merged by the page.
public enum Keybindings {
  public struct Binding: Equatable, Sendable {
    public var key: String
    public var action: String
  }

  public static let defaults: [Binding] = [
    Binding(key: "enter", action: "insertSelected"),
    Binding(key: "tab", action: "insertCommonPrefix"),
    Binding(key: "esc", action: "hideAutocomplete"),
    Binding(key: "up", action: "navigateUp"),
    Binding(key: "shift+tab", action: "navigateUp"),
    Binding(key: "control+p", action: "navigateUp"),
    Binding(key: "down", action: "navigateDown"),
    Binding(key: "control+n", action: "navigateDown"),
    Binding(key: "control+k", action: "toggleDescription"),
    Binding(key: "control+r", action: "toggleHistoryMode"),
  ]

  /// `ActionId` in `web/src/core/contract.ts`, plus `ignore`, which unbinds a key.
  public static let actions = [
    "insertSelected", "insertCommonPrefix", "insertCommonPrefixOrNavigateDown", "insertCommonPrefixOrInsertSelected",
    "insertSelectedAndExecute", "execute", "hideAutocomplete", "showAutocomplete", "toggleAutocomplete", "navigateUp",
    "navigateDown", "toggleDescription", "toggleHistoryMode", "toggleFuzzySearch", "increaseSize", "decreaseSize",
    "ignore",
  ]

  public static func settingKey(for key: String) -> String {
    SettingKey.keybindingPrefix + key
  }

  /// Key to action for every override in `settings`.
  public static func overrides(in settings: [String: JSONValue]) -> [String: String] {
    var result: [String: String] = [:]
    for (settingKey, value) in settings where settingKey.hasPrefix(SettingKey.keybindingPrefix) {
      guard let action = value.stringValue else { continue }
      result[String(settingKey.dropFirst(SettingKey.keybindingPrefix.count))] = action
    }
    return result
  }

  /// Normalises what a user typed: lower case, no spaces, `ctrl` → `control`, `cmd` → `command`,
  /// `opt` → `option`.
  public static func normalize(_ key: String) -> String {
    let aliases = ["ctrl": "control", "cmd": "command", "opt": "option", "escape": "esc", "return": "enter"]
    return key.lowercased().split(separator: "+").map { part in
      let trimmed = part.trimmingCharacters(in: .whitespaces)
      return aliases[trimmed] ?? trimmed
    }.joined(separator: "+")
  }
}
