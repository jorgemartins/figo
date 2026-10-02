import FigoInstallKit
import Foundation

private let log = Log("setup")

/// Runs the input method install from the Settings window. Only ever started by a button.
@MainActor
public enum InputMethodSetup {
  /// The argument that makes the app executable finish an install and exit (see
  /// `InputMethodFinishResult` for why this needs a fresh process).
  public static let finishArgument = "--finish-input-method-install"

  /// Places, registers and enables the input method, then selects it from fresh processes,
  /// retrying while the system catches up.
  public static func install(_ installer: InputMethodInstaller, executable: URL) async -> String {
    do {
      log.info("installing the input method from \(installer.helperBundle.path)")
      try installer.install(.symlink)
    } catch {
      log.error("input method install failed: \(error)")
      return "Install failed: \(error)"
    }
    var last = InputMethodFinishResult.notEnabled
    for attempt in 1...10 {
      last = await finishInFreshProcess(executable: executable)
      log.info("finish attempt \(attempt): \(last.rawValue)")
      if last == .selected { return "Installed. Restart terminals that were already open." }
      try? await Task.sleep(for: .seconds(1))
    }
    return "Installed, but the input source is still \(last.rawValue). Try Reinstall, or log out and back in."
  }

  public static func uninstall(_ installer: InputMethodInstaller) -> String {
    do {
      try installer.uninstall()
      log.info("input method uninstalled")
      return "Uninstalled."
    } catch {
      return "Uninstall failed: \(error)"
    }
  }

  /// Runs `<executable> --finish-input-method-install` and reads its one-word answer.
  static func finishInFreshProcess(executable: URL) async -> InputMethodFinishResult {
    await withCheckedContinuation { continuation in
      let process = Process()
      let output = Pipe()
      process.executableURL = executable
      process.arguments = [finishArgument]
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { _ in
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let word = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(returning: InputMethodFinishResult(rawValue: word) ?? .notRegistered)
      }
      do {
        try process.run()
      } catch {
        continuation.resume(returning: .notRegistered)
      }
    }
  }
}
