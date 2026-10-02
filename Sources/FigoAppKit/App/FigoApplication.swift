import AppKit
import FigoCore
import FigoInstallKit

private let log = Log("app")

/// The app's entry point, called from `FigoApp/main.swift`.
public enum FigoApplication {
  @MainActor
  public static func main(arguments: [String] = CommandLine.arguments) -> Never {
    if arguments.contains(InputMethodSetup.finishArgument) {
      // A short-lived helper process for the input method install; see `InputMethodFinishResult`.
      let result = InputMethodInstaller.finishInstallation()
      print(result.rawValue)
      exit(result == .selected ? 0 : 1)
    }

    let environment = ProcessInfo.processInfo.environment
    LogSink.shared.configure(
      file: FigoPaths.logs.appendingPathComponent("app.log"), level: LogSink.level(from: environment))

    guard prepareRuntimeDirectory() else {
      LogSink.shared.flush()
      exit(1)
    }
    let socket = FigoPaths.appSocket.path
    if !acquireInstanceLock() || UnixSocket.isListening(at: socket) {
      log.info("another Figo is already running for \(FigoPaths.runtime.path); exiting")
      LogSink.shared.flush()
      exit(0)
    }
    // Nobody answers, so whatever is there is left over from a crash.
    unlink(socket)

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
    LogSink.shared.flush()
    exit(0)
  }

  /// Held (never closed) for the life of the process, so two copies started at the same moment
  /// cannot both decide the socket is stale and bind it in turn.
  private static func acquireInstanceLock() -> Bool {
    let path = FigoPaths.runtime.appendingPathComponent("figo.lock").path
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    // Without a lock file the socket check alone has to do.
    guard fd >= 0 else { return true }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      return false
    }
    return true
  }

  /// The socket directory must exist and be private to the user.
  private static func prepareRuntimeDirectory() -> Bool {
    let directory = FigoPaths.runtime
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      return true
    } catch {
      log.error("cannot prepare \(directory.path): \(error)")
      FileHandle.standardError.write(Data("figo: cannot prepare \(directory.path): \(error)\n".utf8))
      return false
    }
  }
}
