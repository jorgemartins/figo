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

  @Test func bracketedPasteIsOneToken() {
    var parser = KeyParser()
    let input = "\u{1b}[200~ls\r\nrm -rf\u{1b}[201~x"
    let tokens = parser.parse(Array(input.utf8), flush: false)
    #expect(tokens.map(\.key) == [nil, "x"])
    #expect(tokens[0].bytes.count == input.utf8.count - 1)
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
