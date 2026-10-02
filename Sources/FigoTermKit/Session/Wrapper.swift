import CFigoPTY
import Darwin
import FigoCore
import Foundation

/// How to start the shell the wrapper hosts.
public struct WrapperConfiguration: Sendable {
  /// Absolute path of the shell binary.
  public var shellPath: String
  /// The shell's argument vector, including argv[0].
  public var arguments: [String]
  public var environment: [String: String]
  public var sessionId: String
  public var socketPath: String

  public init(shellPath: String, arguments: [String], environment: [String: String], sessionId: String, socketPath: String) {
    self.shellPath = shellPath
    self.arguments = arguments
    self.environment = environment
    self.sessionId = sessionId
    self.socketPath = socketPath
  }
}

/// The pty wrapper: runs the shell in a pseudo-terminal, passes everything through, and tells
/// the app what the user is typing.
///
/// One thread does all the work in a single loop so that the order of bytes is never in doubt.
/// The priorities, in order: never lose or reorder terminal data, never stall the user's typing,
/// and only then keep the app informed.
public final class Wrapper {
  public enum StartError: Error {
    case notATerminal
    case spawnFailed(Int32)
  }

  /// How long a lone ESC is held back before it is taken to be the Escape key rather than the
  /// start of a sequence the terminal is still sending.
  private static let escapeTimeout: UInt64 = 10_000_000
  /// After typing an insertion the shell echoes it piece by piece; the popup should only see
  /// the result.
  private static let insertionSettleTime: UInt64 = 16_000_000
  /// A keystroke makes the shell write several times in quick succession (zsh reports the
  /// line, then redraws it). Waiting this long after the first write lets the app see one
  /// consistent update instead of each intermediate state.
  private static let publishDelay: UInt64 = 2_000_000
  /// Minimum time between attempts to reach an app that is not running. Attempts are only made
  /// when something happens in the terminal, so an idle tab never wakes up for this.
  private static let reconnectInterval: UInt64 = 2_000_000_000
  /// Stop reading from one side when this much is waiting to be written to the other.
  private static let maxQueuedInput = 1024 * 1024

  private let configuration: WrapperConfiguration
  private let master: Int32
  private let child: pid_t
  private let signalPipe: Int32
  private var originalTermios: termios

  private let session: ShellSession
  private var filter = OutputFilter()
  private var keyParser = KeyParser()
  private var interceptor = Interceptor()
  private let app = AppConnection()
  private let hello: ClientHello

  /// Bytes on their way to the shell. The pty is written without blocking so that a program
  /// that is not reading its input can never stall output.
  private var inputQueue: [UInt8] = []
  private var inputOpen = true
  private var childStatus: Int32?

  private var escapeDeadline: UInt64?
  /// Whether keys have arrived since the last command finished; see `EditBuffer.typed`.
  private var keysSincePrompt = false
  private var inputEvidence = InputEvidence.Tracker()
  private var hasPublishedBuffer = false
  private var lastPublishedTyped = false
  private var insertionDeadline: UInt64?
  private var publishDeadline: UInt64?
  private var nextConnectAttempt: UInt64 = 0
  /// The edit buffer the app was last told about; `.some(nil)` means "told there is none".
  private var lastPublished: EditBuffer??

  /// When `FIGO_TERM_TRACE` names a file, everything the shell writes is appended to it
  /// unfiltered, for diagnosing what a shell or prompt theme actually emits.
  private var trace: Int32 = -1

  // Results of helper processes arrive from background threads.
  private let completedLock = NSLock()
  private var completed: [(id: UInt64, reply: TerminalReply)] = []
  private var wakePipe: [Int32] = [-1, -1]

  /// Starts the shell and puts the terminal in raw mode. Throws before anything irreversible
  /// has happened if the shell cannot be started, so the caller can fall back to exec'ing it.
  public init(configuration: WrapperConfiguration) throws {
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { throw StartError.notATerminal }
    self.configuration = configuration

    var size = winsize()
    _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
    if size.ws_row == 0 || size.ws_col == 0 {
      size.ws_row = 24
      size.ws_col = 80
    }
    var attributes = termios()
    tcgetattr(STDIN_FILENO, &attributes)
    originalTermios = attributes

    var argv: [UnsafeMutablePointer<CChar>?] = configuration.arguments.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = configuration.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv + envp { free(pointer) }
    }

    var masterDescriptor: Int32 = -1
    // The new terminal starts with the outer terminal's settings, as if the shell had been
    // started there directly.
    let pid = figo_pty_spawn(&masterDescriptor, configuration.shellPath, &argv, &envp, &attributes, &size)
    guard pid > 0 else { throw StartError.spawnFailed(errno) }
    master = masterDescriptor
    child = pid
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    _ = fcntl(master, F_SETFD, FD_CLOEXEC)

    session = ShellSession(sessionId: configuration.sessionId, columns: Int(size.ws_col), rows: Int(size.ws_row))
    session.pixelSize = Self.pixelSize(size)

    let environment = configuration.environment
    hello = ClientHello(
      role: .terminal,
      terminal: TerminalHello(
        sessionId: configuration.sessionId, pid: getpid(), tty: ttyname(STDIN_FILENO).map { String(cString: $0) },
        terminalBundleId: environment["__CFBundleIdentifier"], termProgram: environment["TERM_PROGRAM"],
        insideTmux: environment["TMUX"] != nil, terminalPid: Self.topLevelAncestor()))

    if let path = environment["FIGO_TERM_TRACE"], !path.isEmpty {
      trace = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    }

    signal(SIGPIPE, SIG_IGN)
    signalPipe = figo_signal_pipe()
    _ = pipe(&wakePipe)
    for descriptor in wakePipe {
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    // Raw mode: every key goes to the shell's own terminal untouched. Input typed while the
    // shell was starting stays queued (no flush) and is forwarded like any other.
    var raw = attributes
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSADRAIN, &raw)

    figo_lifeboat_arm(master, child, &originalTermios)
  }

  /// Runs until the shell exits, then exits the process with the shell's status.
  public func run() -> Never {
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
    var output: [UInt8] = []
    output.reserveCapacity(buffer.count)

    connectIfNeeded(now: Self.now())

    while childStatus == nil {
      let now = Self.now()
      runTimers(now: now)

      var readDescriptors: [Int32] = [master, signalPipe, wakePipe[0]]
      if inputOpen && inputQueue.count < Self.maxQueuedInput { readDescriptors.append(STDIN_FILENO) }
      if app.isConnected { readDescriptors.append(app.descriptor) }
      var writeDescriptors: [Int32] = []
      if !inputQueue.isEmpty { writeDescriptors.append(master) }
      if app.wantsWrite { writeDescriptors.append(app.descriptor) }

      var readable: UInt32 = 0
      var writable: UInt32 = 0
      let result = figo_wait(
        readDescriptors, Int32(readDescriptors.count), writeDescriptors, Int32(writeDescriptors.count),
        timeout(now: now), &readable, &writable)
      if result < 0 && errno != EINTR { break }
      if result <= 0 { continue }

      func isReadable(_ descriptor: Int32) -> Bool {
        readDescriptors.firstIndex(of: descriptor).map { readable & (1 << UInt32($0)) != 0 } ?? false
      }
      func isWritable(_ descriptor: Int32) -> Bool {
        writeDescriptors.firstIndex(of: descriptor).map { writable & (1 << UInt32($0)) != 0 } ?? false
      }

      // Shell output first: it is what the user is waiting to see.
      if isReadable(master) {
        let count = read(master, buffer.baseAddress, buffer.count)
        if count > 0 {
          let bytes = UnsafeBufferPointer(rebasing: buffer.bindMemory(to: UInt8.self)[..<count])
          if trace >= 0 { _ = write(trace, bytes.baseAddress, bytes.count) }
          output.removeAll(keepingCapacity: true)
          filter.filter(bytes, into: &output)
          Self.writeAll(STDOUT_FILENO, output)
          handle(session.feed(bytes))
          if publishDeadline == nil { publishDeadline = Self.now() + Self.publishDelay }
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
          break
        }
      }

      if isReadable(STDIN_FILENO) {
        let count = read(STDIN_FILENO, buffer.baseAddress, buffer.count)
        if count > 0 {
          handleInput(Array(buffer.bindMemory(to: UInt8.self)[..<count]))
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
          inputOpen = false
        }
      }

      if isWritable(master) || !inputQueue.isEmpty { flushInput() }

      if isReadable(signalPipe) { handleSignals() }
      if isReadable(wakePipe[0]) { deliverCompleted() }

      if app.isConnected {
        if isWritable(app.descriptor) { app.flush() }
        if isReadable(app.descriptor) {
          if let commands = app.receive() {
            for command in commands { handle(command) }
          } else {
            appDisconnected()
          }
        }
      }
    }

    finish()
  }

  // MARK: - Shell output

  private func handle(_ events: [ShellEvent]) {
    for event in events {
      switch event {
      case .infoChanged:
        app.send(.shell(session.info))
      case .environmentChanged:
        app.send(.environment(variables: session.environment, aliases: session.aliases))
      case .prompt:
        // A prompt is when a newly started app is most useful to reach.
        connectIfNeeded(now: Self.now())
        app.send(.prompt)
      case .preExec:
        interceptor.reset()
        flushPendingKeys()
        keyParser.endPaste()
        insertionDeadline = nil
        publishDeadline = nil
        app.send(.preExec)
        lastPublished = .some(nil)
      case .postExec(let command, let exitCode):
        // Keys typed while the command ran are in the next command line, but they do not say
        // that this tab still has the focus now that it has finished. (Not on every prompt:
        // themes and Ctrl-L redraw the prompt in the middle of a line.)
        keysSincePrompt = false
        app.send(.postExec(command: command, exitCode: exitCode))
      }
    }
  }

  /// Tells the app about the command line if it changed since the last time.
  private func publishEditBuffer() {
    guard app.isConnected, insertionDeadline == nil else { return }
    let current = session.editBuffer()
    let typed = keysSincePrompt || !hasPublishedBuffer
    // The same command line is sent again only to say that it is now being typed in.
    if case .some(let published) = lastPublished, published == current, current == nil || lastPublishedTyped || !typed {
      return
    }
    // Before the first prompt there is nothing to retract.
    if current == nil && lastPublished == nil { return }
    lastPublished = .some(current)
    var outgoing = current
    outgoing?.typed = typed
    if current != nil {
      hasPublishedBuffer = true
      lastPublishedTyped = typed
    }
    app.send(.editBuffer(outgoing))
  }

  // MARK: - Keyboard input

  private func handleInput(_ bytes: [UInt8]) {
    connectIfNeeded(now: Self.now())
    switch inputEvidence.observe(bytes) {
    case .typing, .focusGained:
      if !keysSincePrompt {
        keysSincePrompt = true
        // The command line may not change (coming back to a tab with text already on it), but
        // whose turn it is has: say so.
        if publishDeadline == nil { publishDeadline = Self.now() + Self.publishDelay }
      }
    case .focusLost: keysSincePrompt = false
    case .nothing: break
    }
    guard interceptor.isActive, !session.isExecuting else {
      // Nothing can be intercepted, so the bytes are not parsed; they are only watched for a
      // paste starting, which may still be arriving when interception begins.
      flushPendingKeys()
      keyParser.observe(bytes)
      inputQueue.append(contentsOf: bytes)
      return
    }
    route(keyParser.parse(bytes, flush: false))
    escapeDeadline = keyParser.hasPending ? Self.now() + Self.escapeTimeout : nil
  }

  private func flushPendingKeys() {
    guard keyParser.hasPending else { return }
    route(keyParser.parse([], flush: true))
    escapeDeadline = nil
  }

  private func route(_ tokens: [InputToken]) {
    for token in tokens {
      if let key = token.key, let action = interceptor.action(for: key), app.isConnected {
        app.send(.key(action: action))
      } else {
        inputQueue.append(contentsOf: token.bytes)
      }
    }
  }

  private func flushInput() {
    while !inputQueue.isEmpty {
      let written = inputQueue.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
      if written > 0 {
        inputQueue.removeFirst(written)
      } else if written < 0 && errno == EINTR {
        continue
      } else {
        // EAGAIN: the shell is not reading; try again when the pty has room.
        return
      }
    }
  }

  // MARK: - App

  private func connectIfNeeded(now: UInt64) {
    guard !app.isConnected, now >= nextConnectAttempt else { return }
    nextConnectAttempt = now + Self.reconnectInterval
    guard app.connect(path: configuration.socketPath, hello: hello) else { return }

    // A freshly connected app knows nothing about this session yet.
    if session.info != ShellInfo() { app.send(.shell(session.info)) }
    if !session.environment.isEmpty || !session.aliases.isEmpty {
      app.send(.environment(variables: session.environment, aliases: session.aliases))
    }
    lastPublished = nil
    publishEditBuffer()
  }

  private func appDisconnected() {
    // With nobody to hand keys to, every key belongs to the shell again.
    interceptor.reset()
    flushPendingKeys()
    insertionDeadline = nil
    nextConnectAttempt = Self.now() + Self.reconnectInterval
  }

  private func handle(_ command: TerminalCommand) {
    switch command {
    case .intercept(let configuration):
      interceptor.apply(configuration)
      if !interceptor.isActive { flushPendingKeys() }

    case .insert(let text, let insertionBuffer):
      guard !session.isExecuting else { return }
      flushPendingKeys()
      inputQueue.append(
        contentsOf: InsertionPlan.bytes(
          text: text, insertionBuffer: insertionBuffer, currentBuffer: session.editBuffer()?.text))
      insertionDeadline = Self.now() + Self.insertionSettleTime

    case .runProcess(let id, let request):
      let environment = session.environment.isEmpty ? configuration.environment : session.environment
      let directory = session.info.cwd
      runInBackground(id: id) {
        HelperProcess.run(request, shellEnvironment: environment, shellDirectory: directory)
      }

    case .listDirectory(let id, let path):
      let home = session.environment["HOME"] ?? configuration.environment["HOME"]
      let directory = session.info.cwd
      runInBackground(id: id) {
        HelperProcess.list(path, shellDirectory: directory, home: home)
      }

    case .simulateInput(let text):
      // A testing tool for the command line; never a way to type into a running program.
      guard !session.isExecuting else { return }
      handleInput(Array(text.utf8))
    }
  }

  private func runInBackground(id: UInt64, _ work: @escaping @Sendable () -> TerminalReply) {
    let wake = wakePipe[1]
    Thread.detachNewThread { [weak self] in
      let reply = work()
      guard let self else { return }
      self.completedLock.lock()
      self.completed.append((id, reply))
      self.completedLock.unlock()
      var byte: UInt8 = 1
      _ = write(wake, &byte, 1)
    }
  }

  private func deliverCompleted() {
    var drain = [UInt8](repeating: 0, count: 64)
    while read(wakePipe[0], &drain, drain.count) > 0 {}

    completedLock.lock()
    let ready = completed
    completed.removeAll()
    completedLock.unlock()
    for item in ready {
      app.send(.reply(id: item.id, result: item.reply))
    }
  }

  // MARK: - Signals and timers

  private func handleSignals() {
    var signals = [UInt8](repeating: 0, count: 64)
    let count = read(signalPipe, &signals, signals.count)
    guard count > 0 else { return }

    if signals[..<count].contains(UInt8(SIGWINCH)) {
      var size = winsize()
      if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 {
        _ = ioctl(master, TIOCSWINSZ, &size)
        session.pixelSize = Self.pixelSize(size)
        session.resize(columns: Int(size.ws_col), rows: Int(size.ws_row))
        publishEditBuffer()
      }
    }
    if signals[..<count].contains(UInt8(SIGCHLD)) {
      var status: Int32 = 0
      if waitpid(child, &status, WNOHANG) == child {
        childStatus = status
      }
    }
  }

  private func timeout(now: UInt64) -> Int32 {
    var deadline: UInt64?
    for candidate in [escapeDeadline, insertionDeadline, publishDeadline] {
      if let candidate { deadline = min(deadline ?? candidate, candidate) }
    }
    guard let deadline else { return -1 }
    return deadline <= now ? 0 : Int32(min((deadline - now) / 1_000_000 + 1, 60_000))
  }

  private func runTimers(now: UInt64) {
    if let deadline = escapeDeadline, now >= deadline {
      flushPendingKeys()
    }
    if let deadline = insertionDeadline, now >= deadline {
      insertionDeadline = nil
      publishEditBuffer()
    }
    if let deadline = publishDeadline, now >= deadline {
      publishDeadline = nil
      publishEditBuffer()
    }
  }

  // MARK: - Exit

  private func finish() -> Never {
    // Show whatever the shell printed on its way out.
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 16 * 1024, alignment: 1)
    var output: [UInt8] = []
    while true {
      let count = read(master, buffer.baseAddress, buffer.count)
      guard count > 0 else { break }
      output.removeAll(keepingCapacity: true)
      filter.filter(UnsafeBufferPointer(rebasing: buffer.bindMemory(to: UInt8.self)[..<count]), into: &output)
      Self.writeAll(STDOUT_FILENO, output)
    }

    tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
    app.disconnect()

    var status = childStatus ?? 0
    if childStatus == nil {
      // The pty closed before the exit was reported; give the shell a moment to be reaped.
      for _ in 0..<50 {
        if waitpid(child, &status, WNOHANG) == child { break }
        usleep(10_000)
      }
    }
    exit(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
  }

  // MARK: - Helpers

  /// The process this one descends from that was started by launchd: for a shell in a terminal
  /// window that is the terminal application itself (terminal → login → shell).
  private static func topLevelAncestor() -> Int32? {
    var pid = getppid()
    for _ in 0..<32 {
      // sysctl rather than proc_pidinfo: the chain passes through login(1), which runs as
      // root, and only sysctl describes another user's process.
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.size
      var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
      let parent = info.kp_eproc.e_ppid
      if parent <= 1 { return pid }
      pid = parent
    }
    return nil
  }

  private static func pixelSize(_ size: winsize) -> (width: Int, height: Int)? {
    size.ws_xpixel > 0 && size.ws_ypixel > 0 ? (Int(size.ws_xpixel), Int(size.ws_ypixel)) : nil
  }

  private static func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0 && (errno == EINTR || errno == EAGAIN) {
          continue
        } else {
          return
        }
      }
    }
  }
}
