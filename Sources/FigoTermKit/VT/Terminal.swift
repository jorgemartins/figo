public protocol TerminalDelegate: AnyObject {
  /// An operating system command arrived. Called in stream order, so the cursor and screen
  /// reflect everything printed before it and nothing printed after.
  func terminal(_ terminal: Terminal, didReceiveOSC payload: [UInt8])
}

/// A headless model of what a terminal emulator is showing.
///
/// It exists to answer one question: what did the shell draw, and where is the cursor. It keeps
/// only the visible screen, no scrollback, and ignores everything that affects appearance alone.
public final class Terminal: VTHandler {
  public struct Position: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) {
      self.row = row
      self.column = column
    }
  }

  public weak var delegate: TerminalDelegate?

  public private(set) var columns: Int
  public private(set) var rows: Int

  /// Stamped on every cell printed from now on. Set by the shell integration layer.
  public var origin = CellOrigin()

  public private(set) var isAlternateScreen = false
  /// DECCKM: arrow keys are sent as `ESC O A` instead of `ESC [ A`.
  public private(set) var applicationCursorKeys = false
  /// The foreground program asked for pastes to be wrapped in `ESC [ 200 ~ ... ESC [ 201 ~`.
  public private(set) var bracketedPaste = false

  private var parser = VTParser()
  private var primary: Screen
  private var alternate: Screen
  /// Whichever of the two is being drawn to.
  private var screen: Screen
  private var style = CellStyle()
  private var autowrap = true
  private var insertMode = false
  private var originMode = false

  public init(columns: Int, rows: Int) {
    self.columns = max(columns, 1)
    self.rows = max(rows, 1)
    primary = Screen(columns: self.columns, rows: self.rows)
    alternate = Screen(columns: self.columns, rows: self.rows)
    screen = primary
  }

  // MARK: - Input

  public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
    var handler = self
    parser.feed(bytes, handler: &handler)
  }

  public func feed(_ bytes: [UInt8]) {
    bytes.withUnsafeBufferPointer { feed($0) }
  }

  public func feed(_ text: String) {
    feed(Array(text.utf8))
  }

  public func resize(columns newColumns: Int, rows newRows: Int) {
    let newColumns = max(newColumns, 1)
    let newRows = max(newRows, 1)
    guard newColumns != columns || newRows != rows else { return }
    primary.resize(columns: newColumns, rows: newRows)
    alternate.resize(columns: newColumns, rows: newRows)
    columns = newColumns
    rows = newRows
  }

  // MARK: - Anchor

  /// A position on the primary screen that stays attached to its line as the screen scrolls.
  /// It becomes nil when that line scrolls off the top or the terminal is reset.
  public var anchor: Position? {
    primary.anchor.map { Position(row: $0.row, column: $0.column) }
  }

  /// Anchors at the cursor, optionally moved left by `columnOffset` cells.
  public func setAnchorAtCursor(columnOffset: Int = 0) {
    primary.anchor = Screen.Position(row: primary.cursor.row, column: max(primary.cursor.column - columnOffset, 0))
  }

  public func clearAnchor() {
    primary.anchor = nil
  }

  // MARK: - Reading the screen

  public var cursor: Position { Position(row: screen.cursor.row, column: screen.cursor.column) }

  /// True right after the last column was filled: the cursor is still drawn on that column but
  /// the next character will go to the start of the next line.
  public var isWrapPending: Bool { screen.pendingWrap }

  public func cell(row: Int, column: Int) -> Cell {
    screen.cell(row, column)
  }

  public func isWrapped(row: Int) -> Bool {
    screen.isWrapped(row)
  }

  /// Appends the text of one cell: nothing for the trailing half of a wide character, a space
  /// for a cell nothing was printed to.
  public func appendText(row: Int, column: Int, to scalars: inout String.UnicodeScalarView) {
    let cell = screen.cell(row, column)
    guard cell.width != 0 else { return }
    scalars.append(Unicode.Scalar(cell.scalar == 0 ? 0x20 : cell.scalar) ?? " ")
    if let marks = screen.combiningMarks(row, column) {
      scalars.append(contentsOf: marks)
    }
  }

  /// The text of one row with trailing blanks removed.
  public func text(row: Int) -> String {
    var end = columns
    while end > 0 && screen.cell(row, end - 1).isBlank { end -= 1 }
    var scalars = String.UnicodeScalarView()
    for column in 0..<end { appendText(row: row, column: column, to: &scalars) }
    return String(scalars)
  }

  // MARK: - VTHandler

  public func print(_ scalar: Unicode.Scalar) {
    let screen = self.screen
    let value = scalar.value

    // Plain text that fits on the line, by far the most common case.
    if value < 0x300, !screen.pendingWrap, !insertMode {
      let row = screen.cursor.row
      let column = screen.cursor.column
      if screen.cell(row, column).width == 1 {
        var cell = Cell()
        cell.scalar = value
        cell.origin = origin
        cell.style = style
        screen.set(cell, row, column)
        if column + 1 >= columns {
          screen.pendingWrap = true
        } else {
          screen.cursor.column = column + 1
        }
        return
      }
    }
    printSlow(scalar)
  }

  public func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
    let screen = self.screen
    var template = Cell()
    template.origin = origin
    template.style = style

    var index = 0
    while index < bytes.count {
      let column = screen.cursor.column
      let length = min(bytes.count - index, columns - column)
      if screen.pendingWrap || insertMode
        || !screen.writeASCII(
          UnsafeBufferPointer(rebasing: bytes[index..<index + length]), screen.cursor.row, column, template: template)
      {
        // Wrapping, insert mode or a wide character in the way: one careful step, then retry.
        printSlow(Unicode.Scalar(bytes[index]))
        index += 1
        continue
      }
      index += length
      if column + length >= columns {
        screen.cursor.column = columns - 1
        screen.pendingWrap = true
      } else {
        screen.cursor.column = column + length
      }
    }
  }

  private func printSlow(_ scalar: Unicode.Scalar) {
    let screen = self.screen
    let width = columnWidth(of: scalar)
    if width == 0 {
      attachCombining(scalar)
      return
    }

    if screen.pendingWrap || (width == 2 && screen.cursor.column == columns - 1) {
      if autowrap {
        screen.setWrapped(screen.cursor.row, true)
        screen.cursor.column = 0
        lineFeed()
      } else if width == 2 {
        screen.cursor.column = max(columns - 2, 0)
      }
      screen.pendingWrap = false
    }

    let row = screen.cursor.row
    let column = screen.cursor.column
    if insertMode {
      screen.insertBlanks(row, at: column, count: width)
    }

    var cell = Cell()
    cell.scalar = scalar.value
    cell.width = UInt8(width)
    cell.origin = origin
    cell.style = style
    write(cell, row: row, column: column)
    if width == 2 && column + 1 < columns {
      var spacer = cell
      spacer.scalar = 0
      spacer.width = 0
      write(spacer, row: row, column: column + 1)
    }

    if column + width >= columns {
      screen.cursor.column = columns - 1
      screen.pendingWrap = true
    } else {
      screen.cursor.column = column + width
    }
  }

  public func execute(_ byte: UInt8) {
    let screen = self.screen
    switch byte {
    case 0x08: // BS
      screen.cursor.column = max(screen.cursor.column - 1, 0)
      screen.pendingWrap = false
    case 0x09: // HT
      screen.cursor.column = min((screen.cursor.column / 8 + 1) * 8, columns - 1)
    case 0x0a, 0x0b, 0x0c: // LF VT FF
      // An explicit newline ends the logical line, even where it had wrapped before.
      screen.setWrapped(screen.cursor.row, false)
      lineFeed()
    case 0x0d: // CR
      screen.cursor.column = 0
      screen.pendingWrap = false
    default:
      break
    }
  }

  public func escDispatch(intermediates: [UInt8], final: UInt8) {
    guard intermediates.isEmpty else {
      if intermediates == [0x23], final == 0x38 { // DECALN
        var cell = Cell()
        cell.scalar = 0x45
        screen.fill(with: cell)
      }
      return
    }
    switch final {
    case 0x37: saveCursor() // DECSC
    case 0x38: restoreCursor() // DECRC
    case 0x44: lineFeed() // IND
    case 0x45: // NEL
      screen.cursor.column = 0
      lineFeed()
    case 0x4d: reverseLineFeed() // RI
    case 0x63: reset() // RIS
    default: break
    }
  }

  public func oscDispatch(_ payload: [UInt8]) {
    delegate?.terminal(self, didReceiveOSC: payload)
  }

  public func csiDispatch(params: VTParams, prefix: UInt8, intermediates: [UInt8], final: UInt8) {
    if prefix == 0x3f { // ?
      if final == 0x68 || final == 0x6c { // h l
        for index in 0..<params.count {
          setPrivateMode(params.raw(index), enabled: final == 0x68)
        }
      }
      return
    }
    guard prefix == 0, intermediates.isEmpty else { return }

    let screen = self.screen
    let n = params.value(0, default: 1)
    switch final {
    case 0x40: // ICH
      screen.insertBlanks(screen.cursor.row, at: screen.cursor.column, count: n)
      screen.pendingWrap = false
    case 0x41: moveCursor(rows: -n) // CUU
    case 0x42, 0x65: moveCursor(rows: n) // CUD VPR
    case 0x43, 0x61: moveCursor(columns: n) // CUF HPR
    case 0x44: moveCursor(columns: -n) // CUB
    case 0x45: // CNL
      moveCursor(rows: n)
      screen.cursor.column = 0
    case 0x46: // CPL
      moveCursor(rows: -n)
      screen.cursor.column = 0
    case 0x47, 0x60: setCursor(column: n - 1) // CHA HPA
    case 0x48, 0x66: // CUP HVP
      setCursor(row: n - 1, column: params.value(1, default: 1) - 1)
    case 0x4a: eraseInDisplay(params.raw(0)) // ED
    case 0x4b: eraseInLine(params.raw(0)) // EL
    case 0x4c: insertLines(n) // IL
    case 0x4d: deleteLines(n) // DL
    case 0x50: // DCH
      screen.deleteCells(screen.cursor.row, at: screen.cursor.column, count: n)
      screen.pendingWrap = false
    case 0x53: scrollUp(n) // SU
    case 0x54: scrollDown(n) // SD
    case 0x58: // ECH
      screen.clear(screen.cursor.row, screen.cursor.column..<screen.cursor.column + n)
      screen.pendingWrap = false
    case 0x64: setCursor(row: n - 1) // VPA
    case 0x68, 0x6c: // SM RM
      for index in 0..<params.count where params.raw(index) == 4 {
        insertMode = final == 0x68
      }
    case 0x6d: selectGraphicRendition(params) // SGR
    case 0x72: // DECSTBM
      let top = params.value(0, default: 1) - 1
      let bottom = params.value(1, default: rows) - 1
      if top < bottom, bottom < rows {
        screen.scrollTop = top
        screen.scrollBottom = bottom
      } else {
        screen.scrollTop = 0
        screen.scrollBottom = rows - 1
      }
      setCursor(row: 0, column: 0)
    case 0x73: saveCursor() // SCOSC
    case 0x75: restoreCursor() // SCORC
    default: break
    }
  }

  // MARK: - Modes

  private func setPrivateMode(_ mode: Int, enabled: Bool) {
    switch mode {
    case 1: applicationCursorKeys = enabled
    case 6:
      originMode = enabled
      setCursor(row: 0, column: 0)
    case 7: autowrap = enabled
    case 47, 1047: switchScreen(alternate: enabled, saveCursor: false)
    case 1048: if enabled { saveCursor() } else { restoreCursor() }
    case 1049: switchScreen(alternate: enabled, saveCursor: true)
    case 2004: bracketedPaste = enabled
    default: break
    }
  }

  private func switchScreen(alternate enable: Bool, saveCursor save: Bool) {
    guard enable != isAlternateScreen else { return }
    if enable {
      if save { saveCursor() }
      isAlternateScreen = true
      alternate = Screen(columns: columns, rows: rows)
      screen = alternate
    } else {
      isAlternateScreen = false
      screen = primary
      if save { restoreCursor() }
    }
  }

  private func reset() {
    primary = Screen(columns: columns, rows: rows)
    alternate = Screen(columns: columns, rows: rows)
    screen = primary
    isAlternateScreen = false
    style = CellStyle()
    autowrap = true
    insertMode = false
    originMode = false
    applicationCursorKeys = false
    bracketedPaste = false
  }

  private func saveCursor() {
    screen.saved = Screen.SavedCursor(position: screen.cursor, style: style, originMode: originMode)
  }

  private func restoreCursor() {
    let saved = screen.saved
    screen.cursor = Screen.Position(
      row: min(saved.position.row, rows - 1), column: min(saved.position.column, columns - 1))
    screen.pendingWrap = false
    style = saved.style
    originMode = saved.originMode
  }

  // MARK: - Cursor movement

  private func setCursor(row: Int? = nil, column: Int? = nil) {
    if let row {
      let top = originMode ? screen.scrollTop : 0
      let bottom = originMode ? screen.scrollBottom : rows - 1
      screen.cursor.row = min(max(top + row, top), bottom)
    }
    if let column {
      screen.cursor.column = min(max(column, 0), columns - 1)
    }
    screen.pendingWrap = false
  }

  private func moveCursor(rows delta: Int = 0, columns columnDelta: Int = 0) {
    if delta != 0 {
      // Vertical movement stops at the scroll margins when it starts inside them.
      let row = screen.cursor.row
      let top = row >= screen.scrollTop ? screen.scrollTop : 0
      let bottom = row <= screen.scrollBottom ? screen.scrollBottom : rows - 1
      screen.cursor.row = min(max(row + delta, top), bottom)
    }
    if columnDelta != 0 {
      screen.cursor.column = min(max(screen.cursor.column + columnDelta, 0), columns - 1)
    }
    screen.pendingWrap = false
  }

  private func lineFeed() {
    screen.pendingWrap = false
    if screen.cursor.row == screen.scrollBottom {
      scrollUp(1)
    } else if screen.cursor.row < rows - 1 {
      screen.cursor.row += 1
    }
  }

  private func reverseLineFeed() {
    screen.pendingWrap = false
    if screen.cursor.row == screen.scrollTop {
      scrollDown(1)
    } else if screen.cursor.row > 0 {
      screen.cursor.row -= 1
    }
  }

  // MARK: - Scrolling and line editing

  /// The anchor belongs to the primary screen and only follows scrolling that happens there.
  private var scrollMovesAnchor: Bool { !isAlternateScreen }

  private func scrollUp(_ count: Int) {
    screen.shiftRows(top: screen.scrollTop, bottom: screen.scrollBottom, by: count, movesAnchor: scrollMovesAnchor)
  }

  private func scrollDown(_ count: Int) {
    screen.shiftRows(top: screen.scrollTop, bottom: screen.scrollBottom, by: -count, movesAnchor: scrollMovesAnchor)
  }

  private func insertLines(_ count: Int) {
    let row = screen.cursor.row
    guard row >= screen.scrollTop, row <= screen.scrollBottom else { return }
    screen.shiftRows(top: row, bottom: screen.scrollBottom, by: -count, movesAnchor: scrollMovesAnchor)
    screen.cursor.column = 0
    screen.pendingWrap = false
  }

  private func deleteLines(_ count: Int) {
    let row = screen.cursor.row
    guard row >= screen.scrollTop, row <= screen.scrollBottom else { return }
    screen.shiftRows(top: row, bottom: screen.scrollBottom, by: count, movesAnchor: scrollMovesAnchor)
    screen.cursor.column = 0
    screen.pendingWrap = false
  }

  // MARK: - Erasing

  private func eraseInLine(_ mode: Int) {
    let row = screen.cursor.row
    let column = screen.cursor.column
    switch mode {
    case 0:
      screen.clear(row, column..<columns)
      screen.setWrapped(row, false)
    case 1:
      screen.clear(row, 0..<column + 1)
    case 2:
      screen.clearRow(row)
    default:
      break
    }
    screen.pendingWrap = false
  }

  private func eraseInDisplay(_ mode: Int) {
    let row = screen.cursor.row
    switch mode {
    case 0:
      eraseInLine(0)
      for index in (row + 1)..<max(rows, row + 1) { screen.clearRow(index) }
    case 1:
      eraseInLine(1)
      for index in 0..<row { screen.clearRow(index) }
    case 2:
      screen.clearAll()
      screen.pendingWrap = false
    default:
      break // 3 clears scrollback, which is not modelled.
    }
  }

  // MARK: - Writing cells

  private func write(_ cell: Cell, row: Int, column: Int) {
    let existing = screen.cell(row, column)
    // Overwriting one half of a wide character leaves the other half meaningless.
    if existing.width == 0, column > 0, cell.width != 0 {
      screen.set(.blank, row, column - 1)
    } else if existing.width == 2, column + 1 < columns, cell.width == 1 {
      screen.set(.blank, row, column + 1)
    }
    screen.set(cell, row, column)
  }

  private func attachCombining(_ scalar: Unicode.Scalar) {
    // The character it modifies is the one just printed, left of the cursor unless a wrap
    // is pending, in which case the cursor is still on it.
    let row = screen.cursor.row
    var column = screen.pendingWrap ? screen.cursor.column : screen.cursor.column - 1
    guard column >= 0 else { return }
    if screen.cell(row, column).width == 0, column > 0 { column -= 1 }
    guard screen.cell(row, column).scalar != 0 else { return }
    screen.addCombiningMark(scalar, row, column)
  }

  // MARK: - SGR

  private func selectGraphicRendition(_ params: VTParams) {
    if params.count == 0 {
      style = CellStyle()
      return
    }
    var index = 0
    while index < params.count {
      let code = params.raw(index)
      switch code {
      case 0: style = CellStyle()
      case 1: style.bold = true
      case 2: style.dim = true
      case 3: style.italic = true
      case 4: style.underline = !(index + 1 < params.count && params.isSub[index + 1] && params.raw(index + 1) == 0)
      case 7: style.inverse = true
      case 8: style.hidden = true
      case 22:
        style.bold = false
        style.dim = false
      case 23: style.italic = false
      case 24: style.underline = false
      case 27: style.inverse = false
      case 28: style.hidden = false
      case 30...37: style.foreground = .indexed(UInt8(code - 30))
      case 39: style.foreground = .default
      case 40...47: style.background = .indexed(UInt8(code - 40))
      case 49: style.background = .default
      case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
      case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
      case 38, 48, 58:
        let (color, consumed) = extendedColor(params, at: index)
        if let color {
          if code == 38 { style.foreground = color } else if code == 48 { style.background = color }
        }
        index += consumed
      default:
        break
      }
      index += 1
      // Skip sub-parameters that belong to a code handled above (e.g. 4:3).
      while index < params.count, params.isSub[index] { index += 1 }
    }
  }

  /// Parses the colour following a 38/48/58 at `index`, in either `38;2;r;g;b` or `38:2::r:g:b`
  /// form. Returns the colour and how many parameters after `index` it used.
  private func extendedColor(_ params: VTParams, at index: Int) -> (TerminalColor?, Int) {
    guard index + 1 < params.count else { return (nil, 0) }
    let colon = params.isSub[index + 1]
    var end = index + 1
    if colon {
      while end < params.count, params.isSub[end] { end += 1 }
    } else {
      end = params.count
    }
    let values = (index + 1..<end).map { params.raw($0) }
    func byte(_ value: Int) -> UInt8 { UInt8(clamping: value) }

    switch values.first {
    case 5 where values.count >= 2:
      return (.indexed(byte(values[1])), colon ? values.count : 2)
    case 2 where values.count >= 4:
      // The colon form may carry a colour-space id before the components: 2::r:g:b.
      let rgb = colon && values.count >= 5 ? Array(values.suffix(3)) : Array(values[1...3])
      return (.rgb(byte(rgb[0]), byte(rgb[1]), byte(rgb[2])), colon ? values.count : 4)
    default:
      return (nil, colon ? values.count : 0)
    }
  }
}
