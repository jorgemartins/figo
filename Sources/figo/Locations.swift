import FigoCore
import FigoInstallKit
import Foundation

/// Finds the pieces of the installation relative to this executable.
enum Locations {
  /// `Figo.app` when the CLI runs from inside the bundle (directly or through a symlink).
  static var appBundle: URL? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    let bundle = contents.deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else { return nil }
    return bundle
  }

  static var bundledThemes: URL? {
    appBundle?.appendingPathComponent("Contents/Resources/themes", isDirectory: true)
  }

  static func inputMethodInstaller() throws -> InputMethodInstaller {
    guard let appBundle else {
      throw CommandFailure("The input method can only be installed from inside Figo.app (build it with scripts/bundle.sh).")
    }
    return InputMethodInstaller(helperBundle: InputMethodInstaller.helperBundle(inApp: appBundle))
  }
}
