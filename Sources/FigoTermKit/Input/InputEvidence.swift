/// What a read from the terminal says about whether someone is typing in this tab.
///
/// Not everything a terminal sends is a key press. It also answers questions the shell asks it
/// (where the cursor is, what kind of terminal it is, what its colours are), and those answers
/// arrive in every tab, focused or not.
public enum InputEvidence: Equatable, Sendable {
  /// Keys, or a paste: the keyboard is here.
  case typing
  /// The terminal said this tab gained or lost the focus (`CSI I` / `CSI O`), which it does for
  /// programs that ask to be told.
  case focusGained
  case focusLost
  /// Only answers to queries, or mouse movement.
  case nothing

  /// Classifies input read by read. An answer can arrive in two reads; the unfinished part is
  /// kept and looked at together with what follows.
  public struct Tracker: Sendable {
    private var unfinished: [UInt8] = []
    /// An answer is short. Anything this long without an end is not one.
    private static let limit = 4096

    public init() {}

    public mutating func observe(_ input: [UInt8]) -> InputEvidence {
      // The quick way out for ordinary typing: one comparison.
      if unfinished.isEmpty, let first = input.first, first != 0x1b { return .typing }
      let bytes = unfinished + input
      let (evidence, consumed) = InputEvidence.scan(bytes)
      unfinished = consumed < bytes.count && bytes.count - consumed <= Self.limit ? Array(bytes[consumed...]) : []
      if consumed < bytes.count, unfinished.isEmpty { return .typing }
      return evidence
    }
  }

  /// One read on its own; an answer cut short at the end counts as typing.
  public static func of(_ input: [UInt8]) -> InputEvidence {
    let (evidence, consumed) = scan(input)
    return consumed < input.count ? .typing : evidence
  }

  /// The evidence in the complete sequences at the start of `input`, and how many bytes those
  /// take up. Anything that is not an answer is typing and consumes everything.
  private static func scan(_ input: [UInt8]) -> (InputEvidence, consumed: Int) {
    var evidence = InputEvidence.nothing
    var index = 0
    while index < input.count {
      guard input[index] == 0x1b else { return (.typing, input.count) }
      guard index + 1 < input.count else { return (evidence, index) }
      switch input[index + 1] {
      case 0x5b:  // CSI
        var cursor = index + 2
        // An old-style mouse report is `CSI M` and three raw bytes.
        if cursor < input.count, input[cursor] == 0x4d {
          guard cursor + 3 < input.count else { return (evidence, index) }
          index = cursor + 4
          continue
        }
        let parameters = cursor
        while cursor < input.count, (0x30...0x3f).contains(input[cursor]) { cursor += 1 }
        let isPrivate = cursor > parameters && (0x3c...0x3f).contains(input[parameters])
        while cursor < input.count, (0x20...0x2f).contains(input[cursor]) { cursor += 1 }
        guard cursor < input.count else { return (evidence, index) }
        switch input[cursor] {
        case 0x49 where cursor == parameters: evidence = .focusGained
        case 0x4f where cursor == parameters: evidence = .focusLost
        // Cursor position, device attributes, window size, mode reports.
        case 0x52, 0x63, 0x74, 0x79: break
        // `CSI ? … u` and friends are replies; `CSI < … M` is a mouse report.
        case _ where isPrivate: break
        default: return (.typing, input.count)
        }
        index = cursor + 1
      case 0x5d, 0x50, 0x5f, 0x5e:  // OSC, DCS, APC, PM: a reply that runs to BEL or `ESC \`
        var cursor = index + 2
        var ended = false
        while cursor < input.count {
          if input[cursor] == 0x07 {
            cursor += 1
            ended = true
            break
          }
          if input[cursor] == 0x1b, cursor + 1 < input.count, input[cursor + 1] == 0x5c {
            cursor += 2
            ended = true
            break
          }
          cursor += 1
        }
        guard ended else { return (evidence, index) }
        index = cursor
      default:
        return (.typing, input.count)
      }
    }
    return (evidence, index)
  }
}
