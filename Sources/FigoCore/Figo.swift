import Foundation

public enum Figo {
  public static let version = "0.1.0"
  public static let bundleIdentifier = "dev.figo.Figo"
}

/// Every location Figo reads or writes, so no component invents its own.
public enum FigoPaths {
  /// The user's home directory. `FIGO_HOME` redirects it, which lets the installer be exercised
  /// against a scratch directory instead of the real startup files.
  public static var home: URL {
    if let override = ProcessInfo.processInfo.environment["FIGO_HOME"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  /// Settings, themes and user-written completion specs: `~/.config/figo`.
  public static var config: URL {
    if let override = ProcessInfo.processInfo.environment["FIGO_CONFIG_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return home.appendingPathComponent(".config/figo", isDirectory: true)
  }

  public static var settingsFile: URL { config.appendingPathComponent("settings.json") }
  public static var userThemes: URL { config.appendingPathComponent("themes", isDirectory: true) }
  public static var userSpecs: URL { config.appendingPathComponent("specs", isDirectory: true) }

  /// State that is not meant to be edited by hand: `~/Library/Application Support/figo`.
  public static var data: URL {
    if let override = ProcessInfo.processInfo.environment["FIGO_DATA_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return home.appendingPathComponent("Library/Application Support/figo", isDirectory: true)
  }

  public static var logs: URL { data.appendingPathComponent("logs", isDirectory: true) }

  /// Sockets live in the per-user temporary directory. It is asked of the system rather than
  /// read from `TMPDIR`, which shells and sandboxes are free to change, so the wrapper and
  /// the app always agree.
  public static var runtime: URL {
    if let override = ProcessInfo.processInfo.environment["FIGO_RUNTIME_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let base = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("figo", isDirectory: true)
  }

  /// The socket the app listens on for terminal sessions and the CLI.
  public static var appSocket: URL { runtime.appendingPathComponent("figo.sock") }
}
