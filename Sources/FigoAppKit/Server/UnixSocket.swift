import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible, Equatable {
  public let operation: String
  public let code: Int32

  public init(_ operation: String, code: Int32 = errno) {
    self.operation = operation
    self.code = code
  }

  public var description: String { "\(operation) failed: \(String(cString: strerror(code))) (\(code))" }
}

/// Plain BSD socket calls for unix-domain stream sockets.
public enum UnixSocket {
  /// `sockaddr_un.sun_path` is 104 bytes, but the macOS kernel accepts addresses up to 255 bytes
  /// when the caller passes a larger buffer. Using that keeps long runtime directories (deep
  /// scratch or test paths) working; the default `FigoPaths.appSocket` fits either way.
  static let maxPathLength = 253

  static func withAddress<Result>(
    _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
  ) throws -> Result {
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, bytes.count <= maxPathLength else { throw SocketError("socket path", code: ENAMETOOLONG) }
    let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
    let length = pathOffset + bytes.count + 1
    var storage = [UInt8](repeating: 0, count: max(length, MemoryLayout<sockaddr_un>.size))
    storage[0] = UInt8(length)  // sun_len
    storage[1] = UInt8(AF_UNIX)  // sun_family
    storage.replaceSubrange(pathOffset..<pathOffset + bytes.count, with: bytes)
    return try storage.withUnsafeBytes { raw in
      try body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(length))
    }
  }

  /// Binds and listens. The socket file is made readable and writable by the owner only.
  public static func listen(at path: String, backlog: Int32 = 64) throws -> Int32 {
    let fd = try makeSocket()
    do {
      try withAddress(path) { address, length in
        guard Darwin.bind(fd, address, length) == 0 else { throw SocketError("bind \(path)") }
      }
      chmod(path, 0o600)
      guard Darwin.listen(fd, backlog) == 0 else { throw SocketError("listen") }
      try setNonBlocking(fd)
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  /// A blocking connection to `path`.
  public static func connect(to path: String) throws -> Int32 {
    let fd = try makeSocket()
    do {
      try withAddress(path) { address, length in
        guard Darwin.connect(fd, address, length) == 0 else { throw SocketError("connect \(path)") }
      }
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  /// True when something accepts connections at `path` right now.
  public static func isListening(at path: String) -> Bool {
    guard let fd = try? connect(to: path) else { return false }
    Darwin.close(fd)
    return true
  }

  static func makeSocket() throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError("socket") }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    // A peer that disappears mid-write must produce EPIPE, not kill the app with SIGPIPE.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
  }

  static func setNonBlocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw SocketError("fcntl") }
  }
}
