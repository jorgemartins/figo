import FigoCore
import Foundation

/// Appends to `inputmethod.log`. Kept tiny: the helper cannot use the app's logging library
/// without pulling in AppKit's web stack.
enum IMLog {
  private static let queue = DispatchQueue(label: "dev.figo.inputmethod.log")
  nonisolated(unsafe) private static var handle: FileHandle?
  nonisolated(unsafe) private static var verbose = false

  static func configure() {
    let file = FigoPaths.logs.appendingPathComponent("inputmethod.log")
    try? FileManager.default.createDirectory(at: FigoPaths.logs, withIntermediateDirectories: true)
    let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    let level = ProcessInfo.processInfo.environment["FIGO_LOG_LEVEL"]?.lowercased()
    verbose = level == "debug" || level == "trace"
  }

  static func info(_ message: @autoclosure () -> String) {
    write("INFO", message())
  }

  static func debug(_ message: @autoclosure () -> String) {
    guard verbose else { return }
    write("DEBUG", message())
  }

  private static func write(_ level: String, _ message: String) {
    let line = "\(Date().ISO8601Format()) \(level) \(message)\n"
    queue.async { try? handle?.write(contentsOf: Data(line.utf8)) }
  }
}
