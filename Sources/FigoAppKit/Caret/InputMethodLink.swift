import FigoCore
import Foundation

/// The app's side of the connection to the input method helper: caret queries and the focus
/// reports it sends whenever a text input client gains or loses keyboard focus.
@MainActor
public final class InputMethodLink: CaretSource {
  private struct Client: Equatable {
    var bundleId: String?
    var pid: Int32?
  }

  /// Called when keyboard focus moved to a different text input client.
  public var onFocusMoved: (() -> Void)?
  public var onConnectionChange: (() -> Void)?

  public var isConnected: Bool { channel != nil }
  /// Bundle id of the client the helper last reported as focused.
  public private(set) var focusedBundleId: String?

  private var channel: Channel<InputMethodCommand>?
  private var activeClient: Client?
  /// The active client reported losing focus; whatever activates next is a focus move even if
  /// it belongs to the same app (another window or tab).
  private var activeClientDeactivated = false
  private var pending: [UInt64: CheckedContinuation<CaretReading?, Never>] = [:]
  private var nextQueryId: UInt64 = 1

  public init() {}

  public func attach(_ channel: Channel<InputMethodCommand>) {
    if let previous = self.channel, previous.id != channel.id {
      // A restarted helper connected before the old connection was noticed as closed.
      previous.close()
      answerAllPending(with: nil)
    }
    self.channel = channel
    onConnectionChange?()
  }

  public func detach(channelId: Int) {
    guard channel?.id == channelId else { return }
    channel = nil
    activeClient = nil
    focusedBundleId = nil
    answerAllPending(with: nil)
    onConnectionChange?()
  }

  public func receive(_ message: InputMethodMessage) {
    switch message {
    case .focus(let bundleId, let pid, let active):
      let client = Client(bundleId: bundleId, pid: pid)
      if active {
        let moved = client != activeClient || activeClientDeactivated
        activeClient = client
        activeClientDeactivated = false
        focusedBundleId = bundleId
        if moved { onFocusMoved?() }
      } else if client == activeClient {
        activeClientDeactivated = true
      }
    case .caret(let id, let rect, let bundleId):
      let continuation = pending.removeValue(forKey: id)
      continuation?.resume(returning: rect.map { CaretReading(rect: $0, bundleId: bundleId) })
    }
  }

  public func currentCaret(timeout: Duration) async -> CaretReading? {
    guard let channel else { return nil }
    let id = nextQueryId
    nextQueryId += 1
    return await withCheckedContinuation { continuation in
      pending[id] = continuation
      channel.send(.queryCaret(id: id))
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        self?.pending.removeValue(forKey: id)?.resume(returning: nil)
      }
    }
  }

  private func answerAllPending(with reading: CaretReading?) {
    let waiting = pending
    pending = [:]
    for continuation in waiting.values { continuation.resume(returning: reading) }
  }
}
