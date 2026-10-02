import FigoCore
import Foundation

public enum RouterError: Error, Equatable, CustomStringConvertible {
  case unknownSession(String)
  case noCurrentSession
  case timedOut
  case disconnected
  case failed(String)
  case unexpectedReply

  public var description: String {
    switch self {
    case .unknownSession(let id): "No terminal session \(id)"
    case .noCurrentSession: "No terminal session is active"
    case .timedOut: "Timed out waiting for the terminal session to reply"
    case .disconnected: "The terminal session disconnected"
    case .failed(let message): message
    case .unexpectedReply: "The terminal session sent an unexpected reply"
    }
  }
}

@MainActor
public protocol SessionRouterDelegate: AnyObject {
  func router(_ router: SessionRouter, emit event: PageEvent)
  /// The current session's edit buffer changed, possibly because another session became current.
  func routerCurrentBufferDidChange(_ router: SessionRouter)
  /// The current session started running a command.
  func routerCurrentSessionDidStartCommand(_ router: SessionRouter)
  func routerCurrentSessionDidDisconnect(_ router: SessionRouter)
  /// Sessions connected, disconnected or changed shell.
  func routerSessionsDidChange(_ router: SessionRouter)
}

/// Keeps track of the connected pty wrappers, decides which one the popup belongs to, turns their
/// messages into page events, and routes the page's requests back to the right wrapper.
@MainActor
public final class SessionRouter {
  public struct Session {
    public let hello: TerminalHello
    public internal(set) var shell = ShellInfo()
    public internal(set) var environment: [String: String] = [:]
    public internal(set) var aliases = ""
    public internal(set) var editBuffer: EditBuffer?
    let channel: Channel<TerminalCommand>
    let ordinal: Int
    /// The context the page last received for this session; nil until it was announced.
    var announcedContext: ShellContext?
    /// What the page asked for through `shell.setIntercept`.
    var requestedIntercept: InterceptConfiguration?
    /// What was last sent to the wrapper.
    var sentIntercept: InterceptConfiguration?
  }

  private struct PendingReply {
    let sessionId: String
    let continuation: CheckedContinuation<TerminalReply, Error>
    let timer: Task<Void, Never>
  }

  public weak var delegate: SessionRouterDelegate?
  /// Requests to wrappers wait at least this long, whatever the page asked for.
  public var minimumReplyTimeout: Duration = .seconds(10)
  /// Used for `ShellContext.home` until the shell reports `HOME`.
  public var fallbackHome = FileManager.default.homeDirectoryForCurrentUser.path

  public private(set) var sessions: [String: Session] = [:]
  public private(set) var currentSessionId: String?
  /// Whether the popup is on screen. Bound keys are only taken from the shell while it is, so a
  /// popup that the app hid (or could not show) never swallows Enter or the arrows.
  public var popupVisible = false {
    didSet { if popupVisible != oldValue { syncIntercepts() } }
  }

  private var interceptSessionId: String?
  private var pending: [UInt64: PendingReply] = [:]
  private var nextRequestId: UInt64 = 1
  private var nextOrdinal = 0

  public init() {}

  public var currentSession: Session? { currentSessionId.flatMap { sessions[$0] } }

  // MARK: - Connections

  public func connect(_ hello: TerminalHello, channel: Channel<TerminalCommand>) {
    let sessionId = hello.sessionId
    if let previous = sessions[sessionId] {
      // The wrapper reconnected before the old connection was noticed as closed.
      failPendingRequests(of: sessionId)
      previous.channel.close()
    }
    nextOrdinal += 1
    sessions[sessionId] = Session(hello: hello, channel: channel, ordinal: nextOrdinal)
    delegate?.routerSessionsDidChange(self)
  }

  /// `channelId` guards against a stale connection removing the session that replaced it.
  public func disconnect(sessionId: String, channelId: Int) {
    guard let session = sessions[sessionId], session.channel.id == channelId else { return }
    sessions[sessionId] = nil
    failPendingRequests(of: sessionId)
    if interceptSessionId == sessionId { interceptSessionId = nil }
    if currentSessionId == sessionId {
      currentSessionId = nil
      emit(.editBuffer(sessionId: sessionId, buffer: nil, cursor: 0))
      delegate?.routerCurrentSessionDidDisconnect(self)
    }
    delegate?.routerSessionsDidChange(self)
  }

  // MARK: - Wrapper messages

  public func receive(_ message: TerminalMessage, from sessionId: String) {
    guard sessions[sessionId] != nil else { return }
    switch message {
    case .shell(let info):
      sessions[sessionId]?.shell = info
      contextMayHaveChanged(sessionId)
      delegate?.routerSessionsDidChange(self)
    case .environment(let variables, let aliases):
      sessions[sessionId]?.environment = variables
      sessions[sessionId]?.aliases = aliases
      contextMayHaveChanged(sessionId)
    case .prompt:
      emit(.prompt(sessionId: sessionId))
    case .preExec:
      sessions[sessionId]?.editBuffer = nil
      emit(.preExec(sessionId: sessionId))
      if sessionId == currentSessionId { delegate?.routerCurrentSessionDidStartCommand(self) }
    case .postExec(let command, let exitCode):
      emit(.postExec(sessionId: sessionId, command: command, exitCode: exitCode))
    case .editBuffer(let buffer):
      receiveEditBuffer(buffer, from: sessionId)
    case .key(let action):
      emit(.keybinding(sessionId: sessionId, action: action))
    case .reply(let id, let result):
      guard let reply = pending[id], reply.sessionId == sessionId else { return }
      finish(id, with: .success(result))
    }
  }

  private func receiveEditBuffer(_ buffer: EditBuffer?, from sessionId: String) {
    sessions[sessionId]?.editBuffer = buffer
    if let buffer {
      // The popup belongs to the tab that is being typed in. A command finishing in another tab
      // draws a prompt there, and typing ahead even puts text on it, but neither moves the
      // keyboard: taking the popup away would send the Enter meant for it to the shell.
      if sessionId != currentSessionId, currentSession != nil, buffer.typed == false { return }
      currentSessionId = sessionId
      announceIfNeeded(sessionId)
      emit(.editBuffer(sessionId: sessionId, buffer: buffer.text, cursor: buffer.cursor))
      delegate?.routerCurrentBufferDidChange(self)
    } else if sessionId == currentSessionId {
      emit(.editBuffer(sessionId: sessionId, buffer: nil, cursor: 0))
      delegate?.routerCurrentBufferDidChange(self)
    }
  }

  // MARK: - Context announcements

  public func context(of sessionId: String) -> ShellContext? {
    guard let session = sessions[sessionId] else { return nil }
    return ShellContext(
      hello: session.hello, shell: session.shell, environment: session.environment, aliases: session.aliases,
      fallbackHome: fallbackHome)
  }

  /// Forget what the page has been told, because the page reloaded.
  public func resetAnnouncements() {
    for id in sessions.keys { sessions[id]?.announcedContext = nil }
  }

  private func announceIfNeeded(_ sessionId: String) {
    guard let context = context(of: sessionId), sessions[sessionId]?.announcedContext != context else { return }
    sessions[sessionId]?.announcedContext = context
    emit(.session(context))
  }

  private func contextMayHaveChanged(_ sessionId: String) {
    // Sessions are introduced to the page by their first edit buffer, not before.
    guard sessions[sessionId]?.announcedContext != nil else { return }
    announceIfNeeded(sessionId)
  }

  private func emit(_ event: PageEvent) {
    delegate?.router(self, emit: event)
  }

  // MARK: - Page requests

  public func insert(sessionId: String, text: String, insertionBuffer: String?) throws {
    try session(sessionId).channel.send(.insert(text: text, insertionBuffer: insertionBuffer))
  }

  public func setIntercept(sessionId: String, _ configuration: InterceptConfiguration) throws {
    _ = try session(sessionId)
    for id in sessions.keys { sessions[id]?.requestedIntercept = nil }
    sessions[sessionId]?.requestedIntercept = configuration
    interceptSessionId = sessionId
    syncIntercepts()
  }

  /// Sends each wrapper what it should intercept now: the page's request for the chosen session
  /// (bound keys only while the popup is visible) and nothing for every other session.
  private func syncIntercepts() {
    for (id, session) in sessions {
      var effective = InterceptConfiguration.off
      if id == interceptSessionId, let requested = session.requestedIntercept {
        effective = requested
        effective.interceptBound = requested.interceptBound && popupVisible
      }
      // Sessions the page never configured are left alone until the first request.
      if session.sentIntercept == nil && interceptSessionId == nil { continue }
      guard session.sentIntercept != effective else { continue }
      sessions[id]?.sentIntercept = effective
      session.channel.send(.intercept(effective))
    }
  }

  public func simulateInput(sessionId: String?, text: String) throws {
    guard let id = sessionId ?? currentSessionId else { throw RouterError.noCurrentSession }
    try session(id).channel.send(.simulateInput(text: text))
  }

  public func runProcess(sessionId: String, _ request: ProcessRequest) async throws -> ProcessResult {
    let requested = Duration.milliseconds(request.timeoutMilliseconds ?? 60_000)
    let reply = try await send(to: sessionId, timeout: max(requested, minimumReplyTimeout)) {
      .runProcess(id: $0, request: request)
    }
    switch reply {
    case .process(let result): return result
    case .failure(let message): throw RouterError.failed(message)
    case .directory: throw RouterError.unexpectedReply
    }
  }

  public func listDirectory(sessionId: String, path: String) async throws -> [DirectoryEntry] {
    let reply = try await send(to: sessionId, timeout: minimumReplyTimeout) { .listDirectory(id: $0, path: path) }
    switch reply {
    case .directory(let entries): return entries
    case .failure(let message): throw RouterError.failed(message)
    case .process: throw RouterError.unexpectedReply
    }
  }

  private func send(
    to sessionId: String, timeout: Duration, command: (UInt64) -> TerminalCommand
  ) async throws -> TerminalReply {
    let channel = try session(sessionId).channel
    let id = nextRequestId
    nextRequestId += 1
    let message = command(id)
    return try await withCheckedThrowingContinuation { continuation in
      let timer = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        self?.finish(id, with: .failure(RouterError.timedOut))
      }
      pending[id] = PendingReply(sessionId: sessionId, continuation: continuation, timer: timer)
      channel.send(message)
    }
  }

  private func finish(_ id: UInt64, with result: Result<TerminalReply, Error>) {
    guard let reply = pending.removeValue(forKey: id) else { return }
    reply.timer.cancel()
    reply.continuation.resume(with: result)
  }

  private func failPendingRequests(of sessionId: String) {
    for (id, reply) in pending where reply.sessionId == sessionId {
      finish(id, with: .failure(RouterError.disconnected))
    }
  }

  public var pendingRequestCount: Int { pending.count }

  private func session(_ id: String) throws -> Session {
    guard let session = sessions[id] else { throw RouterError.unknownSession(id) }
    return session
  }

  // MARK: - Status

  public func summaries() -> [SessionSummary] {
    sessions.values.sorted { $0.ordinal < $1.ordinal }.map {
      SessionSummary(
        hello: $0.hello, shell: $0.shell, editBuffer: $0.editBuffer, isCurrent: $0.hello.sessionId == currentSessionId)
    }
  }
}
