import Foundation

// The messages exchanged over the app's unix socket (`FigoPaths.appSocket`).
//
// The app listens; pty wrappers, the input method helper and the CLI connect. Every frame
// (see `Frame`) is one JSON-encoded message. The first frame a client sends is `ClientHello`,
// which decides the message types used for the rest of the connection:
//
//   role           client → app            app → client
//   terminal       TerminalMessage         TerminalCommand
//   inputMethod    InputMethodMessage      InputMethodCommand
//   cli            CLIRequest              CLIResponse (exactly one per request)

public enum ClientRole: String, Codable, Sendable {
  case terminal
  case inputMethod
  case cli
}

public struct ClientHello: Codable, Equatable, Sendable {
  public var role: ClientRole
  /// `Figo.version` of the client, so mismatched builds can be detected after an update.
  public var version: String
  /// Present when `role` is `terminal`.
  public var terminal: TerminalHello?

  public init(role: ClientRole, version: String = Figo.version, terminal: TerminalHello? = nil) {
    self.role = role
    self.version = version
    self.terminal = terminal
  }
}

// MARK: - Terminal sessions (pty wrapper)

/// What a pty wrapper knows about itself when it connects.
public struct TerminalHello: Codable, Equatable, Sendable {
  /// Stable for the life of the wrapper, including across reconnects to the app.
  public var sessionId: String
  /// Process id of the wrapper.
  public var pid: Int32
  /// The terminal device the wrapper itself is attached to, e.g. `/dev/ttys004`.
  public var tty: String?
  /// `__CFBundleIdentifier` of the app that started the shell, e.g. `com.mitchellh.ghostty`.
  public var terminalBundleId: String?
  /// `TERM_PROGRAM`, e.g. `iTerm.app`, `vscode`, `tmux`.
  public var termProgram: String?
  /// True when the wrapper runs inside a tmux pane.
  public var insideTmux: Bool
  /// Process id of the application the wrapper descends from (the terminal emulator), found by
  /// walking up the process tree. Tells two running copies of the same terminal apart.
  public var terminalPid: Int32?

  public init(
    sessionId: String, pid: Int32, tty: String? = nil, terminalBundleId: String? = nil,
    termProgram: String? = nil, insideTmux: Bool = false, terminalPid: Int32? = nil
  ) {
    self.sessionId = sessionId
    self.pid = pid
    self.tty = tty
    self.terminalBundleId = terminalBundleId
    self.termProgram = termProgram
    self.insideTmux = insideTmux
    self.terminalPid = terminalPid
  }
}

/// What the shell integration has reported about the shell. Fields are nil until reported.
public struct ShellInfo: Codable, Equatable, Sendable {
  /// `zsh`, `bash` or `fish`.
  public var shell: String?
  public var shellPath: String?
  public var pid: Int32?
  public var cwd: String?
  public var user: String?
  /// The terminal device of the shell, i.e. the wrapper's pty slave.
  public var tty: String?

  public init(
    shell: String? = nil, shellPath: String? = nil, pid: Int32? = nil, cwd: String? = nil,
    user: String? = nil, tty: String? = nil
  ) {
    self.shell = shell
    self.shellPath = shellPath
    self.pid = pid
    self.cwd = cwd
    self.user = user
    self.tty = tty
  }
}

public struct GridPosition: Codable, Equatable, Sendable {
  /// Zero-based, from the top-left cell of the terminal's screen.
  public var row: Int
  public var column: Int

  public init(row: Int, column: Int) {
    self.row = row
    self.column = column
  }
}

public struct GridSize: Codable, Equatable, Sendable {
  public var rows: Int
  public var columns: Int
  /// The size of the text area in pixels as the terminal reports it, when it does. Whether
  /// these are points or device pixels differs between terminals.
  public var pixelWidth: Int?
  public var pixelHeight: Int?

  public init(rows: Int, columns: Int, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
    self.rows = rows
    self.columns = columns
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

/// The command line the user is editing.
public struct EditBuffer: Codable, Equatable, Sendable {
  public var text: String
  /// Cursor position in `text`, in UTF-16 code units.
  public var cursor: Int
  /// Where the terminal cursor is on the screen grid, for positioning when nothing better is known.
  public var cursorCell: GridPosition
  public var grid: GridSize
  /// True when this session is where the keyboard is: keys reached it since its prompt was
  /// drawn, or it has only just started. A terminal sends keys to the tab that has the focus, so
  /// this tells the tab being typed in from one whose command finished in the background.
  /// Nil from wrappers that predate it.
  public var typed: Bool?

  public init(text: String, cursor: Int, cursorCell: GridPosition, grid: GridSize, typed: Bool? = nil) {
    self.text = text
    self.cursor = cursor
    self.cursorCell = cursorCell
    self.grid = grid
    self.typed = typed
  }
}

public struct ProcessRequest: Codable, Equatable, Sendable {
  /// Looked up in the shell's `PATH` unless it contains a slash.
  public var executable: String
  public var arguments: [String]
  /// Defaults to the shell's working directory; also used when this directory does not exist.
  public var workingDirectory: String?
  /// Applied on top of the shell's environment. A nil value removes the variable.
  public var environment: [String: String?]
  /// Defaults to 60 seconds.
  public var timeoutMilliseconds: Int?

  public init(
    executable: String, arguments: [String] = [], workingDirectory: String? = nil,
    environment: [String: String?] = [:], timeoutMilliseconds: Int? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.timeoutMilliseconds = timeoutMilliseconds
  }
}

public struct ProcessResult: Codable, Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  /// The exit status, or 128 + signal number when the process was killed by a signal.
  public var exitCode: Int32

  public init(stdout: String, stderr: String, exitCode: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public struct DirectoryEntry: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case file
    case directory
    /// Sockets, devices and dangling symbolic links.
    case other
  }

  public var name: String
  /// For symbolic links this describes the target.
  public var kind: Kind
  public var isSymlink: Bool

  public init(name: String, kind: Kind, isSymlink: Bool) {
    self.name = name
    self.kind = kind
    self.isSymlink = isSymlink
  }
}

/// The outcome of a `TerminalCommand` that carries an `id`.
public enum TerminalReply: Codable, Equatable, Sendable {
  case process(ProcessResult)
  case directory([DirectoryEntry])
  case failure(String)
}

/// Which keys the wrapper takes away from the shell and reports instead.
public struct InterceptConfiguration: Codable, Equatable, Sendable {
  /// Swallow every key in `bindings` (the popup is visible with suggestions).
  public var interceptBound: Bool
  /// The popup is hidden but could be shown: swallow only keys bound to `showAutocomplete`
  /// or `toggleAutocomplete`.
  public var interceptGlobal: Bool
  /// Key (`enter`, `shift+tab`, `control+k`, …) to action id. The action `ignore` unbinds.
  public var bindings: [String: String]

  public init(interceptBound: Bool = false, interceptGlobal: Bool = false, bindings: [String: String] = [:]) {
    self.interceptBound = interceptBound
    self.interceptGlobal = interceptGlobal
    self.bindings = bindings
  }

  /// Nothing is intercepted.
  public static let off = InterceptConfiguration()
}

/// Wrapper → app.
public enum TerminalMessage: Codable, Equatable, Sendable {
  /// Sent whenever something in it changed, and always before the first `editBuffer`.
  case shell(ShellInfo)
  /// The shell's exported environment and the raw output of its `alias` builtin. Sent when
  /// either changed since the last prompt.
  case environment(variables: [String: String], aliases: String)
  /// A fresh prompt was drawn.
  case prompt
  /// A command started running. No edit buffers follow until the next `prompt`.
  case preExec
  /// The command submitted at the last `preExec` finished.
  case postExec(command: String, exitCode: Int32)
  /// The command line changed. Nil means there is nothing to complete right now (a full-screen
  /// program took over, the line scrolled away, …).
  case editBuffer(EditBuffer?)
  /// A bound key was pressed and swallowed; `action` is what it is bound to.
  case key(action: String)
  case reply(id: UInt64, result: TerminalReply)
}

/// App → wrapper.
public enum TerminalCommand: Codable, Equatable, Sendable {
  case intercept(InterceptConfiguration)
  /// Types into the shell. `text` may contain 0x08 (delete backwards), `ESC [ D` / `ESC [ C`
  /// and `\n`. `insertionBuffer` is the command line the insertion was computed against.
  case insert(text: String, insertionBuffer: String?)
  /// Answered with `TerminalMessage.reply(id:result:)` carrying `.process` or `.failure`.
  case runProcess(id: UInt64, request: ProcessRequest)
  /// Lists a directory; `path` may start with `~` or be relative to the shell's working
  /// directory. Answered with `.directory` or `.failure`.
  case listDirectory(id: UInt64, path: String)
  /// Feeds `text` through the wrapper's input path exactly as if it had been typed in the
  /// terminal, key interception included. For automated tests and `figo debug type`.
  case simulateInput(text: String)
}

// MARK: - Input method helper

/// A rectangle in Cocoa screen coordinates: points, origin at the bottom-left of the primary display.
public struct ScreenRect: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// Input method helper → app.
public enum InputMethodMessage: Codable, Equatable, Sendable {
  /// A text input client gained (`active: true`) or lost keyboard focus.
  case focus(bundleId: String?, pid: Int32?, active: Bool)
  /// Answer to `InputMethodCommand.queryCaret`. `rect` is nil when no client is active or the
  /// client did not report a usable rectangle.
  case caret(id: UInt64, rect: ScreenRect?, bundleId: String?)
}

/// App → input method helper.
public enum InputMethodCommand: Codable, Equatable, Sendable {
  /// Ask the focused text input client where its insertion point is.
  case queryCaret(id: UInt64)
}

// MARK: - CLI

public struct SessionSummary: Codable, Equatable, Sendable {
  public var hello: TerminalHello
  public var shell: ShellInfo
  public var editBuffer: EditBuffer?
  /// True for the session the popup currently belongs to.
  public var isCurrent: Bool

  public init(hello: TerminalHello, shell: ShellInfo, editBuffer: EditBuffer?, isCurrent: Bool) {
    self.hello = hello
    self.shell = shell
    self.editBuffer = editBuffer
    self.isCurrent = isCurrent
  }
}

/// A snapshot of the app's state, for `figo doctor` and for automated tests.
public struct AppStatus: Codable, Equatable, Sendable {
  public var version: String
  public var pid: Int32
  public var sessions: [SessionSummary]
  public var inputMethodConnected: Bool
  /// Bundle id of the app the input method last reported as having keyboard focus.
  public var focusedBundleId: String?
  /// The last caret rectangle used for positioning, if any.
  public var caret: ScreenRect?
  public var popupVisible: Bool
  /// The popup window's frame, in the same coordinates as `ScreenRect`.
  public var popupFrame: ScreenRect?
  /// Free-form JSON describing what the popup is showing, as reported by the web page.
  public var popupState: String?

  public init(
    version: String, pid: Int32, sessions: [SessionSummary], inputMethodConnected: Bool,
    focusedBundleId: String?, caret: ScreenRect?, popupVisible: Bool, popupFrame: ScreenRect?,
    popupState: String?
  ) {
    self.version = version
    self.pid = pid
    self.sessions = sessions
    self.inputMethodConnected = inputMethodConnected
    self.focusedBundleId = focusedBundleId
    self.caret = caret
    self.popupVisible = popupVisible
    self.popupFrame = popupFrame
    self.popupState = popupState
  }
}

/// CLI → app.
public enum CLIRequest: Codable, Equatable, Sendable {
  case status
  case quit
  /// Bring up the settings window.
  case openSettings
  /// Send `TerminalCommand.simulateInput` to a session (the current one when nil).
  case simulateInput(sessionId: String?, text: String)
}

/// App → CLI.
public enum CLIResponse: Codable, Equatable, Sendable {
  case ok
  case status(AppStatus)
  case failure(String)
}
