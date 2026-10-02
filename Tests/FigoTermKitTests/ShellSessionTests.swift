import FigoCore
import Testing

@testable import FigoTermKit

private let sid = "0123456789abcdef"

private func osc(_ payload: String, session: String = sid) -> String {
  "\u{1b}]6977;\(session);\(payload)\u{07}"
}

/// What a shell integration prints before and around a prompt.
private func prompt(_ text: String = "$ ", shell: String = "bash") -> String {
  osc("Shell=\(shell)") + osc("Dir=/tmp") + osc("StartPrompt") + text + osc("EndPrompt") + osc("NewCmd")
}

private func makeSession(columns: Int = 40, rows: Int = 6) -> ShellSession {
  ShellSession(sessionId: sid, columns: columns, rows: rows)
}

@Suite struct ShellSessionStateTests {
  @Test func nothingToEditBeforeTheFirstPrompt() {
    let session = makeSession()
    _ = session.feed("Last login: today\r\n")
    #expect(session.editBuffer() == nil)
    #expect(session.isExecuting)
  }

  @Test func promptStartsEditing() {
    let session = makeSession()
    let events = session.feed(prompt())
    #expect(events == [.infoChanged, .prompt])
    #expect(session.info.shell == "bash")
    #expect(session.info.cwd == "/tmp")
    #expect(session.editBuffer()?.text == "")
    #expect(session.editBuffer()?.cursor == 0)
  }

  @Test func commandLifecycleReportsPostExecAtNextPrompt() {
    let session = makeSession()
    _ = session.feed(prompt() + "ls -la")
    #expect(session.feed("\r\n" + osc("PreExec=ls -la")) == [.preExec])
    #expect(session.editBuffer() == nil)
    _ = session.feed("total 0\r\n")
    let events = session.feed(osc("ExitCode=2") + prompt())
    #expect(events == [.postExec(command: "ls -la", exitCode: 2), .prompt])
    #expect(session.editBuffer()?.text == "")
  }

  @Test func preExecWithoutCommandFallsBackToTheScreen() {
    let session = makeSession()
    _ = session.feed(prompt() + "make test  ")
    _ = session.feed("\r\n" + osc("PreExec"))
    #expect(session.feed(osc("ExitCode=0") + prompt()) == [.postExec(command: "make test", exitCode: 0), .prompt])
  }

  @Test func promptRedrawWithoutCommandDoesNotReportPostExec() {
    let session = makeSession()
    _ = session.feed(prompt() + "abc")
    // Ctrl-C: the shell prints a new prompt without ever running anything.
    #expect(session.feed("^C\r\n" + prompt()) == [.prompt])
    #expect(session.editBuffer()?.text == "")
  }

  @Test func sequencesFromOtherSessionsAreIgnored() {
    let session = makeSession()
    _ = session.feed(prompt() + "ssh host")
    _ = session.feed("\r\n" + osc("PreExec=ssh host"))
    // The remote shell runs its own integration with a different session id.
    let foreign = osc("Shell=fish", session: "ffffffffffffffff") + osc("NewCmd", session: "ffffffffffffffff")
    #expect(session.feed(foreign + "remote$ ") == [])
    #expect(session.isExecuting)
    #expect(session.info.shell == "bash")
  }

  @Test func infoChangesAreReportedOnce() {
    let session = makeSession()
    _ = session.feed(prompt())
    #expect(session.feed(osc("Dir=/tmp") + osc("Shell=bash")) == [])
    #expect(session.feed(osc("Dir=/var") + osc("PID=42") + osc("User=me")) == [.infoChanged])
    #expect(session.info == ShellInfo(shell: "bash", pid: 42, cwd: "/var", user: "me"))
  }

  @Test func environmentIsReplacedAtomicallyAndOnlyReportedOnChange() {
    let session = makeSession()
    let snapshot = osc("EnvStart") + osc("Var=PATH=/bin:/usr/bin") + osc("Var=NOTE=a\\nb=c\\\\d") + osc("EnvEnd")
    #expect(session.feed(snapshot) == [.environmentChanged])
    #expect(session.environment == ["PATH": "/bin:/usr/bin", "NOTE": "a\nb=c\\d"])
    #expect(session.feed(snapshot) == [])
    #expect(session.feed(osc("EnvStart") + osc("Var=PATH=/bin") + osc("EnvEnd")) == [.environmentChanged])
    #expect(session.environment == ["PATH": "/bin"])
    #expect(session.feed(osc("Aliases=ll='ls -l'\\ngs='git status'")) == [.environmentChanged])
    #expect(session.aliases == "ll='ls -l'\ngs='git status'")
  }

  @Test func alternateScreenHasNoBuffer() {
    let session = makeSession()
    _ = session.feed(prompt() + "abc")
    _ = session.feed("\u{1b}[?1049h")
    #expect(session.editBuffer() == nil)
    _ = session.feed("\u{1b}[?1049l")
    #expect(session.editBuffer()?.text == "abc")
  }

  @Test func resizeInvalidatesUntilThePromptIsRedrawn() {
    let session = makeSession()
    _ = session.feed(prompt() + "abc")
    session.resize(columns: 30, rows: 6)
    #expect(session.editBuffer() == nil)
    _ = session.feed("\r\u{1b}[K" + prompt() + "abc")
    #expect(session.editBuffer()?.text == "abc")
  }
}

@Suite struct ScreenScrapingTests {
  @Test func readsTypedTextAndCursor() {
    let session = makeSession()
    _ = session.feed(prompt() + "git checkout")
    let buffer = session.editBuffer()
    #expect(buffer?.text == "git checkout")
    #expect(buffer?.cursor == 12)
    #expect(buffer?.cursorCell == GridPosition(row: 0, column: 14))
    #expect(buffer?.grid == GridSize(rows: 6, columns: 40))
  }

  @Test func keepsTrailingSpaceBeforeTheCursor() {
    let session = makeSession()
    _ = session.feed(prompt() + "cd ")
    #expect(session.editBuffer()?.text == "cd ")
    #expect(session.editBuffer()?.cursor == 3)
  }

  @Test func cursorInTheMiddle() {
    let session = makeSession()
    _ = session.feed(prompt() + "git status\u{1b}[7D")
    #expect(session.editBuffer()?.text == "git status")
    #expect(session.editBuffer()?.cursor == 3)
  }

  @Test func trailingSpacesAfterTheCursorAreDropped() {
    let session = makeSession()
    _ = session.feed(prompt() + "ls    \u{1b}[4D")
    #expect(session.editBuffer()?.text == "ls")
    #expect(session.editBuffer()?.cursor == 2)
  }

  @Test func softWrappedLineIsJoined() {
    let session = makeSession(columns: 10)
    _ = session.feed(prompt() + "echo one two three")
    #expect(session.editBuffer()?.text == "echo one two three")
    #expect(session.editBuffer()?.cursor == 18)
  }

  @Test func lineThatExactlyFillsTheRow() {
    let session = makeSession(columns: 10)
    _ = session.feed(prompt() + "12345678")
    #expect(session.editBuffer()?.text == "12345678")
    #expect(session.editBuffer()?.cursor == 8)
  }

  @Test func rightPromptIsExcluded() {
    let session = makeSession()
    let right = "\u{1b}[s\u{1b}[34G" + osc("StartPrompt") + "12:30" + osc("EndPrompt") + "\u{1b}[u"
    _ = session.feed(prompt() + right + "ls")
    #expect(session.editBuffer()?.text == "ls")
    #expect(session.editBuffer()?.cursor == 2)
  }

  @Test func continuationPromptBecomesANewline() {
    let session = makeSession()
    let ps2 = osc("StartPrompt") + "> " + osc("EndPrompt")
    _ = session.feed(prompt() + "echo \"a\r\n" + ps2 + "b")
    #expect(session.editBuffer()?.text == "echo \"a\nb")
    #expect(session.editBuffer()?.cursor == 9)
  }

  @Test func contentBelowTheCursorLineIsIgnored() {
    let session = makeSession()
    // A completion listing drawn under the prompt, with the cursor put back on the command line.
    _ = session.feed(prompt() + "git ch\u{1b}7\r\ncheckout  cherry-pick\u{1b}8")
    #expect(session.editBuffer()?.text == "git ch")
    #expect(session.editBuffer()?.cursor == 6)
  }

  @Test func ghostTextAfterTheCursorIsExcluded() {
    let session = makeSession()
    _ = session.feed(osc("FishSuggestionColor=555 brblack") + prompt(shell: "fish"))
    _ = session.feed("git \u{1b}[38;2;85;85;85mstatus --short\u{1b}[0m\u{1b}[14D")
    #expect(session.editBuffer()?.text == "git ")
    #expect(session.editBuffer()?.cursor == 4)
  }

  @Test func textInTheSuggestionColourBeforeTheCursorIsKept() {
    let session = makeSession()
    _ = session.feed(osc("ZshAutosuggestionColor=fg=8") + prompt(shell: "zsh"))
    _ = session.feed("\u{1b}[90m# note\u{1b}[0m x")
    #expect(session.editBuffer()?.text == "# note x")
  }

  @Test func wideAndCombiningCharactersCountInUTF16() {
    let session = makeSession()
    _ = session.feed(prompt() + "echo 漢e\u{301}🚀x\u{1b}[D")
    #expect(session.editBuffer()?.text == "echo 漢e\u{301}🚀x")
    // "echo " (5) + 漢 (1) + e + combining (2) + 🚀 (2 UTF-16 units)
    #expect(session.editBuffer()?.cursor == 10)
  }

  @Test func bufferSurvivesScrolling() {
    let session = makeSession(columns: 20, rows: 3)
    _ = session.feed("a\r\nb\r\n" + prompt() + "echo 1234567890123456789")
    #expect(session.editBuffer()?.text == "echo 1234567890123456789")
  }

  @Test func bufferScrolledOffScreenIsInvalid() {
    let session = makeSession(columns: 10, rows: 2)
    _ = session.feed(prompt() + String(repeating: "x", count: 30))
    #expect(session.editBuffer() == nil)
  }

  @Test func promptRedrawReanchors() {
    let session = makeSession()
    _ = session.feed(prompt("long-prompt$ ") + "abc")
    // Ctrl-L: clear and redraw with the same buffer.
    _ = session.feed("\u{1b}[H\u{1b}[2J" + prompt("$ ") + "abc")
    #expect(session.editBuffer()?.text == "abc")
    #expect(session.editBuffer()?.cursor == 3)
  }
}

@Suite struct ReportedBufferTests {
  @Test func reportedBufferWinsOverTheScreen() {
    let session = makeSession()
    _ = session.feed(prompt(shell: "zsh"))
    _ = session.feed("git st" + "\u{1b}[90matus\u{1b}[0m" + osc("Buffer=git st\\c"))
    let buffer = session.editBuffer()
    #expect(buffer?.text == "git st")
    #expect(buffer?.cursor == 6)
    #expect(buffer?.cursorCell.row == 0)
  }

  @Test func cursorMarkerInTheMiddleAndEscapes() {
    let session = makeSession()
    _ = session.feed(prompt(shell: "zsh"))
    _ = session.feed(osc("Buffer=echo 🚀\\c \"a\\\\b\\nc\""))
    #expect(session.editBuffer()?.text == "echo 🚀 \"a\\b\nc\"")
    #expect(session.editBuffer()?.cursor == 7)
  }

  @Test func reportIsDroppedAtTheNextCommandLine() {
    let session = makeSession()
    _ = session.feed(prompt(shell: "zsh") + "ls" + osc("Buffer=ls\\c"))
    _ = session.feed("\r\n" + osc("PreExec=ls") + "out\r\n" + osc("PreCmd") + prompt(shell: "zsh"))
    #expect(session.editBuffer()?.text == "")
  }

  @Test func reportIsDroppedAfterAnAbandonedLine() {
    let session = makeSession()
    _ = session.feed(prompt(shell: "zsh") + "abc" + osc("Buffer=abc\\c"))
    // Ctrl-C: no command ran, but a new command line begins.
    _ = session.feed("^C\r\n" + osc("PreCmd") + prompt(shell: "zsh"))
    #expect(session.editBuffer()?.text == "")
  }

  @Test func reportSurvivesAPromptRedraw() {
    let session = makeSession()
    _ = session.feed(prompt(shell: "zsh") + "abc" + osc("Buffer=ab\\cc"))
    // An asynchronous theme redraws the prompt in place while the user is typing.
    _ = session.feed("\r\u{1b}[K" + prompt(shell: "zsh") + "abc\u{08}")
    #expect(session.editBuffer()?.text == "abc")
    #expect(session.editBuffer()?.cursor == 2)
  }

  @Test func reportWhileExecutingIsIgnored() {
    let session = makeSession()
    _ = session.feed(prompt(shell: "zsh") + osc("PreExec=vared x") + osc("Buffer=inner\\c"))
    #expect(session.editBuffer() == nil)
  }
}

@Suite struct SuggestionStyleTests {
  @Test func zshStyles() {
    #expect(SuggestionStyle.zsh("fg=8").foregrounds == [.indexed(8)])
    #expect(SuggestionStyle.zsh("fg=#586e75,bold").foregrounds.contains(.rgb(0x58, 0x6e, 0x75)))
    #expect(SuggestionStyle.zsh("fg=cyan,bg=black") == SuggestionStyle(foregrounds: [.indexed(6)], backgrounds: [.indexed(0)]))
    #expect(SuggestionStyle.zsh("bold").isEmpty)
  }

  @Test func fishStyles() {
    let style = SuggestionStyle.fish("555 brblack --italics")
    #expect(style.foregrounds.contains(.rgb(0x55, 0x55, 0x55)))
    #expect(style.foregrounds.contains(.indexed(8)))
    #expect(style.foregrounds.contains(.indexed(240)))
    #expect(style.backgrounds.isEmpty)
    #expect(SuggestionStyle.fish("brblack --background=blue").backgrounds == [.indexed(4)])
  }

  @Test func matching() {
    var cell = CellStyle()
    #expect(!SuggestionStyle().matches(cell))
    cell.foreground = .indexed(8)
    #expect(SuggestionStyle.zsh("fg=8").matches(cell))
    cell.bold = true
    #expect(SuggestionStyle.zsh("fg=8").matches(cell))
    cell.foreground = .indexed(7)
    #expect(!SuggestionStyle.zsh("fg=8").matches(cell))
  }
}
