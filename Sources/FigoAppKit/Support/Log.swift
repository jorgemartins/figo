import Foundation

public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
  case debug
  case info
  case warn
  case error

  public init?(name: String) {
    switch name.lowercased() {
    case "debug", "trace": self = .debug
    case "info": self = .info
    case "warn", "warning": self = .warn
    case "error": self = .error
    default: return nil
    }
  }

  public var name: String {
    switch self {
    case .debug: "DEBUG"
    case .info: "INFO"
    case .warn: "WARN"
    case .error: "ERROR"
    }
  }

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Appends log lines to one file. Nothing is written until `configure` is called, so unit tests
/// and other library users never create files as a side effect.
public final class LogSink: @unchecked Sendable {
  public static let shared = LogSink()

  /// The file is rotated once at configuration time when it has grown past this size.
  private static let rotationSize = 4 * 1024 * 1024

  private let queue = DispatchQueue(label: "dev.figo.log")
  private let lock = NSLock()
  private var minimum: LogLevel = .info
  private var handle: FileHandle?
  private let timestamp: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  public func configure(file: URL, level: LogLevel) {
    let manager = FileManager.default
    try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = try? manager.attributesOfItem(atPath: file.path)[.size] as? Int, size > Self.rotationSize {
      let previous = file.appendingPathExtension("1")
      try? manager.removeItem(at: previous)
      try? manager.moveItem(at: file, to: previous)
    }
    // O_APPEND, because a second copy that starts only to find the first one running writes to
    // the same file; without it each process would overwrite the other's lines.
    let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    let opened = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil

    lock.lock()
    minimum = level
    handle = opened
    lock.unlock()
  }

  /// `FIGO_LOG_LEVEL` wins over `fallback`.
  public static func level(from environment: [String: String], fallback: LogLevel = .info) -> LogLevel {
    environment["FIGO_LOG_LEVEL"].flatMap(LogLevel.init(name:)) ?? fallback
  }

  /// Waits for queued lines to reach the file, for use right before `exit`.
  public func flush() {
    queue.sync {}
  }

  public func isEnabled(_ level: LogLevel) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return handle != nil && level >= minimum
  }

  func write(_ level: LogLevel, _ category: String, _ message: String) {
    let now = Date()
    queue.async { [self] in
      lock.lock()
      let handle = self.handle
      lock.unlock()
      guard let handle else { return }
      let line = "\(timestamp.string(from: now)) \(level.name) [\(category)] \(message)\n"
      try? handle.write(contentsOf: Data(line.utf8))
    }
  }
}

/// A named logger, typically one per file: `private let log = Log("server")`.
public struct Log: Sendable {
  public let category: String

  public init(_ category: String) {
    self.category = category
  }

  public func debug(_ message: @autoclosure () -> String) { emit(.debug, message) }
  public func info(_ message: @autoclosure () -> String) { emit(.info, message) }
  public func warn(_ message: @autoclosure () -> String) { emit(.warn, message) }
  public func error(_ message: @autoclosure () -> String) { emit(.error, message) }

  public func log(_ level: LogLevel, _ message: @autoclosure () -> String) { emit(level, message) }

  private func emit(_ level: LogLevel, _ message: () -> String) {
    let sink = LogSink.shared
    guard sink.isEnabled(level) else { return }
    sink.write(level, category, message())
  }
}
