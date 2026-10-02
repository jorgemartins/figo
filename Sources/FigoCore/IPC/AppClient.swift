import Foundation

/// A small blocking client for the app's socket, for one-shot tools such as the CLI.
public final class AppClient {
  public enum Failure: Error, CustomStringConvertible {
    case notRunning
    case connectionLost
    case timedOut

    public var description: String {
      switch self {
      case .notRunning: return "Figo is not running"
      case .connectionLost: return "Figo closed the connection"
      case .timedOut: return "Figo did not answer in time"
      }
    }
  }

  private let descriptor: Int32
  private var decoder = FrameDecoder()

  /// Connects and introduces itself with `role`.
  public init(role: ClientRole, socketPath: String = FigoPaths.appSocket.path) throws {
    let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { throw Failure.notRunning }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(socketDescriptor)
      throw Failure.notRunning
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(socketDescriptor)
      throw Failure.notRunning
    }
    var enabled: Int32 = 1
    setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    descriptor = socketDescriptor
    try send(ClientHello(role: role))
  }

  deinit {
    close(descriptor)
  }

  public func send<Message: Encodable>(_ message: Message) throws {
    let frame = try Frame.encode(message)
    try frame.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0 && errno == EINTR {
          continue
        } else {
          throw Failure.connectionLost
        }
      }
    }
  }

  /// Waits for the next message, for at most `timeout` seconds.
  public func receive<Message: Decodable>(_ type: Message.Type, timeout: TimeInterval = 5) throws -> Message {
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let payload = try decoder.next() {
        return try JSONDecoder().decode(type, from: payload)
      }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw Failure.timedOut }
      var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&poller, 1, Int32(remaining * 1000) + 1)
      if ready < 0 && errno == EINTR { continue }
      guard ready > 0 else { throw Failure.timedOut }
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
      } else if count < 0 && errno == EINTR {
        continue
      } else {
        throw Failure.connectionLost
      }
    }
  }

  /// Sends one CLI request and returns the app's answer.
  public static func request(_ request: CLIRequest, timeout: TimeInterval = 5) throws -> CLIResponse {
    let client = try AppClient(role: .cli)
    try client.send(request)
    return try client.receive(CLIResponse.self, timeout: timeout)
  }

  /// True when an app is listening on the socket.
  public static var isAppRunning: Bool {
    (try? request(.status, timeout: 2)) != nil
  }
}
