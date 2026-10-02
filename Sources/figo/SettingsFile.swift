import FigoCore
import Foundation

/// The settings file: one flat JSON object with dotted keys. The app watches it, so writing it
/// is all it takes to change a setting.
enum SettingsFile {
  static func read() throws -> [String: Any] {
    guard let data = try? Data(contentsOf: FigoPaths.settingsFile), !data.isEmpty else { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CommandFailure("\(FigoPaths.settingsFile.path) is not a JSON object")
    }
    return object
  }

  static func write(_ settings: [String: Any]) throws {
    try FileManager.default.createDirectory(at: FigoPaths.config, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data("\n".utf8)).write(to: FigoPaths.settingsFile, options: .atomic)
  }

  /// Interprets `text` as JSON when it is valid JSON (`true`, `14`, `"x"`), and as a plain
  /// string otherwise, so `figo settings set autocomplete.theme dracula` needs no quoting.
  static func parseValue(_ text: String) -> Any {
    if let data = text.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    {
      return value
    }
    return text
  }

  static func render(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
      return String(describing: value)
    }
    return String(decoding: data, as: UTF8.self)
  }
}
