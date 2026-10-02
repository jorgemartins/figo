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
    var output: [UInt8] = []

    if let expected = insertionBuffer, let current = currentBuffer, expected != current {
      if current.hasPrefix(expected) {
        // One backspace deletes one character as the user perceives it, not one byte.
        let extra = current.count - expected.count
        output.append(contentsOf: repeatElement(0x08, count: extra))
      } else if expected.hasPrefix(current) {
        output.append(contentsOf: expected.dropFirst(current.count).utf8)
      }
    }

    // Line editors run the command on a carriage return, which is what the Return key sends.
    for byte in text.utf8 {
      output.append(byte == 0x0a ? 0x0d : byte)
    }
    return output
  }
}
