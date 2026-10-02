import Testing

@testable import FigoTermKit

/// Records parser events as readable strings.
struct EventLog: VTHandler {
  var events: [String] = []

  mutating func print(_ scalar: Unicode.Scalar) {
    if let last = events.last, last.hasPrefix("print:") {
      events[events.count - 1] = last + String(scalar)
    } else {
      events.append("print:" + String(scalar))
    }
  }

  mutating func execute(_ byte: UInt8) {
    events.append("exec:\(byte)")
  }

  mutating func csiDispatch(params: VTParams, prefix: UInt8, intermediates: [UInt8], final: UInt8) {
    let rendered = zip(params.values, params.isSub).map { ($1 ? ":" : ";") + String($0) }.joined()
    let marker = prefix == 0 ? "" : String(UnicodeScalar(prefix))
    let inter = String(decoding: intermediates, as: UTF8.self)
    events.append("csi:\(marker)\(rendered.dropFirst())\(inter)\(UnicodeScalar(final))")
  }

  mutating func escDispatch(intermediates: [UInt8], final: UInt8) {
    events.append("esc:\(String(decoding: intermediates, as: UTF8.self))\(UnicodeScalar(final))")
  }

  mutating func oscDispatch(_ payload: [UInt8]) {
    events.append("osc:" + String(decoding: payload, as: UTF8.self))
  }
}

private func parse(_ chunks: String...) -> [String] {
  var parser = VTParser()
  var log = EventLog()
  for chunk in chunks {
    parser.feed(Array(chunk.utf8), handler: &log)
  }
  return log.events
}

@Suite struct VTParserTests {
  @Test func plainText() {
    #expect(parse("hello") == ["print:hello"])
  }

  @Test func controlCharacters() {
    #expect(parse("a\r\nb\u{08}") == ["print:a", "exec:13", "exec:10", "print:b", "exec:8"])
  }

  @Test func csiWithParameters() {
    #expect(parse("\u{1b}[1;31mx") == ["csi:1;31m", "print:x"])
    #expect(parse("\u{1b}[H") == ["csi:H"])
    #expect(parse("\u{1b}[;5H") == ["csi:0;5H"])
  }

  @Test func csiPrivateAndIntermediate() {
    #expect(parse("\u{1b}[?1049h") == ["csi:?1049h"])
    #expect(parse("\u{1b}[2 q") == ["csi:2 q"])
    #expect(parse("\u{1b}[>4;2m") == ["csi:>4;2m"])
  }

  @Test func csiSubParameters() {
    #expect(parse("\u{1b}[38:2:10:20:30m") == ["csi:38:2:10:20:30m"])
    #expect(parse("\u{1b}[4:3;1m") == ["csi:4:3;1m"])
  }

  @Test func escapeSequences() {
    #expect(parse("\u{1b}7\u{1b}8\u{1b}(B\u{1b}M") == ["esc:7", "esc:8", "esc:(B", "esc:M"])
  }

  @Test func oscTerminatedByBellOrST() {
    #expect(parse("\u{1b}]0;title\u{07}x") == ["osc:0;title", "print:x"])
    #expect(parse("\u{1b}]697;NewCmd=abc\u{1b}\\x") == ["osc:697;NewCmd=abc", "esc:\\", "print:x"])
  }

  @Test func oscKeepsUTF8AndEquals() {
    #expect(parse("\u{1b}]697;Dir=/tmp/caf\u{e9}=x\u{07}") == ["osc:697;Dir=/tmp/caf\u{e9}=x"])
  }

  @Test func sequencesSplitAcrossReads() {
    #expect(parse("\u{1b}", "[3", "1", "mred") == ["csi:31m", "print:red"])
    #expect(parse("\u{1b}]697;Start", "Prompt\u{07}") == ["osc:697;StartPrompt"])
  }

  @Test func utf8SplitAcrossReads() {
    var parser = VTParser()
    var log = EventLog()
    let bytes = Array("é漢🚀".utf8)
    for byte in bytes {
      parser.feed([byte], handler: &log)
    }
    #expect(log.events == ["print:é漢🚀"])
  }

  @Test func invalidUTF8BecomesReplacementCharacter() {
    var parser = VTParser()
    var log = EventLog()
    parser.feed([0x61, 0xff, 0x62, 0xe2, 0x82, 0x63], handler: &log)
    #expect(log.events == ["print:a\u{FFFD}b\u{FFFD}c"])
  }

  @Test func deviceControlStringsAreSwallowed() {
    #expect(parse("a\u{1b}P1$r0m\u{1b}\\b") == ["print:a", "esc:\\", "print:b"])
    #expect(parse("a\u{1b}_Gf=100;payload\u{1b}\\b") == ["print:a", "esc:\\", "print:b"])
  }

  @Test func cancelAbortsSequence() {
    #expect(parse("\u{1b}[12\u{18}x") == ["print:x"])
  }

  @Test func controlInsideCSIIsExecuted() {
    #expect(parse("\u{1b}[1\r;2H") == ["exec:13", "csi:1;2H"])
  }

  @Test func oversizedOSCIsDropped() {
    let big = String(repeating: "a", count: VTParser.maxOSCLength + 10)
    #expect(parse("\u{1b}]52;c;\(big)\u{07}ok") == ["print:ok"])
  }
}
