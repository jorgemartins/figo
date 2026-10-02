import Foundation

/// The colours of a theme file that the settings window previews.
public struct ThemeSwatch: Equatable, Sendable {
  public var text: String
  public var background: String
  public var selectionText: String
  public var selectionBackground: String
  public var match: String
  public var description: String

  /// The page's built-in dark theme, which theme files are merged over.
  public static let dark = ThemeSwatch(
    text: "#ffffff", background: "#2b2b2b", selectionText: "#ffffff", selectionBackground: "#1c56bd",
    match: "#6272a4", description: "#c0c0c0")
  public static let light = ThemeSwatch(
    text: "#1f1f1f", background: "#f7f7f7", selectionText: "#ffffff", selectionBackground: "#2f6fe0",
    match: "#9db8f2", description: "#5c5c5c")
}

public struct ThemeEntry: Equatable, Identifiable, Sendable {
  public var name: String
  public var swatch: ThemeSwatch
  public var isUserTheme: Bool
  public var id: String { name }
}

/// Theme files: user themes in `~/.config/figo/themes` win over bundled ones of the same name.
public struct ThemeCatalog: Sendable {
  public var bundled: URL?
  public var user: URL

  public init(bundled: URL?, user: URL) {
    self.bundled = bundled
    self.user = user
  }

  /// Every theme file name without `.json`, sorted.
  public func names() -> [String] {
    Set(files(in: bundled) + files(in: user)).sorted()
  }

  public func entries() -> [ThemeEntry] {
    let userNames = Set(files(in: user))
    return names().map { name in
      let directory = userNames.contains(name) ? user : bundled
      let swatch = directory.flatMap { Self.swatch(at: $0.appendingPathComponent("\(name).json")) } ?? .dark
      return ThemeEntry(name: name, swatch: swatch, isUserTheme: userNames.contains(name))
    }
  }

  private func files(in directory: URL?) -> [String] {
    guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return []
    }
    return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(".json".count)) }
  }

  /// Reads the v1.0 theme schema; missing colours fall back to the built-in dark theme.
  public static func swatch(at file: URL) -> ThemeSwatch? {
    guard let data = try? Data(contentsOf: file),
      let theme = try? JSONDecoder().decode(JSONValue.self, from: data)["theme"]
    else { return nil }
    let fallback = ThemeSwatch.dark
    return ThemeSwatch(
      text: theme["textColor"]?.stringValue ?? fallback.text,
      background: theme["backgroundColor"]?.stringValue ?? fallback.background,
      selectionText: theme["selection"]?["textColor"]?.stringValue ?? fallback.selectionText,
      selectionBackground: theme["selection"]?["backgroundColor"]?.stringValue ?? fallback.selectionBackground,
      match: theme["matchBackgroundColor"]?.stringValue ?? fallback.match,
      description: theme["description"]?["textColor"]?.stringValue ?? fallback.description)
  }
}
