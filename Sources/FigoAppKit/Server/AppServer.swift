import FigoCore
import Foundation

private let log = Log("server")

/// Listens on the app socket and feeds every client's decoded messages to the `AppCore`, in
/// order, on the main actor.
@MainActor
public final class AppServer {
  private final class CoreReference: @unchecked Sendable {
    weak var core: AppCore?
    init(_ core: AppCore) { self.core = core }
  }

  /// Confined to one connection's queue.
  private final class DecoderBox: @unchecked Sendable {
    var decoder = InboundDecoder()
  }

  public let path: String
  private let server: SocketServer

  public init(path: String) {
    self.path = path
    server = SocketServer(path: path)
  }

  public func start(core: AppCore) throws {
    let reference = CoreReference(core)
    try server.start { connection in
      let box = DecoderBox()
      connection.start(
        onFrame: { payload in
          let inbound: Inbound
          do {
            inbound = try box.decoder.decode(payload)
          } catch {
            if box.decoder.role == nil {
              log.warn("client \(connection.id) did not start with a hello; closing")
              connection.close()
            } else {
              log.warn("client \(connection.id) sent an unreadable message: \(error)")
            }
            return
          }
          DispatchQueue.main.async {
            MainActor.assumeIsolated { reference.core?.receive(inbound, from: connection) }
          }
        },
        onClose: {
          DispatchQueue.main.async {
            MainActor.assumeIsolated { reference.core?.connectionClosed(connection.id) }
          }
        })
    }
    log.info("listening on \(path)")
  }

  public func stop() {
    server.stop()
  }
}
