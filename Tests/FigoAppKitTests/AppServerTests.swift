import FigoCore
import Foundation
import Testing

@testable import FigoAppKit

/// Drives the app's real socket server with fake clients speaking the real `FigoCore` frames.
@MainActor
@Suite(.serialized) final class AppServerTests {
  let directory: URL
  let window = FakeWindow()
  let desktop = FakeDesktop()
  let page = PageRecorder()
  let core: AppCore

  init() throws {
    directory = try makeTemporaryDirectory("server")
    let settings = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    core = AppCore(settings: settings, window: window, desktop: desktop, themes: ThemeCatalog(bundled: nil, user: directory))
    core.page = page
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  private func startServer(at path: String? = nil) throws -> AppServer {
    let server = AppServer(path: path ?? directory.appendingPathComponent("figo.sock").path)
    try server.start(core: core)
    return server
  }

  private func fetchStatus(via cli: TestClient) async throws -> AppStatus {
    try cli.send(CLIRequest.status)
    guard case .status(let status) = try await cli.receive(CLIResponse.self) else {
      throw TestClientError(description: "expected a status")
    }
    return status
  }

  @Test func terminalAndInputMethodSessionEndToEnd() async throws {
    let server = try startServer()
    defer { server.stop() }

    let inputMethod = try TestClient(path: server.path, hello: ClientHello(role: .inputMethod))
    defer { inputMethod.disconnect() }
    let caret = ScreenRect(x: 300, y: 586, width: 1, height: 14)
    try inputMethod.send(InputMethodMessage.focus(bundleId: "com.mitchellh.ghostty", pid: 42, active: true))
    inputMethod.answerCaretQueries(with: caret, bundleId: "com.mitchellh.ghostty")
    #expect(await eventually { core.inputMethod.focusedBundleId == "com.mitchellh.ghostty" })

    let hello = TerminalHello(
      sessionId: "session-1", pid: 4242, tty: "/dev/ttys009", terminalBundleId: "com.mitchellh.ghostty",
      termProgram: "ghostty")
    let terminal = try TestClient(path: server.path, hello: ClientHello(role: .terminal, terminal: hello))
    try terminal.send(TerminalMessage.shell(ShellInfo(shell: "zsh", pid: 4243, cwd: "/tmp")))
    try terminal.send(TerminalMessage.editBuffer(editBuffer("git ch")))
    #expect(await eventually { core.presenter.caret != nil })

    let cli = try TestClient(path: server.path, hello: ClientHello(role: .cli))
    let status = try await fetchStatus(via: cli)
    #expect(status.version == Figo.version)
    #expect(status.pid == getpid())
    #expect(status.sessions.map(\.hello) == [hello])
    #expect(status.sessions.first?.isCurrent == true)
    #expect(status.sessions.first?.editBuffer?.text == "git ch")
    #expect(status.sessions.first?.shell.shell == "zsh")
    #expect(status.inputMethodConnected)
    #expect(status.focusedBundleId == "com.mitchellh.ghostty")
    #expect(status.caret == caret)
    #expect(!status.popupVisible)
    #expect(page.names == ["session", "editBuffer"])

    // The page sizes the popup: it appears below the caret.
    _ = try await core.handle(.position(PositionRequest(width: 320, height: 140, anchorX: 0, offsetFromBaseline: -3)))
    #expect(window.isVisible)
    let visible = try await fetchStatus(via: cli)
    #expect(visible.popupVisible)
    #expect(visible.popupFrame == ScreenRect(x: 300, y: 900 - 316 - 140, width: 320, height: 140))

    // Intercepts reach the wrapper.
    let intercept = InterceptConfiguration(interceptBound: true, interceptGlobal: true, bindings: ["tab": "insertCommonPrefix"])
    _ = try await core.handle(.setIntercept(sessionId: "session-1", intercept))
    #expect(try await terminal.receive(TerminalCommand.self) == .intercept(intercept))

    // A generator runs through the wrapper and its reply comes back to the page.
    async let output = core.handle(
      .runProcess(sessionId: "session-1", ProcessRequest(executable: "git", arguments: ["branch"])))
    guard case .runProcess(let id, let request) = try await terminal.receive(TerminalCommand.self) else {
      Issue.record("expected runProcess")
      return
    }
    #expect(request.arguments == ["branch"])
    try terminal.send(
      TerminalMessage.reply(id: id, result: .process(ProcessResult(stdout: "main\n", stderr: "", exitCode: 0))))
    #expect(try await output == BridgeReply.process(ProcessResult(stdout: "main\n", stderr: "", exitCode: 0)))

    // Text typed by the page and by the CLI.
    _ = try await core.handle(.insert(sessionId: "session-1", text: "eckout ", insertionBuffer: "git ch"))
    #expect(try await terminal.receive(TerminalCommand.self) == .insert(text: "eckout ", insertionBuffer: "git ch"))
    try cli.send(CLIRequest.simulateInput(sessionId: nil, text: "ls\n"))
    #expect(try await cli.receive(CLIResponse.self) == .ok)
    #expect(try await terminal.receive(TerminalCommand.self) == .simulateInput(text: "ls\n"))

    // Running a command hides the popup and stops intercepting bound keys.
    try terminal.send(TerminalMessage.preExec)
    #expect(await eventually { !window.isVisible })
    #expect(page.names.contains("windowHidden"))
    var hidden = intercept
    hidden.interceptBound = false
    #expect(try await terminal.receive(TerminalCommand.self) == .intercept(hidden))

    // The wrapper going away removes the session.
    terminal.disconnect()
    #expect(await eventually { core.router.sessions.isEmpty })
    #expect(try await fetchStatus(via: cli).sessions.isEmpty)
    try cli.send(CLIRequest.simulateInput(sessionId: "session-1", text: "x"))
    guard case .failure = try await cli.receive(CLIResponse.self) else {
      Issue.record("simulateInput to a gone session should fail")
      return
    }

    // And so does the input method.
    inputMethod.disconnect()
    #expect(await eventually { !core.inputMethod.isConnected })
  }

  @Test func focusMovingToAnotherClientHidesThePopup() async throws {
    let server = try startServer()
    defer { server.stop() }
    let inputMethod = try TestClient(path: server.path, hello: ClientHello(role: .inputMethod))
    defer { inputMethod.disconnect() }
    try inputMethod.send(InputMethodMessage.focus(bundleId: "com.mitchellh.ghostty", pid: 42, active: true))
    inputMethod.answerCaretQueries(with: ScreenRect(x: 100, y: 500, width: 1, height: 14), bundleId: "com.mitchellh.ghostty")

    let hello = TerminalHello(sessionId: "s", pid: 1, terminalBundleId: "com.mitchellh.ghostty")
    let terminal = try TestClient(path: server.path, hello: ClientHello(role: .terminal, terminal: hello))
    try terminal.send(TerminalMessage.editBuffer(editBuffer("npm ")))
    #expect(await eventually { core.presenter.caret != nil })
    _ = try await core.handle(.position(PositionRequest(width: 300, height: 100)))
    #expect(window.isVisible)

    // Another tab of the same terminal: deactivate, then activate.
    try inputMethod.send(InputMethodMessage.focus(bundleId: "com.mitchellh.ghostty", pid: 42, active: false))
    try inputMethod.send(InputMethodMessage.focus(bundleId: "com.mitchellh.ghostty", pid: 42, active: true))
    #expect(await eventually { !window.isVisible })
  }

  @Test func closesClientsThatDoNotStartWithAHello() async throws {
    let server = try startServer()
    defer { server.stop() }
    let client = try TestClient(path: server.path, hello: ClientHello(role: .cli))
    // Speak garbage on a fresh connection instead of a hello.
    let rude = try UnixSocket.connect(to: server.path)
    defer { close(rude) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(rude, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let frame = Frame.encode(Data(#"{"nonsense":true}"#.utf8))
    _ = frame.withUnsafeBytes { write(rude, $0.baseAddress, $0.count) }
    var byte: UInt8 = 0
    #expect(read(rude, &byte, 1) == 0, "the server hangs up")
    // Other clients are unaffected.
    #expect(try await fetchStatus(via: client).sessions.isEmpty)
  }

  @Test func worksWithSocketPathsLongerThanSunPath() async throws {
    let deep = directory.appendingPathComponent(String(repeating: "d", count: 90), isDirectory: true)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    let path = deep.appendingPathComponent("figo.sock").path
    #expect(path.utf8.count > 104)
    let server = try startServer(at: path)
    defer { server.stop() }
    let cli = try TestClient(path: path, hello: ClientHello(role: .cli))
    #expect(try await fetchStatus(via: cli).version == Figo.version)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
  }

  @Test func quitRepliesBeforeQuitting() async throws {
    let server = try startServer()
    defer { server.stop() }
    var quit = false
    core.onQuit = { quit = true }
    let cli = try TestClient(path: server.path, hello: ClientHello(role: .cli))
    try cli.send(CLIRequest.quit)
    #expect(try await cli.receive(CLIResponse.self) == .ok)
    #expect(await eventually { quit })
  }
}
