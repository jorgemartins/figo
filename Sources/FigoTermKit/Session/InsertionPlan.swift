/// Works out the bytes to type into the shell for an insertion the popup asked for.
public enum InsertionPlan {
  /// - Parameters:
  ///   - text: What the popup wants typed. It may contain 0x08 (delete backwards),
  ///     `ESC [ D` / `ESC [ C` (move the cursor) and `\n` (run the command).
  ///   - insertionBuffer: The command line the popup computed `text` against.
  ///   - currentBuffer: The command line as it is now.
  ///
  /// People keep typing while suggestions are computed. If the line has moved on since
  /// `insertionBuffer`, the extra characters are deleted first (or the missing ones retyped) so
  /// that `text` lands on the line it was meant for.
  public static func bytes(text: String, insertionBuffer: String?, currentBuffer: String?) -> [UInt8] {
    guard let typed = typeable(Array(text.utf8), mayRun: true) else { return [] }
    var output: [UInt8] = []

    if let expected = insertionBuffer, let current = currentBuffer, expected != current {
      if current.hasPrefix(expected) {
        // One backspace deletes one character as the user perceives it, not one byte.
        let extra = current.count - expected.count
        output.append(contentsOf: repeatElement(0x08, count: extra))
      } else if expected.hasPrefix(current) {
        guard let missing = typeable(Array(String(expected.dropFirst(current.count)).utf8), mayRun: false) else { return [] }
        output.append(contentsOf: missing)
      }
    }

    output.append(contentsOf: typed)
    return output
  }

  /// The bytes to type for `bytes`, or nil when they hold something that must not be typed.
  ///
  /// What may be typed on the popup's behalf is text, backspace, the two cursor movements, and
  /// one newline at the very end to run the command. The text comes from completion specs and
  /// from whatever they read: file names, branch names, script names. To a line editor a control
  /// character is a key press, so a file name holding a carriage return would run the first half
  /// of the line, and one holding ^U would clear it first. The page is meant never to ask for
  /// such an insertion; this is the second lock on that door. Nothing at all is typed then,
  /// because the text with the control characters taken out would be a different word.
  static func typeable(_ bytes: [UInt8], mayRun: Bool) -> [UInt8]? {
    var output: [UInt8] = []
    output.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      switch byte {
      case 0x08:
        output.append(byte)
      case 0x0a where mayRun && index == bytes.count - 1:
        // Line editors run the command on a carriage return, which is what the Return key sends.
        output.append(0x0d)
      case 0x1b:
        guard index + 2 < bytes.count, bytes[index + 1] == 0x5b, bytes[index + 2] == 0x43 || bytes[index + 2] == 0x44
        else { return nil }
        output.append(contentsOf: bytes[index...index + 2])
        index += 2
      case 0x00...0x1f, 0x7f:
        return nil
      case 0xc2 where index + 1 < bytes.count && (0x80...0x9f).contains(bytes[index + 1]):
        // U+0080 to U+009F, the second set of control characters.
        return nil
      default:
        output.append(byte)
      }
      index += 1
    }
    return output
  }
}
