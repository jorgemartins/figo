import CoreGraphics
import FigoCore
import Foundation

private let log = Log("core")
private let pageLog = Log("page")

/// The app's logic without any AppKit: it connects the socket clients (pty wrappers, the input
/// method helper, the CLI), the popup page and the popup's presenter. Everything runs on the
/// main actor; socket I/O happens elsewhere and arrives here as decoded messages.
@MainActor
public final class AppCore {
  private enum Peer {
    case terminal(sessionId: String)
    case inputMethod
    case cli(Channel<CLIResponse>)
  }

  public let settings: SettingsStore
  public let router = SessionRouter()
  public let inputMethod = InputMethodLink()
  public let presenter: PopupPresenter
  public var themes: ThemeCatalog
  public weak var page: PageSink?

  public var onQuit: (() -> Void)?
  public var onOpenSettings: (() -> Void)?
  /// Sessions or the input method connection changed (for the menu's status line).
  public var onStatusChange: (() -> Void)?

  /// What the page last reported through `app.reportState`, as JSON text.
  public private(set) var popupState: String?

  private var peers: [Int: Peer] = [:]
  private var frontmostPid: Int32?

  public init(settings: SettingsStore, window: PopupWindowing, desktop: DesktopEnvironment, themes: ThemeCatalog) {
    self.settings = settings
    self.themes = themes
    presenter = PopupPresenter(window: window, caretSource: FixedCaretSource() ?? inputMethod, desktop: desktop)
    frontmostPid = desktop.frontmostApplication?.pid

    router.delegate = self
    presenter.isDisabled = { [unowned settings] in settings.bool(SettingKey.disable) == true }
    presenter.allowsBackgroundTerminal = ProcessInfo.processInfo.environment["FIGO_DEBUG_ALLOW_BACKGROUND"] == "1"
    presenter.decisionHeight = { [unowned settings] in
      CGFloat(settings.double(SettingKey.height).flatMap { $0 > 0 ? $0 : nil } ?? 140)
    }
    presenter.onVisibilityChange = { [weak self] visible, reason in
      self?.popupVisibilityChanged(visible, reason: reason)
    }
    inputMethod.onFocusMoved = { [weak self] in self?.presenter.hide(.focusMoved) }
    inputMethod.onConnectionChange = { [weak self] in self?.onStatusChange?() }
    settings.observe { [weak self] values, changed in self?.settingsChanged(values, changed: changed) }
  }

  // MARK: - Clients

  public func receive(_ inbound: Inbound, from connection: ClientConnection) {
    switch inbound {
    case .hello(let hello):
      register(hello, connection: connection)
    case .terminal(let message):
      guard case .terminal(let sessionId)? = peers[connection.id] else { return }
      router.receive(message, from: sessionId)
    case .inputMethod(let message):
      guard case .inputMethod? = peers[connection.id] else { return }
      inputMethod.receive(message)
    case .cli(let request):
      guard case .cli(let channel)? = peers[connection.id] else { return }
      handle(request, reply: channel)
    }
  }

  public func connectionClosed(_ id: Int) {
    switch peers.removeValue(forKey: id) {
    case .terminal(let sessionId)?: router.disconnect(sessionId: sessionId, channelId: id)
    case .inputMethod?: inputMethod.detach(channelId: id)
    case .cli?, nil: break
    }
  }

  private func register(_ hello: ClientHello, connection: ClientConnection) {
    if hello.version != Figo.version {
      log.warn("\(hello.role.rawValue) client \(connection.id) runs version \(hello.version), the app \(Figo.version)")
    }
    switch hello.role {
    case .terminal:
      guard let terminal = hello.terminal else {
        log.warn("terminal client \(connection.id) sent no session; closing")
        connection.close()
        return
      }
      peers[connection.id] = .terminal(sessionId: terminal.sessionId)
      router.connect(terminal, channel: Channel(connection: connection))
      log.info("session \(terminal.sessionId) connected (\(terminal.terminalBundleId ?? "unknown terminal"))")
    case .inputMethod:
      peers[connection.id] = .inputMethod
      inputMethod.attach(Channel(connection: connection))
      log.info("input method connected")
    case .cli:
      peers[connection.id] = .cli(Channel(connection: connection))
    }
  }

  // MARK: - CLI

  private func handle(_ request: CLIRequest, reply: Channel<CLIResponse>) {
    switch request {
    case .status:
      reply.send(.status(status()))
    case .quit:
      log.info("quit requested by the CLI")
      reply.send(.ok) { [weak self] in self?.onQuit?() }
    case .openSettings:
      onOpenSettings?()
      reply.send(.ok)
    case .simulateInput(let sessionId, let text):
      do {
        try router.simulateInput(sessionId: sessionId, text: text)
        reply.send(.ok)
      } catch {
        reply.send(.failure("\(error)"))
      }
    }
  }

  public func status() -> AppStatus {
    AppStatus(
      version: Figo.version, pid: getpid(), sessions: router.summaries(), inputMethodConnected: inputMethod.isConnected,
      focusedBundleId: inputMethod.focusedBundleId, caret: presenter.caret?.rect, popupVisible: presenter.isVisible,
      popupFrame: presenter.frame.map(ScreenRect.init), popupState: popupState)
  }

  // MARK: - Desktop

  /// Another application became frontmost (`NSWorkspace` activation).
  public func frontmostApplicationChanged(_ app: RunningApp?) {
    guard app?.pid != frontmostPid else { return }
    frontmostPid = app?.pid
    presenter.hide(.appSwitched)
  }

  public func activeSpaceChanged() {
    presenter.hide(.spaceChanged)
  }

  // MARK: - Internals

  private func popupVisibilityChanged(_ visible: Bool, reason: HideReason?) {
    router.popupVisible = visible
    // The page is only told about hides it did not ask for. Telling it about its own (it sizes
    // the window away after inserting a suggestion) would reset it, and the popup would never
    // come back for the next argument.
    if !visible, reason != .pageRequested { page?.deliver(.windowHidden) }
  }

  private func settingsChanged(_ values: [String: JSONValue], changed: Set<String>) {
    page?.deliver(.settings(values))
    if changed.contains(SettingKey.disable) || changed.contains(SettingKey.height) {
      presenter.update()
    }
  }

  /// Tells the presenter about the session the popup belongs to.
  private func syncTarget() {
    guard let session = router.currentSession else {
      presenter.target = nil
      return
    }
    let text = session.editBuffer?.text ?? ""
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // Inside tmux the recorded terminal is whichever one started the tmux server, which may not
    // be the one the user is looking at now.
    let terminal = session.hello.insideTmux ? nil : session.hello.terminalBundleId
    presenter.target = PopupTarget(
      hasText: hasText, terminalBundleId: terminal, terminalPid: session.hello.insideTmux ? nil : session.hello.terminalPid,
      cursorCell: session.editBuffer?.cursorCell, grid: session.editBuffer?.grid)
  }

  func appInfo() -> AppInfo {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return AppInfo(
      version: Figo.version, home: NSHomeDirectory(), user: NSUserName(),
      macosVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", settings: settings.values,
      themes: themes.names())
  }
}

extension AppCore: SessionRouterDelegate {
  public func router(_ router: SessionRouter, emit event: PageEvent) {
    page?.deliver(event)
  }

  public func routerCurrentBufferDidChange(_ router: SessionRouter) {
    syncTarget()
    presenter.commandLineChanged()
  }

  public func routerCurrentSessionDidStartCommand(_ router: SessionRouter) {
    syncTarget()
    presenter.hide(.commandStarted)
  }

  public func routerCurrentSessionDidDisconnect(_ router: SessionRouter) {
    syncTarget()
    presenter.hide(.sessionEnded)
  }

  public func routerSessionsDidChange(_ router: SessionRouter) {
    onStatusChange?()
  }
}

extension AppCore: BridgeHandler {
  public func handle(_ request: BridgeRequest) async throws -> JSONValue {
    switch request {
    case .ready:
      log.info("page ready")
      return BridgeReply.appInfo(appInfo())
    case .log(let level, let message):
      pageLog.log(level, message)
      return .null
    case .reportState(let state):
      popupState = state.jsonText(sortedKeys: true)
      return .null
    case .position(let request):
      let result = presenter.position(request)
      log.debug(
        "window.position \(request.width)x\(request.height) anchor \(request.anchorX)\(request.dryRun == true ? " (dry run)" : "")"
          + " → above \(result.isAbove), clipped \(result.isClipped), visible \(presenter.isVisible)")
      return BridgeReply.position(result)
    case .insert(let sessionId, let text, let insertionBuffer):
      try router.insert(sessionId: sessionId, text: text, insertionBuffer: insertionBuffer)
      return .null
    case .setIntercept(let sessionId, let configuration):
      try router.setIntercept(sessionId: sessionId, configuration)
      return .null
    case .runProcess(let sessionId, let request):
      return BridgeReply.process(try await router.runProcess(sessionId: sessionId, request))
    case .listDirectory(let sessionId, let path):
      return BridgeReply.directory(try await router.listDirectory(sessionId: sessionId, path: path))
    case .setSetting(let key, let value):
      let before = settings.values
      try settings.set(key, value)
      // The contract promises a settings event after every set, even one that changed nothing.
      if settings.values == before { page?.deliver(.settings(settings.values)) }
      return .null
    }
  }

  public func pageWillLoad() {
    router.resetAnnouncements()
  }
}
