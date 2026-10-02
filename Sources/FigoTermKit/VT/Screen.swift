/// The cells of one screen (primary or alternate), plus the cursor and scrolling state that
/// belong to it.
///
/// Rows are stored in one flat block and addressed through `rowMap`, so scrolling moves a few
/// integers instead of copying or allocating lines. This is the hottest data structure in the
/// wrapper: all shell output is written through it.
final class Screen {
  struct Position: Equatable {
    var row: Int
    var column: Int
  }

  struct SavedCursor {
    var position = Position(row: 0, column: 0)
    var style = CellStyle()
    var originMode = false
  }

  private(set) var columns: Int
  private(set) var rows: Int
  private var cells: UnsafeMutablePointer<Cell>
  /// Screen row → row in `cells`.
  private var rowMap: [Int]
  /// Per screen row: the text continues on the next row because it reached the right margin.
  private var wrapped: [Bool]
  /// Zero-width scalars attached to a cell, keyed by its index in `cells`.
  private var combining: [Int: [Unicode.Scalar]] = [:]

  var cursor = Position(row: 0, column: 0)
  /// Set after printing in the last column: the next character wraps before it is placed.
  var pendingWrap = false
  var saved = SavedCursor()
  var scrollTop = 0
  var scrollBottom: Int
  /// A position that stays attached to its line as the screen scrolls.
  var anchor: Position?

  init(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
    cells = .allocate(capacity: columns * rows)
    cells.initialize(repeating: .blank, count: columns * rows)
    rowMap = Array(0..<rows)
    wrapped = Array(repeating: false, count: rows)
    scrollBottom = rows - 1
  }

  deinit {
    cells.deallocate()
  }

  // MARK: - Cells

  @inline(__always)
  private func index(_ row: Int, _ column: Int) -> Int {
    rowMap[row] * columns + column
  }

  @inline(__always)
  func cell(_ row: Int, _ column: Int) -> Cell {
    cells[index(row, column)]
  }

  @inline(__always)
  func set(_ cell: Cell, _ row: Int, _ column: Int) {
    let index = index(row, column)
    cells[index] = cell
    if !combining.isEmpty { combining[index] = nil }
  }

  /// Writes a run of single-width characters starting at `column`, all sharing `template`'s
  /// origin and style. Returns false without writing anything when the run would cut through a
  /// wide character, which the caller then handles cell by cell.
  func writeASCII(_ bytes: UnsafeBufferPointer<UInt8>, _ row: Int, _ column: Int, template: Cell) -> Bool {
    let start = index(row, column)
    let destination = cells + start
    for offset in 0..<bytes.count where destination[offset].width != 1 {
      return false
    }
    var cell = template
    for offset in 0..<bytes.count {
      cell.scalar = UInt32(bytes[offset])
      destination[offset] = cell
    }
    if !combining.isEmpty {
      for index in start..<start + bytes.count { combining[index] = nil }
    }
    return true
  }

  func isWrapped(_ row: Int) -> Bool { wrapped[row] }
  func setWrapped(_ row: Int, _ value: Bool) { wrapped[row] = value }

  func combiningMarks(_ row: Int, _ column: Int) -> [Unicode.Scalar]? {
    combining.isEmpty ? nil : combining[index(row, column)]
  }

  func addCombiningMark(_ scalar: Unicode.Scalar, _ row: Int, _ column: Int) {
    combining[index(row, column), default: []].append(scalar)
  }

  func clear(_ row: Int, _ range: Range<Int>) {
    let range = range.clamped(to: 0..<columns)
    guard !range.isEmpty else { return }
    let start = index(row, range.lowerBound)
    (cells + start).update(repeating: .blank, count: range.count)
    if !combining.isEmpty {
      for index in start..<start + range.count { combining[index] = nil }
    }
  }

  func clearRow(_ row: Int) {
    clear(row, 0..<columns)
    wrapped[row] = false
  }

  func clearAll() {
    for row in 0..<rows { clearRow(row) }
  }

  func fill(with cell: Cell) {
    cells.update(repeating: cell, count: columns * rows)
    combining.removeAll()
    for row in 0..<rows { wrapped[row] = false }
  }

  // MARK: - Moving cells within a row

  /// Opens a gap of `count` blank cells at `column`, pushing the rest of the row right.
  func insertBlanks(_ row: Int, at column: Int, count: Int) {
    let amount = min(count, columns - column)
    guard amount > 0 else { return }
    let base = cells + index(row, 0)
    let moved = columns - column - amount
    if moved > 0 {
      (base + column + amount).update(from: base + column, count: moved)
    }
    (base + column).update(repeating: .blank, count: amount)
    dropCombining(row)
  }

  /// Removes `count` cells at `column`, pulling the rest of the row left.
  func deleteCells(_ row: Int, at column: Int, count: Int) {
    let amount = min(count, columns - column)
    guard amount > 0 else { return }
    let base = cells + index(row, 0)
    let moved = columns - column - amount
    if moved > 0 {
      (base + column).update(from: base + column + amount, count: moved)
    }
    (base + columns - amount).update(repeating: .blank, count: amount)
    dropCombining(row)
  }

  /// Shifting cells would leave side-table entries pointing at the wrong characters; losing a
  /// combining mark on a row being edited in place is the lesser evil.
  private func dropCombining(_ row: Int) {
    guard !combining.isEmpty else { return }
    let start = index(row, 0)
    for index in start..<start + columns { combining[index] = nil }
  }

  // MARK: - Scrolling

  /// Moves the rows in `top...bottom` up by `count` (down when negative). Rows that fall off
  /// are cleared and reused at the other end.
  func shiftRows(top: Int, bottom: Int, by count: Int, movesAnchor: Bool) {
    let height = bottom - top + 1
    let amount = min(abs(count), height)
    guard amount > 0 else { return }

    if movesAnchor, let current = anchor, (top...bottom).contains(current.row) {
      let row = current.row - (count > 0 ? amount : -amount)
      anchor = (top...bottom).contains(row) ? Position(row: row, column: current.column) : nil
    }

    if amount == height {
      // Everything in the region scrolls out. There is nothing left to move, and the ranges
      // below would be empty ones written backwards.
      for row in top...bottom { clearRow(row) }
      return
    }

    if count > 0 {
      let recycled = Array(rowMap[top..<top + amount])
      let recycledWrapped = [Bool](repeating: false, count: amount)
      rowMap.replaceSubrange(top...bottom, with: rowMap[(top + amount)...bottom] + recycled)
      wrapped.replaceSubrange(top...bottom, with: wrapped[(top + amount)...bottom] + recycledWrapped)
      for row in (bottom - amount + 1)...bottom { clearRow(row) }
    } else {
      let recycled = Array(rowMap[(bottom - amount + 1)...bottom])
      let recycledWrapped = [Bool](repeating: false, count: amount)
      rowMap.replaceSubrange(top...bottom, with: recycled + rowMap[top...(bottom - amount)])
      wrapped.replaceSubrange(top...bottom, with: recycledWrapped + wrapped[top...(bottom - amount)])
      for row in top..<(top + amount) { clearRow(row) }
    }
  }

  // MARK: - Resizing

  func resize(columns newColumns: Int, rows newRows: Int) {
    let newCells = UnsafeMutablePointer<Cell>.allocate(capacity: newColumns * newRows)
    newCells.initialize(repeating: .blank, count: newColumns * newRows)

    // Keep the cursor's line on screen: when shrinking, rows are dropped from the top first.
    let dropped = rows > newRows ? min(rows - newRows, max(cursor.row - (newRows - 1), 0)) : 0
    let copiedRows = min(rows - dropped, newRows)
    let copiedColumns = min(columns, newColumns)
    var newWrapped = [Bool](repeating: false, count: newRows)
    var newCombining: [Int: [Unicode.Scalar]] = [:]
    for row in 0..<copiedRows {
      let source = index(row + dropped, 0)
      (newCells + row * newColumns).update(from: cells + source, count: copiedColumns)
      newWrapped[row] = wrapped[row + dropped] && newColumns == columns
      if !combining.isEmpty {
        for column in 0..<copiedColumns {
          if let marks = combining[source + column] { newCombining[row * newColumns + column] = marks }
        }
      }
    }

    cells.deallocate()
    cells = newCells
    combining = newCombining
    wrapped = newWrapped
    rowMap = Array(0..<newRows)

    if let current = anchor {
      let row = current.row - dropped
      anchor = row >= 0 && row < newRows && current.column < newColumns ? Position(row: row, column: current.column) : nil
    }
    cursor.row = min(max(cursor.row - dropped, 0), newRows - 1)
    cursor.column = min(cursor.column, newColumns - 1)
    pendingWrap = false
    scrollTop = 0
    scrollBottom = newRows - 1
    columns = newColumns
    rows = newRows
  }
}
