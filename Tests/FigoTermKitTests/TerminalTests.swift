import Testing

@testable import FigoTermKit

private func screen(_ terminal: Terminal) -> [String] {
  (0..<terminal.rows).map { terminal.text(row: $0) }
}

private func makeTerminal(_ columns: Int = 10, _ rows: Int = 4, _ input: String = "") -> Terminal {
  let terminal = Terminal(columns: columns, rows: rows)
  terminal.feed(input)
  return terminal
}

@Suite struct TerminalTests {
  @Test func printsAndAdvancesCursor() {
    let terminal = makeTerminal(10, 4, "hi")
    #expect(screen(terminal) == ["hi", "", "", ""])
    #expect(terminal.cursor == .init(row: 0, column: 2))
  }

  @Test func carriageReturnAndLineFeed() {
    let terminal = makeTerminal(10, 4, "ab\r\ncd\nef")
    #expect(screen(terminal) == ["ab", "cd", "  ef", ""])
  }

  @Test func wrapsAtRightMarginLazily() {
    let terminal = makeTerminal(5, 3, "abcde")
    // The cursor stays on the last column until another character arrives.
    #expect(terminal.cursor == .init(row: 0, column: 4))
    #expect(!terminal.isWrapped(row: 0))
    terminal.feed("f")
    #expect(screen(terminal) == ["abcde", "f", ""])
    #expect(terminal.isWrapped(row: 0))
    #expect(terminal.cursor == .init(row: 1, column: 1))
  }

  @Test func carriageReturnCancelsPendingWrap() {
    let terminal = makeTerminal(5, 3, "abcde\rX")
    #expect(screen(terminal) == ["Xbcde", "", ""])
  }

  @Test func scrollsWhenOutputReachesTheBottom() {
    let terminal = makeTerminal(5, 3, "1\r\n2\r\n3\r\n4")
    #expect(screen(terminal) == ["2", "3", "4"])
    #expect(terminal.cursor == .init(row: 2, column: 1))
  }

  @Test func cursorMovement() {
    let terminal = makeTerminal(10, 4, "\u{1b}[3;4Hx\u{1b}[Ay\u{1b}[2Dz\u{1b}[Bw\u{1b}[Gv")
    #expect(screen(terminal) == ["", "   zy", "v  xw", ""])
  }

  @Test func cursorMovementIsClamped() {
    let terminal = makeTerminal(5, 3, "\u{1b}[99;99H")
    #expect(terminal.cursor == .init(row: 2, column: 4))
    terminal.feed("\u{1b}[99A\u{1b}[99D")
    #expect(terminal.cursor == .init(row: 0, column: 0))
  }

  @Test func eraseInLine() {
    let terminal = makeTerminal(10, 2, "abcdef\u{1b}[3D\u{1b}[K")
    #expect(screen(terminal) == ["abc", ""])
    terminal.feed("\u{1b}[1K")
    #expect(screen(terminal) == ["", ""])
  }

  @Test func eraseInDisplayBelowCursor() {
    let terminal = makeTerminal(5, 3, "aaa\r\nbbb\r\nccc\u{1b}[2;2H\u{1b}[J")
    #expect(screen(terminal) == ["aaa", "b", ""])
  }

  @Test func insertAndDeleteCharacters() {
    let terminal = makeTerminal(10, 1, "abcdef\u{1b}[1;3H\u{1b}[2@")
    #expect(screen(terminal) == ["ab  cdef"])
    terminal.feed("\u{1b}[3P")
    #expect(screen(terminal) == ["abdef"])
  }

  @Test func insertModeShiftsText() {
    let terminal = makeTerminal(10, 1, "abc\u{1b}[1;2H\u{1b}[4hXY\u{1b}[4lZ")
    #expect(screen(terminal) == ["aXYZc"])
  }

  @Test func backspaceMovesWithoutErasing() {
    let terminal = makeTerminal(10, 1, "abc\u{08}\u{08}")
    #expect(screen(terminal) == ["abc"])
    #expect(terminal.cursor.column == 1)
  }

  @Test func wideCharactersTakeTwoCells() {
    let terminal = makeTerminal(10, 1, "a漢b")
    #expect(terminal.cursor.column == 4)
    #expect(terminal.cell(row: 0, column: 1).width == 2)
    #expect(terminal.cell(row: 0, column: 2).width == 0)
    #expect(screen(terminal) == ["a漢b"])
  }

  @Test func wideCharacterWrapsWhenItDoesNotFit() {
    let terminal = makeTerminal(4, 2, "abc漢")
    #expect(screen(terminal) == ["abc", "漢"])
    #expect(terminal.isWrapped(row: 0))
  }

  @Test func combiningMarksJoinThePreviousCell() {
    let terminal = makeTerminal(10, 1, "e\u{301}x")
    #expect(terminal.cursor.column == 2)
    #expect(screen(terminal) == ["e\u{301}x"])
  }

  @Test func alternateScreenIsSeparateAndRestoresCursor() {
    let terminal = makeTerminal(10, 2, "shell\u{1b}[?1049hvim")
    #expect(terminal.isAlternateScreen)
    #expect(screen(terminal) == ["vim", ""])
    terminal.feed("\u{1b}[?1049l")
    #expect(!terminal.isAlternateScreen)
    #expect(screen(terminal) == ["shell", ""])
    #expect(terminal.cursor == .init(row: 0, column: 5))
  }

  @Test func scrollRegionOnlyScrollsInside() {
    let terminal = makeTerminal(5, 4, "top\r\na\r\nb\r\nbot\u{1b}[2;3r\u{1b}[3;1H\nc")
    #expect(screen(terminal) == ["top", "b", "c", "bot"])
  }

  @Test func reverseIndexScrollsDownAtTop() {
    let terminal = makeTerminal(5, 3, "a\r\nb\u{1b}[H\u{1b}Mx")
    #expect(screen(terminal) == ["x", "a", "b"])
  }

  @Test func insertAndDeleteLines() {
    let terminal = makeTerminal(5, 4, "a\r\nb\r\nc\r\nd\u{1b}[2;1H\u{1b}[L")
    #expect(screen(terminal) == ["a", "", "b", "c"])
    terminal.feed("\u{1b}[2M")
    #expect(screen(terminal) == ["a", "c", "", ""])
  }

  @Test func shiftingAWholeRegionClearsIt() {
    // Each of these moves every row of the region out of it, which used to stop the program.
    let filled = "a\r\nb\r\nc\r\nd"
    // Delete line and insert line with the cursor on the last row.
    #expect(screen(makeTerminal(5, 4, filled + "\u{1b}[4;1H\u{1b}[M")) == ["a", "b", "c", ""])
    #expect(screen(makeTerminal(5, 4, filled + "\u{1b}[4;1H\u{1b}[L")) == ["a", "b", "c", ""])
    // More lines than the screen has, from the top.
    #expect(screen(makeTerminal(5, 4, filled + "\u{1b}[H\u{1b}[9M")) == ["", "", "", ""])
    #expect(screen(makeTerminal(5, 4, filled + "\u{1b}[H\u{1b}[4L")) == ["", "", "", ""])
    // Scroll up and down by the height of the screen or more.
    #expect(screen(makeTerminal(5, 4, filled + "\u{1b}[4S")) == ["", "", "", ""])
    #expect(screen(makeTerminal(5, 4, filled + "\u{1b}[99T")) == ["", "", "", ""])
    // Inside a scroll region only that region goes.
    #expect(screen(makeTerminal(5, 4, filled + "\u{1b}[2;3r\u{1b}[2S")) == ["a", "", "", "d"])
    // A line feed in a terminal one row high.
    let single = makeTerminal(5, 1, "ab\r\ncd")
    #expect(screen(single) == ["cd"])
  }

  @Test func saveAndRestoreCursor() {
    let terminal = makeTerminal(10, 2, "ab\u{1b}7\r\ncd\u{1b}8X")
    #expect(screen(terminal) == ["abX", "cd"])
  }

  @Test func tracksStyleAndOriginPerCell() {
    let terminal = makeTerminal(20, 1)
    terminal.origin = .prompt
    terminal.feed("\u{1b}[1;34m$ \u{1b}[0m")
    terminal.origin = []
    terminal.feed("ls\u{1b}[38;5;8m -la\u{1b}[38;2;1;2;3mx\u{1b}[38:2::4:5:6my\u{1b}[90mz")

    #expect(terminal.cell(row: 0, column: 0).origin == .prompt)
    #expect(terminal.cell(row: 0, column: 0).style.bold)
    #expect(terminal.cell(row: 0, column: 0).style.foreground == .indexed(4))
    #expect(terminal.cell(row: 0, column: 2).origin == [])
    #expect(terminal.cell(row: 0, column: 2).style == CellStyle())
    #expect(terminal.cell(row: 0, column: 5).style.foreground == .indexed(8))
    #expect(terminal.cell(row: 0, column: 8).style.foreground == .rgb(1, 2, 3))
    #expect(terminal.cell(row: 0, column: 9).style.foreground == .rgb(4, 5, 6))
    #expect(terminal.cell(row: 0, column: 10).style.foreground == .indexed(8))
  }

  @Test func tracksInputModes() {
    let terminal = makeTerminal(10, 2, "\u{1b}[?2004h\u{1b}[?1h")
    #expect(terminal.bracketedPaste)
    #expect(terminal.applicationCursorKeys)
    terminal.feed("\u{1b}[?2004l\u{1b}[?1l")
    #expect(!terminal.bracketedPaste)
    #expect(!terminal.applicationCursorKeys)
  }

  @Test func resizeKeepsCursorLineVisible() {
    let terminal = makeTerminal(10, 4, "1\r\n2\r\n3\r\n4")
    terminal.resize(columns: 6, rows: 2)
    #expect(screen(terminal) == ["3", "4"])
    #expect(terminal.cursor == .init(row: 1, column: 1))
    terminal.resize(columns: 8, rows: 3)
    #expect(screen(terminal) == ["3", "4", ""])
  }

  @Test func reportsOSCInStreamOrder() {
    final class Recorder: TerminalDelegate {
      var seen: [(String, Int)] = []
      func terminal(_ terminal: Terminal, didReceiveOSC payload: [UInt8]) {
        seen.append((String(decoding: payload, as: UTF8.self), terminal.cursor.column))
      }
    }
    let recorder = Recorder()
    let terminal = Terminal(columns: 20, rows: 2)
    terminal.delegate = recorder
    terminal.feed("\u{1b}]697;StartPrompt\u{07}$ \u{1b}]697;EndPrompt\u{07}ls")
    #expect(recorder.seen.map(\.0) == ["697;StartPrompt", "697;EndPrompt"])
    #expect(recorder.seen.map(\.1) == [0, 2])
  }
}

@Suite struct TerminalAnchorTests {
  @Test func anchorFollowsScrolling() {
    let terminal = makeTerminal(10, 3, "a\r\n$ ")
    terminal.setAnchorAtCursor()
    #expect(terminal.anchor == .init(row: 1, column: 2))
    terminal.feed("x\r\ny\r\nz")
    #expect(terminal.anchor == .init(row: 0, column: 2))
    terminal.feed("\r\n")
    #expect(terminal.anchor == nil)
  }

  @Test func anchorSurvivesResizeThatDropsTopLines() {
    let terminal = makeTerminal(10, 4, "1\r\n2\r\n3\r\n$ ")
    terminal.setAnchorAtCursor()
    terminal.resize(columns: 10, rows: 2)
    #expect(terminal.anchor == .init(row: 1, column: 2))
  }

  @Test func alternateScreenScrollingLeavesAnchorAlone() {
    let terminal = makeTerminal(10, 2, "$ ")
    terminal.setAnchorAtCursor()
    terminal.feed("\u{1b}[?1049h1\r\n2\r\n3\r\n4\u{1b}[?1049l")
    #expect(terminal.anchor == .init(row: 0, column: 2))
  }

  @Test func resetClearsAnchor() {
    let terminal = makeTerminal(10, 2, "$ ")
    terminal.setAnchorAtCursor()
    terminal.feed("\u{1b}c")
    #expect(terminal.anchor == nil)
  }
}
