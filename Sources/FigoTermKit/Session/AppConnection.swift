import Darwin
import FigoCore
import Foundation

/// The wrapper's connection to the Figo app.
///
/// The app is optional: when it is not running the wrapper is a plain pass-through, and it keeps
/// trying to connect in the background. Nothing here may ever block, because this runs on the
/// same thread that moves the user's keystrokes.
final class AppConnection {
  /// More than this queued means the app has stopped reading; give up on it rather than grow.
  private static let maxQueuedBytes = 4 * 1024 * 1024

  private(set) var descriptor: Int32 = -1
  private var decoder = FrameDecoder()
  private var outgoing = Data()
  private let encoder = JSONEncoder()
  private let jsonDecoder = JSONDecoder()

  var isConnected: Bool { descriptor >= 0 }
  var wantsWrite: Bool { isConnected && !outgoing.isEmpty }

  /// Connects and queues the hello. Returns false when the app is not listening.
  func connect(path: String, hello: ClientHello) -> Bool {
    disconnect()

    let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { return false }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
      close(socketDescriptor)
      return false
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: pathBytes)
    }

    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketDescriptor, $0, length) }
    }
    guard result == 0 else {
      close(socketDescriptor)
      return false
    }

    var enabled: Int32 = 1
    setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(socketDescriptor, F_SETFL, fcntl(socketDescriptor, F_GETFL) | O_NONBLOCK)
    _ = fcntl(socketDescriptor, F_SETFD, FD_CLOEXEC)

    descriptor = socketDescriptor
    enqueue(hello)
    return true
  }

  func disconnect() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
    outgoing.removeAll()
    decoder = FrameDecoder()
  }

  func send(_ message: TerminalMessage) {
    guard isConnected else { return }
    enqueue(message)
  }

  private func enqueue<Message: Encodable>(_ message: Message) {
    guard let payload = try? encoder.encode(message) else { return }
    outgoing.append(Frame.encode(payload))
    if outgoing.count > Self.maxQueuedBytes {
      disconnect()
      return
    }
    flush()
  }

  /// Writes as much of the queue as the socket accepts.
  func flush() {
    while isConnected, !outgoing.isEmpty {
      let written = outgoing.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if written > 0 {
        outgoing.removeSubrange(outgoing.startIndex..<outgoing.startIndex + written)
      } else if written < 0 && errno == EINTR {
        continue
      } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        return
      } else {
        disconnect()
      }
    }
  }

  /// Reads what has arrived. Returns nil when the app closed the connection.
  func receive() -> [TerminalCommand]? {
    var commands: [TerminalCommand] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while isConnected {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        do {
          while let payload = try decoder.next() {
            // A command this build does not know is skipped rather than fatal, so that an app
            // and wrappers from different versions keep working together.
            if let command = try? jsonDecoder.decode(TerminalCommand.self, from: payload) {
              commands.append(command)
            }
          }
        } catch {
          disconnect()
          return nil
        }
        if count < buffer.count { break }
      } else if count < 0 && errno == EINTR {
        continue
      } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        break
      } else {
        disconnect()
        return nil
      }
    }
    return commands
  }
}
