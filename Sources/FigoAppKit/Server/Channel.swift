import FigoCore
import Foundation

/// One connected client as the app sees it. `SocketConnection` in the app; fakes in tests.
public protocol ClientConnection: AnyObject, Sendable {
  var id: Int { get }
  /// Sends one frame payload.
  func send(_ payload: Data)
  /// Runs `body` (on any thread) once everything sent so far has been written out.
  func whenFlushed(_ body: @escaping () -> Void)
  func close()
}

extension SocketConnection: ClientConnection {}

/// The sending half of one connected client, typed by what the app may send it.
@MainActor
public final class Channel<Outbound: Encodable> {
  public typealias Completion = @MainActor () -> Void

  public let id: Int
  private let write: (Data, Completion?) -> Void
  private let terminate: () -> Void
  private let encoder = JSONEncoder()

  /// `write` receives each encoded message and an optional callback to run on the main actor
  /// once it has been written out.
  public init(id: Int, write: @escaping (Data, Completion?) -> Void, close: @escaping () -> Void) {
    self.id = id
    self.write = write
    self.terminate = close
  }

  public convenience init(connection: ClientConnection) {
    self.init(
      id: connection.id,
      write: { payload, completion in
        connection.send(payload)
        if let completion {
          let box = CompletionBox(completion)
          connection.whenFlushed { DispatchQueue.main.async { MainActor.assumeIsolated { box.body() } } }
        }
      },
      close: { connection.close() })
  }

  public func send(_ message: Outbound, then completion: Completion? = nil) {
    guard let payload = try? encoder.encode(message) else { return }
    write(payload, completion)
  }

  public func close() {
    terminate()
  }
}

/// Carries a main-actor callback through the connection's queue.
private final class CompletionBox: @unchecked Sendable {
  let body: @MainActor () -> Void
  init(_ body: @escaping @MainActor () -> Void) { self.body = body }
}

/// What a client sent, decoded according to the role it announced in its hello.
public enum Inbound: Sendable {
  case hello(ClientHello)
  case terminal(TerminalMessage)
  case inputMethod(InputMethodMessage)
  case cli(CLIRequest)
}

/// Decodes one connection's frames. The first frame must be a `ClientHello`; it fixes how every
/// later frame is read. Used only on the connection's queue.
public struct InboundDecoder {
  public enum Failure: Error, Equatable {
    case expectedHello
  }

  public private(set) var role: ClientRole?
  private let decoder = JSONDecoder()

  public init() {}

  public mutating func decode(_ payload: Data) throws -> Inbound {
    guard let role else {
      guard let hello = try? decoder.decode(ClientHello.self, from: payload) else { throw Failure.expectedHello }
      self.role = hello.role
      return .hello(hello)
    }
    switch role {
    case .terminal: return .terminal(try decoder.decode(TerminalMessage.self, from: payload))
    case .inputMethod: return .inputMethod(try decoder.decode(InputMethodMessage.self, from: payload))
    case .cli: return .cli(try decoder.decode(CLIRequest.self, from: payload))
    }
  }
}
