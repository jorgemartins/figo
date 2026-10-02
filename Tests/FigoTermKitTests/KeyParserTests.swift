import FigoCore
import Testing

@testable import FigoTermKit

private func keys(_ input: String, flush: Bool = true) -> [String?] {
  var parser = KeyParser()
  return parser.parse(Array(input.utf8), flush: flush).map(\.key)
}

@Suite struct KeyParserTests {
  @Test func plainCharacters() {
    #expect(keys("aZ? é🚀") == ["a", "Z", "?", "space", "é", "🚀"])
  }

  @Test func controlCharacters() {
    #expect(keys("\r\t\u{7f}\u{08}") == ["enter", "tab", "backspace", "backspace"])
    #expect(keys("\u{0b}\u{10}\u{0e}\u{03}\u{0a}") == ["control+k", "control+p", "control+n", "control+c", "control+j"])
    #expect(keys("\u{00}") == ["control+space"])
  }

  @Test func arrowsInBothCursorModes() {
    #expect(keys("\u{1b}[A\u{1b}[B\u{1b}[C\u{1b}[D") == ["up", "down", "right", "left"])
    #expect(keys("\u{1b}OA\u{1b}OB") == ["up", "down"])
    #expect(keys("\u{1b}[1;5A\u{1b}[1;2B") == ["control+up", "shift+down"])
  }

  @Test func editingKeys() {
    #expect(keys("\u{1b}[Z") == ["shift+tab"])
    #expect(keys("\u{1b}[3~\u{1b}[5~\u{1b}[H\u{1b}[F") == ["delete", "pageup", "home", "end"])
    #expect(keys("\u{1b}[15~\u{1b}OP") == ["f5", "f1"])
  }

  @Test func escapeAloneIsOnlyDecidedOnFlush() {
    var parser = KeyParser()
    #expect(parser.parse([0x1b], flush: false).isEmpty)
    #expect(parser.hasPending)
    #expect(parser.parse([], flush: true).map(\.key) == ["esc"])
    #expect(!parser.hasPending)
  }

  @Test func escapeSequenceSplitAcrossReads() {
    var parser = KeyParser()
    #expect(parser.parse([0x1b], flush: false).isEmpty)
    #expect(parser.parse(Array("[A".utf8), flush: false).map(\.key) == ["up"])
  }

  @Test func optionCombinations() {
    #expect(keys("\u{1b}b\u{1b}\u{7f}\u{1b}\r") == ["option+b", "option+backspace", "option+enter"])
  }

  @Test func doubleEscape() {
    #expect(keys("\u{1b}\u{1b}") == ["esc", "esc"])
  }

  @Test func kittyProtocolKeys() {
    #expect(keys("\u{1b}[27u") == ["esc"])
    #expect(keys("\u{1b}[107;5u") == ["control+k"])
    #expect(keys("\u{1b}[13;2u\u{1b}[9;2u") == ["shift+enter", "shift+tab"])
    #expect(keys("\u{1b}[97;2u") == ["A"])
    #expect(keys("\u{1b}[105;9u") == ["command+i"])
    #expect(keys("\u{1b}[97:65;2u") == ["A"])
    // Key release events are not presses.
    #expect(keys("\u{1b}[97;1:3u") == [nil])
  }

  @Test func modifyOtherKeys() {
    #expect(keys("\u{1b}[27;5;107~") == ["control+k"])
  }

  @Test func nonKeysPassThroughWhole() {
    var parser = KeyParser()
    let input = "\u{1b}[<0;10;5M\u{1b}[?62;c\u{1b}]11;rgb:0000/0000/0000\u{1b}\\\u{1b}[I"
    let tokens = parser.parse(Array(input.utf8), flush: true)
    #expect(tokens.map(\.key) == [nil, nil, nil, nil])
    #expect(tokens.flatMap(\.bytes) == Array(input.utf8))
  }

  @Test func nothingInsideABracketedPasteIsAKey() {
    var parser = KeyParser()
    let input = "\u{1b}[200~ls\r\nrm -rf\t\u{1b}[201~x"
    let tokens = parser.parse(Array(input.utf8), flush: false)
    #expect(tokens.compactMap(\.key) == ["x"])
    #expect(tokens.flatMap(\.bytes) == Array(input.utf8))
    #expect(!parser.isInPaste)
  }

  @Test func aPasteStaysAPasteHoweverItArrives() {
    // In pieces of any size, with pauses in the middle of it (the caller flushes after a
    // pause), and with the markers split across reads.
    let paste = "\u{1b}[200~" + String(repeating: "line one\r\tline two\r", count: 600) + "\u{1b}[201~"
    let bytes = Array(paste.utf8) + Array("\r".utf8)
    for chunk in [1, 5, 1000, 4096] {
      var parser = KeyParser()
      var tokens: [InputToken] = []
      var offset = 0
      while offset < bytes.count {
        let end = min(offset + chunk, bytes.count)
        tokens += parser.parse(Array(bytes[offset..<end]), flush: false)
        if parser.isInPaste { tokens += parser.parse([], flush: true) }
        offset = end
      }
      #expect(tokens.compactMap(\.key) == ["enter"], "chunks of \(chunk)")
      #expect(tokens.flatMap(\.bytes) == bytes, "chunks of \(chunk)")
      #expect(!parser.hasPending)
    }
  }

  @Test func aPasteThatBeganBeforeParsingStartedIsStillAPaste() {
    var parser = KeyParser()
    parser.observe(Array("ls \u{1b}[200~first".utf8))
    #expect(parser.isInPaste)
    let tokens = parser.parse(Array(" half\rsecond half\u{1b}[201~\t".utf8), flush: true)
    #expect(tokens.compactMap(\.key) == ["tab"])
    parser.observe(Array("\u{1b}[200~unfinished".utf8))
    parser.endPaste()
    #expect(parser.parse([0x0d], flush: true).map(\.key) == ["enter"])
  }

  @Test func aPasteMarkerSplitBetweenObservingAndParsingIsStillOne() {
    let marker = Array("\u{1b}[200~".utf8)
    let rest = Array("pasted\ttext\r\u{1b}[201~".utf8)
    for split in 1..<marker.count {
      // The start of the marker passes by unparsed, then parsing begins.
      var parser = KeyParser()
      parser.observe(Array(marker[..<split]))
      var tokens = parser.parse(Array(marker[split...]) + rest, flush: false)
      tokens += parser.parse([0x09], flush: true)
      #expect(tokens.compactMap(\.key) == ["tab"], "observed \(split) bytes")
      #expect(tokens.flatMap(\.bytes) == Array(marker[split...]) + rest + [0x09], "observed \(split) bytes")

      // The other way round: parsing stops with the start of the marker held back.
      guard split > 1 else { continue }
      var stopping = KeyParser()
      var held = stopping.parse(Array(marker[..<split]), flush: false)
      held += stopping.parse([], flush: true)
      #expect(held.flatMap(\.bytes) == Array(marker[..<split]))
      stopping.observe(Array(marker[split...]) + Array("pasted".utf8))
      #expect(stopping.isInPaste, "parsed \(split) bytes")
    }
    // An Escape that was pressed long ago does not swallow the next key.
    var parser = KeyParser()
    parser.observe([0x1b])
    #expect(parser.parse([0x0d], flush: true).map(\.key) == ["enter"])
  }

  @Test func tellsTypingFromWhatTheTerminalSendsOnItsOwn() {
    func evidence(_ text: String) -> InputEvidence { InputEvidence.of(Array(text.utf8)) }
    #expect(evidence("a") == .typing)
    #expect(evidence("\r") == .typing)
    #expect(evidence("\u{1b}") == .typing)
    #expect(evidence("\u{1b}[A") == .typing)
    #expect(evidence("\u{1b}[1;5C") == .typing)
    #expect(evidence("\u{1b}[97;5u") == .typing)
    #expect(evidence("\u{1b}[200~pasted\u{1b}[201~") == .typing)
    #expect(evidence("\u{1b}f") == .typing)
    // Answers to the shell's queries: cursor position, device attributes, keyboard flags,
    // colours, mode reports. And the mouse.
    #expect(evidence("\u{1b}[24;1R") == .nothing)
    #expect(evidence("\u{1b}[?62;22c\u{1b}[?0u\u{1b}[?2026;2$y") == .nothing)
    #expect(evidence("\u{1b}]11;rgb:0000/0000/0000\u{1b}\\\u{1b}]10;rgb:ffff/ffff/ffff\u{07}") == .nothing)
    #expect(evidence("\u{1b}P1+r544e\u{1b}\\") == .nothing)
    #expect(evidence("\u{1b}[<0;10;5M\u{1b}[<0;10;5m") == .nothing)
    #expect(evidence("") == .nothing)
    // A reply followed by a key is still typing.
    #expect(evidence("\u{1b}[24;1Rx") == .typing)
    // Focus reports, for programs that ask for them.
    #expect(evidence("\u{1b}[I") == .focusGained)
    #expect(evidence("\u{1b}[24;1R\u{1b}[O") == .focusLost)
  }

  @Test func anAnswerThatArrivesInPiecesIsStillAnAnswer() {
    for reply in ["\u{1b}[24;1R", "\u{1b}[?62;22c", "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\", "\u{1b}[M !!", "\u{1b}[O"] {
      let bytes = Array(reply.utf8)
      for split in 1..<bytes.count {
        var tracker = InputEvidence.Tracker()
        let first = tracker.observe(Array(bytes[..<split]))
        let second = tracker.observe(Array(bytes[split...]))
        #expect(first == .nothing, "\(reply.dropFirst()) cut at \(split)")
        #expect(second == (reply.hasSuffix("[O") ? .focusLost : .nothing), "\(reply.dropFirst()) cut at \(split)")
      }
    }
    // Typing is still seen at once, also right after an answer or an Escape.
    var tracker = InputEvidence.Tracker()
    #expect(tracker.observe(Array("l".utf8)) == .typing)
    #expect(tracker.observe(Array("\u{1b}[24;".utf8)) == .nothing)
    #expect(tracker.observe(Array("1Rs".utf8)) == .typing)
    #expect(tracker.observe([0x1b]) == .nothing)
    #expect(tracker.observe(Array("b".utf8)) == .typing)
  }

  @Test func absurdCodePointsAreNotKeys() {
    var parser = KeyParser()
    for input in ["\u{1b}[4294967296u", "\u{1b}[27;5;9999999999~", "\u{1b}[99999999999999999999u"] {
      let tokens = parser.parse(Array(input.utf8), flush: true)
      #expect(tokens.allSatisfy { $0.key == nil }, "\(input.dropFirst())")
      #expect(tokens.flatMap(\.bytes) == Array(input.utf8))
    }
  }

  @Test func bytesAreAlwaysPreserved() {
    var parser = KeyParser()
    let input: [UInt8] = [0x61, 0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x41, 0xff, 0xc3, 0xa9, 0x1b, 0x5b, 0x39, 0x39]
    let tokens = parser.parse(input, flush: true)
    #expect(tokens.flatMap(\.bytes) == input)
  }

  @Test func normalizesBindings() {
    #expect(KeyName.normalize("Ctrl+K") == "control+k")
    #expect(KeyName.normalize("control+k") == "control+k")
    #expect(KeyName.normalize("shift+tab") == "shift+tab")
    #expect(KeyName.normalize("alt+arrowup") == "option+up")
    #expect(KeyName.normalize("command+i") == "command+i")
    #expect(KeyName.normalize("shift+a") == "A")
    #expect(KeyName.normalize("Enter") == "enter")
    #expect(KeyName.normalize("escape") == "esc")
    #expect(KeyName.normalize("shift+ctrl+x") == "control+shift+x")
    #expect(KeyName.normalize("control++") == "control++")
  }
}

@Suite struct InterceptorTests {
  private let bindings = [
    "enter": "insertSelected", "tab": "insertCommonPrefix", "esc": "hideAutocomplete", "up": "navigateUp",
    "ctrl+k": "toggleDescription", "control+r": "ignore", "option+space": "showAutocomplete",
  ]

  @Test func inactiveByDefault() {
    var interceptor = Interceptor()
    #expect(interceptor.action(for: "enter") == nil)
  }

  @Test func boundKeysAreInterceptedWhileVisible() {
    var interceptor = Interceptor()
    interceptor.apply(InterceptConfiguration(interceptBound: true, interceptGlobal: true, bindings: bindings))
    #expect(interceptor.action(for: "enter") == "insertSelected")
    #expect(interceptor.action(for: "control+k") == "toggleDescription")
    #expect(interceptor.action(for: "a") == nil)
    #expect(interceptor.action(for: "control+r") == nil)
  }

  @Test func onlyGlobalActionsWhileHidden() {
    var interceptor = Interceptor()
    interceptor.apply(InterceptConfiguration(interceptBound: false, interceptGlobal: true, bindings: bindings))
    #expect(interceptor.action(for: "enter") == nil)
    #expect(interceptor.action(for: "option+space") == "showAutocomplete")
  }

  @Test func escapeStopsInterceptingImmediately() {
    var interceptor = Interceptor()
    interceptor.apply(InterceptConfiguration(interceptBound: true, interceptGlobal: true, bindings: bindings))
    #expect(interceptor.action(for: "esc") == "hideAutocomplete")
    #expect(interceptor.action(for: "enter") == nil)
    #expect(interceptor.action(for: "option+space") == "showAutocomplete")
  }

  @Test func interruptResets() {
    var interceptor = Interceptor()
    interceptor.apply(InterceptConfiguration(interceptBound: true, interceptGlobal: true, bindings: bindings))
    #expect(interceptor.action(for: "control+c") == nil)
    #expect(!interceptor.isActive)
    #expect(interceptor.action(for: "enter") == nil)
  }
}
