import Darwin
import FigoCore
import Foundation

@testable import FigoAppKit

struct TestClientError: Error, CustomStringConvertible {
  var description: String
}

/// A blocking socket client speaking the real `FigoCore` framing, standing in for a pty wrapper,
/// the input method helper or the CLI. Reads happen off the main actor so the app's server,
/// which delivers to the main actor, keeps running while a test waits.
final class TestClient: @unchecked Sendable {
  private let fd: Int32
  private let lock = NSLock()
  private var decoder = FrameDecoder()

  init(path: String, hello: ClientHello) throws {
    fd = try UnixSocket.connect(to: path)
    try send(hello)
  }

  deinit {
    Darwin.close(fd)
  }

  func send<Message: Encodable>(_ message: Message) throws {
    let frame = try Frame.encode(message)
    try frame.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        guard written > 0 else { throw TestClientError(description: "write failed: \(errno)") }
        offset += written
      }
    }
  }

  /// Shuts the connection down so the app sees end-of-stream.
  func disconnect() {
    Darwin.shutdown(fd, SHUT_RDWR)
  }

  /// The next message of type `Message`, waiting up to `timeout`.
  func receive<Message: Decodable & Sendable>(
    _ type: Message.Type, timeout: TimeInterval = 5
  ) async throws -> Message {
    let payload = try await nextPayload(timeout: timeout)
    return try JSONDecoder().decode(Message.self, from: payload)
  }

  private func nextPayload(timeout: TimeInterval) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { [self] in
        continuation.resume(with: Result { try readPayload(timeout: timeout) })
      }
    }
  }

  private func readPayload(timeout: TimeInterval) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let payload = try decoder.next() { return payload }
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw TestClientError(description: "timed out waiting for a message") }
      var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&poller, 1, Int32(remaining * 1000))
      if ready < 0 && errno == EINTR { continue }
      guard ready > 0 else { continue }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      guard count > 0 else { throw TestClientError(description: "connection closed") }
      buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
    }
  }

  /// Answers every caret query with `rect`, as the input method helper would, until the
  /// connection closes.
  func answerCaretQueries(with rect: ScreenRect, bundleId: String) {
    Thread.detachNewThread { [self] in
      while let command = try? readPayload(timeout: 30),
        let query = try? JSONDecoder().decode(InputMethodCommand.self, from: command)
      {
        guard case .queryCaret(let id) = query else { continue }
        try? send(InputMethodMessage.caret(id: id, rect: rect, bundleId: bundleId))
      }
    }
  }
}
