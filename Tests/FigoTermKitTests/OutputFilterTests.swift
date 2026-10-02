import Testing

@testable import FigoTermKit

private func filtered(_ chunks: String...) -> String {
  var filter = OutputFilter()
  var output: [UInt8] = []
  for chunk in chunks {
    output += filter.filter(Array(chunk.utf8))
  }
  return String(decoding: output, as: UTF8.self)
}

@Suite struct OutputFilterTests {
  @Test func plainOutputIsUntouched() {
    #expect(filtered("hello\r\n\u{1b}[31mred\u{1b}[0m") == "hello\r\n\u{1b}[31mred\u{1b}[0m")
  }

  @Test func privateSequencesAreRemoved() {
    #expect(filtered("a\u{1b}]6977;abc;StartPrompt\u{07}$ \u{1b}]6977;abc;NewCmd\u{07}b") == "a$ b")
  }

  @Test func stringTerminatorFormIsRemoved() {
    #expect(filtered("a\u{1b}]6977;abc;Dir=/tmp\u{1b}\\b") == "ab")
  }

  @Test func otherOperatingSystemCommandsPass() {
    let title = "\u{1b}]0;my title\u{07}"
    let similar = "\u{1b}]697;NewCmd\u{07}\u{1b}]69770;x\u{07}\u{1b}]6;x\u{07}"
    #expect(filtered(title + similar) == title + similar)
  }

  @Test func sequencesSplitAnywhereAcrossReads() {
    let input = "x\u{1b}]6977;abc;Var=SECRET=hunter2\u{07}y\u{1b}]0;t\u{07}z\u{1b}[1m"
    let expected = "xy\u{1b}]0;t\u{07}z\u{1b}[1m"
    let bytes = Array(input.utf8)
    for split in 0...bytes.count {
      var filter = OutputFilter()
      let output = filter.filter(Array(bytes[..<split])) + filter.filter(Array(bytes[split...]))
      #expect(String(decoding: output, as: UTF8.self) == expected, "split at \(split)")
    }
  }

  @Test func escapeInsideOurSequenceStartsTheNextOne() {
    #expect(filtered("\u{1b}]6977;abc;Dir=/x\u{1b}[31mred") == "\u{1b}[31mred")
  }

  @Test func doubleEscapeIsPreserved() {
    #expect(filtered("\u{1b}\u{1b}[A") == "\u{1b}\u{1b}[A")
  }

  @Test func holdsBackOnlyWhatIsUndecided() {
    var filter = OutputFilter()
    #expect(filter.filter(Array("abc\u{1b}".utf8)) == Array("abc".utf8))
    #expect(filter.filter(Array("[0m".utf8)) == Array("\u{1b}[0m".utf8))
  }
}

@Suite struct InsertionPlanTests {
  private func plan(_ text: String, _ expected: String?, _ current: String?) -> String {
    String(decoding: InsertionPlan.bytes(text: text, insertionBuffer: expected, currentBuffer: current), as: UTF8.self)
  }

  @Test func plainInsertion() {
    #expect(plan("tes/", "cd Si", "cd Si") == "tes/")
    #expect(plan("x", nil, "anything") == "x")
    #expect(plan("x", "abc", nil) == "x")
  }

  @Test func newlineBecomesReturn() {
    #expect(plan("status\n", "git ", "git ") == "status\r")
  }

  @Test func deletesWhatWasTypedSinceTheSuggestionWasComputed() {
    #expect(plan("\u{08}\u{08}Sites/", "cd si", "cd sit") == "\u{08}\u{08}\u{08}Sites/")
    #expect(plan("x", "é", "é🚀e\u{301}") == "\u{08}\u{08}x")
  }

  @Test func retypesWhatWasDeleted() {
    #expect(plan("x", "git che", "git c") == "hex")
  }

  @Test func divergedBuffersAreLeftAlone() {
    #expect(plan("x", "git a", "git b") == "x")
  }
}
