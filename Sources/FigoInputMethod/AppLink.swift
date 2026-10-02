import Darwin
import FigoCore
import Foundation

/// The helper's connection to the Figo app. It keeps reconnecting with backoff while the app is
/// not running. Reads happen on a dedicated thread and writes on a serial queue, so the input
/// method's main thread, which the text input system calls into, never waits on the socket.
final class AppLink: @unchecked Sendable {
  private let path: String
  private let lock = NSLock()
  private let writes = DispatchQueue(label: "dev.figo.inputmethod.writes")
  private var fd: Int32 = -1

  /// Called on the main thread.
  var onCommand: ((InputMethodCommand) -> Void)?
  /// Called on the main thread after each successful (re)connection.
  var onConnect: (() -> Void)?

  init(path: String) {
    self.path = path
  }

  func start() {
    let thread = Thread { [self] in run() }
    thread.name = "dev.figo.inputmethod.link"
    thread.start()
  }

  func send(_ message: InputMethodMessage) {
    guard let payload = try? JSONEncoder().encode(message) else { return }
    write(Frame.encode(payload))
  }

  private func run() {
    var delay: TimeInterval = 0.5
    while true {
      if let socket = connect() {
        IMLog.info("connected to \(path)")
        delay = 0.5
        lock.lock()
        fd = socket
        lock.unlock()
        if let hello = try? Frame.encode(ClientHello(role: .inputMethod)) { write(hello) }
        DispatchQueue.main.async { [self] in onConnect?() }
        readUntilClosed(socket)
        lock.lock()
        fd = -1
        lock.unlock()
        writes.sync { _ = Darwin.close(socket) }
        IMLog.info("disconnected")
      }
      Thread.sleep(forTimeInterval: delay)
      delay = min(delay * 2, 10)
    }
  }

  private func readUntilClosed(_ socket: Int32) {
    var decoder = FrameDecoder()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    let json = JSONDecoder()
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return }
      buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
      do {
        while let payload = try decoder.next() {
          guard let command = try? json.decode(InputMethodCommand.self, from: payload) else { continue }
          DispatchQueue.main.async { [self] in onCommand?(command) }
        }
      } catch {
        return
      }
    }
  }

  private func write(_ frame: Data) {
    writes.async { [self] in
      lock.lock()
      let socket = fd
      lock.unlock()
      guard socket >= 0 else { return }
      var offset = 0
      while offset < frame.count {
        let written = frame.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + offset, frame.count - offset) }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { return }
        offset += written
      }
    }
  }

  private func connect() -> Int32? {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { return nil }
    _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
    var one: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    // A stuck app must not stall the write queue forever.
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    // macOS accepts socket addresses longer than sockaddr_un when given a larger buffer.
    let bytes = Array(path.utf8)
    let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
    let length = pathOffset + bytes.count + 1
    guard !bytes.isEmpty, length <= 255 else {
      Darwin.close(socket)
      return nil
    }
    var storage = [UInt8](repeating: 0, count: max(length, MemoryLayout<sockaddr_un>.size))
    storage[0] = UInt8(length)
    storage[1] = UInt8(AF_UNIX)
    storage.replaceSubrange(pathOffset..<pathOffset + bytes.count, with: bytes)
    let result = storage.withUnsafeBytes {
      Darwin.connect(socket, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(length))
    }
    guard result == 0 else {
      Darwin.close(socket)
      return nil
    }
    return socket
  }
}
