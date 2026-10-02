import FigoCore

/// Things the shell did that the rest of the wrapper reacts to.
public enum ShellEvent: Equatable, Sendable {
  /// A prompt was drawn; the user can type. May repeat when the shell redraws its prompt.
  case prompt
  /// A command started running.
  case preExec
  /// The command submitted at the last `preExec` finished.
  case postExec(command: String, exitCode: Int32)
  /// Something in `ShellSession.info` changed.
  case infoChanged
  /// The exported environment or the aliases changed.
  case environmentChanged
}

/// Follows what the shell is doing by reading the private escape sequences its integration
/// script emits, and derives the command line being edited.
///
/// Every sequence has the form `ESC ] 6977 ; <session id> ; <payload> BEL`. Carrying the session
/// id means sequences from anything but this session's own shell integration (the output of a
/// remote shell over ssh, a replayed recording) are ignored without further bookkeeping.
public final class ShellSession: TerminalDelegate {
  /// The number of our private operating system command.
  public static let oscNumber = "6977"

  public let sessionId: String
  public let terminal: Terminal

  public private(set) var info = ShellInfo()
  public private(set) var environment: [String: String] = [:]
  public private(set) var aliases = ""

  /// True from the moment a command starts until the next prompt. Starts true: nothing can be
  /// edited before the first prompt.
  public private(set) var isExecuting = true
  public private(set) var hasSeenPrompt = false

  /// How the shell draws its own autosuggestion, used to leave ghost text out of the buffer.
  public private(set) var suggestionStyle = SuggestionStyle()

  /// The text area's size in pixels as reported by the outer terminal, or nil when it reports none.
  public var pixelSize: (width: Int, height: Int)?

  /// The command line as reported by the shell itself (zsh), which is exact. Nil when the shell
  /// cannot report it, in which case it is read off the screen.
  private var reported: (text: String, cursor: Int)?
  private var pendingEnvironment: [String: String]?
  private var pendingCommand: String?
  private var pendingExitCode: Int32?
  /// Set between a window resize and the next prompt draw, while the anchor may be stale.
  private var anchorIsStale = false
  private var events: [ShellEvent] = []

  public init(sessionId: String, columns: Int, rows: Int) {
    self.sessionId = sessionId
    terminal = Terminal(columns: columns, rows: rows)
    terminal.delegate = self
  }

  /// Feeds shell output through the terminal model and returns what happened, in order.
  public func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [ShellEvent] {
    events.removeAll(keepingCapacity: true)
    terminal.feed(bytes)
    return events
  }

  public func feed(_ text: String) -> [ShellEvent] {
    Array(text.utf8).withUnsafeBufferPointer { feed($0) }
  }

  public func resize(columns: Int, rows: Int) {
    guard columns != terminal.columns || rows != terminal.rows else { return }
    terminal.resize(columns: columns, rows: rows)
    // The shell redraws its prompt after a resize, which re-anchors. Until then the text on
    // screen may have been re-wrapped by the real terminal in ways the model did not follow.
    anchorIsStale = true
  }

  // MARK: - Edit buffer

  /// The command line being edited, or nil when there is none to complete right now.
  public func editBuffer() -> EditBuffer? {
    guard !isExecuting, hasSeenPrompt, info.shell != nil, !terminal.isAlternateScreen else { return nil }

    let cursorCell = GridPosition(row: terminal.cursor.row, column: terminal.cursor.column)
    let grid = GridSize(
      rows: terminal.rows, columns: terminal.columns, pixelWidth: pixelSize?.width, pixelHeight: pixelSize?.height)

    if let reported {
      return EditBuffer(text: reported.text, cursor: reported.cursor, cursorCell: cursorCell, grid: grid)
    }
    guard !anchorIsStale, let scraped = scrapeScreen() else { return nil }
    return EditBuffer(text: scraped.text, cursor: scraped.cursor, cursorCell: cursorCell, grid: grid)
  }

  /// Reads the command line off the screen: everything from the end of the prompt to the end
  /// of the logical line the cursor is on, leaving out prompt cells and ghost text.
  private func scrapeScreen() -> (text: String, cursor: Int)? {
    guard let anchor = terminal.anchor else { return nil }
    let cursor = terminal.cursor
    // A wrap is pending when the last column was just filled: the cursor is logically past it.
    let cursorColumn = terminal.isWrapPending ? terminal.columns : cursor.column
    guard cursor.row > anchor.row || (cursor.row == anchor.row && cursorColumn >= anchor.column) else {
      return nil
    }

    var text = String.UnicodeScalarView()
    var utf16Count = 0
    var cursorIndex: Int?
    // Blank cells only count as spaces when something real follows them on the same row,
    // which keeps the gap before a right-hand prompt out of the buffer.
    var pendingBlanks = 0

    func flushBlanks() {
      text.append(contentsOf: repeatElement(" ", count: pendingBlanks))
      utf16Count += pendingBlanks
      pendingBlanks = 0
    }

    var row = anchor.row
    var column = anchor.column
    while row < terminal.rows {
      while column < terminal.columns {
        if row == cursor.row && column == cursorColumn {
          flushBlanks()
          cursorIndex = utf16Count
        }
        let cell = terminal.cell(row: row, column: column)
        let cellColumn = column
        column += 1
        if cell.width == 0 || cell.origin.contains(.prompt) { continue }
        // Ghost text can only follow the cursor, so text before it that merely shares the
        // suggestion's colour (syntax highlighting) is kept.
        if cursorIndex != nil, suggestionStyle.matches(cell.style) { continue }
        if cell.scalar == 0 {
          pendingBlanks += 1
          continue
        }
        flushBlanks()
        var cellText = String.UnicodeScalarView()
        terminal.appendText(row: row, column: cellColumn, to: &cellText)
        text.append(contentsOf: cellText)
        utf16Count += cellText.reduce(0) { $0 + UTF16.width($1) }
      }

      if row == cursor.row && cursorColumn >= terminal.columns {
        flushBlanks()
        cursorIndex = utf16Count
      }

      let wrapped = terminal.isWrapped(row: row)
      if row >= cursor.row && !wrapped { break }
      if !wrapped {
        // The cursor is further down, so the buffer continues on the next row. A row filled to
        // its last column was most likely wrapped by the line editor; anything shorter was
        // ended with a newline.
        let lastCell = terminal.cell(row: row, column: terminal.columns - 1)
        if lastCell.scalar == 0 && lastCell.width != 0 {
          pendingBlanks = 0
          text.append("\n")
          utf16Count += 1
        }
      }
      pendingBlanks = 0
      row += 1
      column = 0
    }

    guard let cursorIndex else { return nil }

    // Trailing whitespace after the cursor is an artefact of how the line was drawn.
    var result = String(text)
    while result.utf16.count > cursorIndex, let last = result.unicodeScalars.last, last == " " || last == "\n" {
      result.unicodeScalars.removeLast()
    }
    return (result, cursorIndex)
  }

  // MARK: - TerminalDelegate

  public func terminal(_ terminal: Terminal, didReceiveOSC payload: [UInt8]) {
    let fields = payload.split(separator: UInt8(ascii: ";"), maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count == 3,
      fields[0].elementsEqual(Self.oscNumber.utf8),
      fields[1].elementsEqual(sessionId.utf8)
    else { return }

    let body = String(decoding: fields[2], as: UTF8.self)
    let key: Substring
    let value: String
    if let separator = body.firstIndex(of: "=") {
      key = body[..<separator]
      value = String(body[body.index(after: separator)...])
    } else {
      key = Substring(body)
      value = ""
    }
    handle(key: key, value: value)
  }

  private func handle(key: Substring, value: String) {
    switch key {
    case "StartPrompt":
      terminal.origin.insert(.prompt)

    case "EndPrompt":
      terminal.origin.remove(.prompt)

    case "NewCmd":
      // The left prompt has just been drawn: the cursor sits on the first editable cell.
      terminal.origin.remove(.prompt)
      terminal.setAnchorAtCursor()
      anchorIsStale = false
      hasSeenPrompt = true
      if isExecuting {
        isExecuting = false
        if let command = pendingCommand {
          events.append(.postExec(command: command, exitCode: pendingExitCode ?? 0))
        }
        pendingCommand = nil
        pendingExitCode = nil
      }
      events.append(.prompt)

    case "PreExec":
      guard !isExecuting else { return }
      // Shells pass the command line they are about to run; fall back to what was on screen.
      let command = value.isEmpty ? editBuffer()?.text : Self.unescape(value).text
      pendingCommand = command?.trimmingTrailingWhitespace()
      isExecuting = true
      reported = nil
      terminal.origin.remove(.prompt)
      events.append(.preExec)

    case "PreCmd":
      // A new command line is about to begin (also after Ctrl-C or an empty line, which run
      // nothing), so the last report describes a line that no longer exists. Prompt redraws
      // do not come through here and keep the report.
      reported = nil

    case "ExitCode":
      pendingExitCode = Int32(value)

    case "Buffer":
      // The whole command line, with `\c` marking where the cursor is.
      guard !isExecuting else { return }
      let unescaped = Self.unescape(value)
      reported = (unescaped.text, unescaped.cursor ?? unescaped.text.utf16.count)

    case "Dir": update(\.cwd, to: Self.unescape(value).text)
    case "Shell": update(\.shell, to: value)
    case "ShellPath": update(\.shellPath, to: Self.unescape(value).text)
    case "PID": update(\.pid, to: Int32(value))
    case "TTY": update(\.tty, to: value)
    case "User": update(\.user, to: Self.unescape(value).text)

    case "ZshAutosuggestionColor":
      suggestionStyle = .zsh(value)
    case "FishSuggestionColor":
      suggestionStyle = .fish(value)

    case "EnvStart":
      pendingEnvironment = [:]
    case "Var":
      guard pendingEnvironment != nil, let separator = value.firstIndex(of: "=") else { return }
      pendingEnvironment?[String(value[..<separator])] = Self.unescape(String(value[value.index(after: separator)...])).text
    case "EnvEnd":
      guard let pending = pendingEnvironment else { return }
      pendingEnvironment = nil
      if pending != environment {
        environment = pending
        noteEnvironmentChanged()
      }
    case "Aliases":
      let unescaped = Self.unescape(value).text
      if unescaped != aliases {
        aliases = unescaped
        noteEnvironmentChanged()
      }

    default:
      break
    }
  }

  /// Variables and aliases usually change together; one event covers both.
  private func noteEnvironmentChanged() {
    if !events.contains(.environmentChanged) {
      events.append(.environmentChanged)
    }
  }

  private func update<Value: Equatable>(_ keyPath: WritableKeyPath<ShellInfo, Value?>, to value: Value?) {
    guard let value, info[keyPath: keyPath] != value else { return }
    info[keyPath: keyPath] = value
    if events.last != .infoChanged {
      events.append(.infoChanged)
    }
  }

  // MARK: - Value encoding

  /// Reverses the escaping the shell scripts apply so values survive inside an escape sequence:
  /// `\\`, `\e` (ESC), `\a` (BEL), `\n`, `\r` and `\t`. `\c` is not a character: it marks the
  /// cursor, whose position is returned in UTF-16 units.
  static func unescape(_ value: String) -> (text: String, cursor: Int?) {
    guard value.contains("\\") else { return (value, nil) }
    var result = String.UnicodeScalarView()
    var utf16Count = 0
    var cursor: Int?
    func append(_ scalar: Unicode.Scalar) {
      result.append(scalar)
      utf16Count += UTF16.width(scalar)
    }
    var iterator = value.unicodeScalars.makeIterator()
    while let scalar = iterator.next() {
      guard scalar == "\\" else {
        append(scalar)
        continue
      }
      switch iterator.next() {
      case "\\"?: append("\\")
      case "e"?: append("\u{1b}")
      case "a"?: append("\u{07}")
      case "n"?: append("\n")
      case "r"?: append("\r")
      case "t"?: append("\t")
      case "c"?: cursor = utf16Count
      case let other?:
        append("\\")
        append(other)
      case nil:
        append("\\")
      }
    }
    return (String(result), cursor)
  }
}

extension String {
  func trimmingTrailingWhitespace() -> String {
    var scalars = unicodeScalars
    while let last = scalars.last, last == " " || last == "\n" || last == "\t" {
      scalars.removeLast()
    }
    return String(scalars)
  }
}
