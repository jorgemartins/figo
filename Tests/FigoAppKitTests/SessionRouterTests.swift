import FigoCore
import Foundation
import Testing

@testable import FigoAppKit

@MainActor
final class RouterDelegateRecorder: SessionRouterDelegate {
  var events: [PageEvent] = []
  var bufferChanges = 0
  var commandStarts = 0
  var disconnects = 0

  func router(_ router: SessionRouter, emit event: PageEvent) { events.append(event) }
  func routerCurrentBufferDidChange(_ router: SessionRouter) { bufferChanges += 1 }
  func routerCurrentSessionDidStartCommand(_ router: SessionRouter) { commandStarts += 1 }
  func routerCurrentSessionDidDisconnect(_ router: SessionRouter) { disconnects += 1 }
  func routerSessionsDidChange(_ router: SessionRouter) {}
}

@MainActor
@Suite struct SessionRouterTests {
  let router = SessionRouter()
  let delegate = RouterDelegateRecorder()
  let a = ChannelRecorder<TerminalCommand>()
  let b = ChannelRecorder<TerminalCommand>()

  init() {
    router.delegate = delegate
    router.fallbackHome = "/Users/test"
    router.connect(hello("A", bundle: "com.mitchellh.ghostty"), channel: a.channel(id: 1))
    router.connect(hello("B", bundle: "com.googlecode.iterm2"), channel: b.channel(id: 2))
  }

  private func hello(_ id: String, bundle: String? = nil) -> TerminalHello {
    TerminalHello(sessionId: id, pid: 100, tty: "/dev/ttys00\(id.count)", terminalBundleId: bundle)
  }

  @Test func currentSessionIsTheLatestToSendANonNilBuffer() {
    #expect(router.currentSessionId == nil)
    router.receive(.editBuffer(editBuffer("git")), from: "A")
    #expect(router.currentSessionId == "A")
    router.receive(.editBuffer(editBuffer("ls")), from: "B")
    #expect(router.currentSessionId == "B")
    // A nil buffer from a session that is not current changes nothing.
    router.receive(.editBuffer(nil), from: "A")
    #expect(router.currentSessionId == "B")
    #expect(delegate.bufferChanges == 2)
    // A blank but non-nil buffer still makes its session current.
    router.receive(.editBuffer(editBuffer("")), from: "A")
    #expect(router.currentSessionId == "A")
  }

  @Test func announcesTheSessionBeforeItsFirstEditBuffer() {
    router.receive(.shell(ShellInfo(shell: "zsh", shellPath: "/bin/zsh", pid: 7, cwd: "/tmp", user: "test")), from: "A")
    router.receive(.environment(variables: ["HOME": "/Users/env", "PATH": "/bin"], aliases: "ll='ls -l'"), from: "A")
    #expect(delegate.events.isEmpty, "sessions are introduced by their first edit buffer")

    router.receive(.editBuffer(editBuffer("git ch", cursor: 6)), from: "A")
    router.receive(.editBuffer(editBuffer("git che", cursor: 7)), from: "A")
    let expected = ShellContext(
      sessionId: "A", shell: "zsh", shellPath: "/bin/zsh", pid: 7, cwd: "/tmp", user: "test", home: "/Users/env",
      env: ["HOME": "/Users/env", "PATH": "/bin"], aliases: "ll='ls -l'", terminal: "com.mitchellh.ghostty")
    #expect(
      delegate.events == [
        .session(expected), .editBuffer(sessionId: "A", buffer: "git ch", cursor: 6),
        .editBuffer(sessionId: "A", buffer: "git che", cursor: 7),
      ])
  }

  @Test func reannouncesWhenTheContextChanges() {
    router.receive(.editBuffer(editBuffer("x")), from: "A")
    delegate.events = []
    router.receive(.shell(ShellInfo(shell: "fish", cwd: "/var")), from: "A")
    router.receive(.shell(ShellInfo(shell: "fish", cwd: "/var")), from: "A")
    guard case .session(let context)? = delegate.events.first else {
      Issue.record("no session event: \(delegate.events)")
      return
    }
    #expect(delegate.events.count == 1, "an unchanged context is not sent again")
    #expect(context.shell == "fish")
    #expect(context.cwd == "/var")
    #expect(context.home == "/Users/test", "falls back to the real home without HOME")

    router.resetAnnouncements()
    delegate.events = []
    router.receive(.editBuffer(editBuffer("xy")), from: "A")
    #expect(delegate.events.map(\.name) == ["session", "editBuffer"])
  }

  @Test func forwardsShellEvents() {
    router.receive(.prompt, from: "A")
    router.receive(.postExec(command: "ls", exitCode: 2), from: "B")
    router.receive(.key(action: "insertSelected"), from: "A")
    #expect(
      delegate.events == [
        .prompt(sessionId: "A"), .postExec(sessionId: "B", command: "ls", exitCode: 2),
        .keybinding(sessionId: "A", action: "insertSelected"),
      ])
  }

  @Test func preExecClearsTheBufferAndStopsTheCurrentSession() {
    router.receive(.editBuffer(editBuffer("make")), from: "A")
    router.receive(.preExec, from: "A")
    #expect(router.currentSession?.editBuffer == nil)
    #expect(delegate.commandStarts == 1)
    router.receive(.preExec, from: "B")
    #expect(delegate.commandStarts == 1, "only the current session hides the popup")
  }

  @Test func nilBufferFromTheCurrentSessionIsForwarded() {
    router.receive(.editBuffer(editBuffer("vim")), from: "A")
    delegate.events = []
    router.receive(.editBuffer(nil), from: "A")
    #expect(delegate.events == [.editBuffer(sessionId: "A", buffer: nil, cursor: 0)])
    #expect(delegate.bufferChanges == 2)
  }

  @Test func interceptGoesToTheNamedSessionAndOffToTheRest() throws {
    let configuration = InterceptConfiguration(
      interceptBound: true, interceptGlobal: true, bindings: ["enter": "insertSelected"])
    try router.setIntercept(sessionId: "A", configuration)
    var hidden = configuration
    hidden.interceptBound = false
    // The popup is not visible yet, so bound keys stay with the shell.
    #expect(a.messages == [.intercept(hidden)])
    #expect(b.messages == [.intercept(.off)])

    router.popupVisible = true
    #expect(a.messages.last == .intercept(configuration))
    #expect(b.messages.count == 1, "unchanged configurations are not re-sent")

    try router.setIntercept(sessionId: "B", configuration)
    #expect(a.messages.last == .intercept(.off))
    #expect(b.messages.last == .intercept(configuration))

    router.popupVisible = false
    #expect(b.messages.last == .intercept(hidden))
    #expect(throws: RouterError.unknownSession("C")) { try router.setIntercept(sessionId: "C", configuration) }
  }

  @Test func insertAndSimulateInputReachTheirSession() throws {
    try router.insert(sessionId: "B", text: "\u{8}checkout ", insertionBuffer: "git ch")
    #expect(b.messages == [.insert(text: "\u{8}checkout ", insertionBuffer: "git ch")])
    #expect(throws: RouterError.noCurrentSession) { try router.simulateInput(sessionId: nil, text: "x") }
    router.receive(.editBuffer(editBuffer("a")), from: "A")
    try router.simulateInput(sessionId: nil, text: "ls\n")
    #expect(a.messages.last == .simulateInput(text: "ls\n"))
  }

  @Test func matchesRepliesToRequests() async throws {
    let request = ProcessRequest(executable: "git", arguments: ["branch"])
    async let result = router.runProcess(sessionId: "A", request)
    #expect(await eventually { a.messages.count == 1 })
    guard case .runProcess(let id, let sent)? = a.messages.first else {
      Issue.record("no runProcess command")
      return
    }
    #expect(sent == request)
    // A reply with the right id from the wrong session, or an unknown id, is ignored.
    router.receive(.reply(id: id, result: .process(ProcessResult(stdout: "wrong", stderr: "", exitCode: 1))), from: "B")
    router.receive(.reply(id: id + 100, result: .failure("nope")), from: "A")
    router.receive(.reply(id: id, result: .process(ProcessResult(stdout: "main\n", stderr: "", exitCode: 0))), from: "A")
    #expect(try await result == ProcessResult(stdout: "main\n", stderr: "", exitCode: 0))
    #expect(router.pendingRequestCount == 0)
  }

  @Test func listsDirectoriesAndSurfacesFailures() async throws {
    async let entries = router.listDirectory(sessionId: "B", path: "~/")
    #expect(await eventually { b.messages.count == 1 })
    guard case .listDirectory(let id, "~/")? = b.messages.first else {
      Issue.record("no listDirectory command")
      return
    }
    let listing = [DirectoryEntry(name: "src", kind: .directory, isSymlink: false)]
    router.receive(.reply(id: id, result: .directory(listing)), from: "B")
    #expect(try await entries == listing)

    let failing = Task { try await router.listDirectory(sessionId: "B", path: "/root") }
    #expect(await eventually { b.messages.count == 2 })
    guard case .listDirectory(let second, _)? = b.messages.last else { return }
    router.receive(.reply(id: second, result: .failure("Permission denied")), from: "B")
    await #expect(throws: RouterError.failed("Permission denied")) { try await failing.value }
  }

  @Test func timesOutWithoutAReply() async {
    router.minimumReplyTimeout = .milliseconds(50)
    let started = ContinuousClock.now
    await #expect(throws: RouterError.timedOut) {
      try await router.runProcess(sessionId: "A", ProcessRequest(executable: "sleep", timeoutMilliseconds: 10))
    }
    #expect(ContinuousClock.now - started >= .milliseconds(50), "waits at least the minimum")
    #expect(router.pendingRequestCount == 0)
  }

  @Test func usesTheLongerOfTheRequestedTimeoutAndTheMinimum() async {
    router.minimumReplyTimeout = .milliseconds(10)
    let started = ContinuousClock.now
    await #expect(throws: RouterError.timedOut) {
      try await router.runProcess(sessionId: "A", ProcessRequest(executable: "sleep", timeoutMilliseconds: 150))
    }
    #expect(ContinuousClock.now - started >= .milliseconds(150))
  }

  @Test func failsPendingRequestsWhenTheSessionDisconnects() async {
    router.receive(.editBuffer(editBuffer("cd ")), from: "A")
    let listing = Task { try await router.listDirectory(sessionId: "A", path: ".") }
    #expect(await eventually { a.messages.count == 1 })
    delegate.events = []
    router.disconnect(sessionId: "A", channelId: 1)
    await #expect(throws: RouterError.disconnected) { try await listing.value }
    #expect(router.sessions["A"] == nil)
    #expect(router.currentSessionId == nil)
    #expect(delegate.disconnects == 1)
    #expect(delegate.events == [.editBuffer(sessionId: "A", buffer: nil, cursor: 0)])
    await #expect(throws: RouterError.unknownSession("A")) {
      try await router.listDirectory(sessionId: "A", path: ".")
    }
  }

  @Test func aReconnectReplacesTheOldConnection() {
    let replacement = ChannelRecorder<TerminalCommand>()
    router.connect(hello("A"), channel: replacement.channel(id: 9))
    #expect(a.isClosed)
    // The old connection closing late must not remove the new one.
    router.disconnect(sessionId: "A", channelId: 1)
    #expect(router.sessions["A"] != nil)
    router.disconnect(sessionId: "A", channelId: 9)
    #expect(router.sessions["A"] == nil)
  }

  @Test func summariesFollowConnectionOrder() {
    router.receive(.editBuffer(editBuffer("x")), from: "B")
    let summaries = router.summaries()
    #expect(summaries.map(\.hello.sessionId) == ["A", "B"])
    #expect(summaries.map(\.isCurrent) == [false, true])
  }
}
