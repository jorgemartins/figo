/// Removes Figo's private escape sequences from shell output before it reaches the terminal.
///
/// The shell integration talks to the wrapper through `ESC ] 6977 ; … BEL` sequences that carry,
/// among other things, the shell's environment. Terminals would ignore them, but there is no
/// reason for them to see them at all: stripping keeps secrets out of terminal logs and
/// recordings, and keeps an outer wrapper from reacting to a nested one.
///
/// Everything else is passed through byte for byte, including sequences split across reads.
public struct OutputFilter: Sendable {
  private enum State: Sendable {
    case text
    /// An ESC was seen and is being held back.
    case escape
    /// `ESC ]` plus this many bytes of the marker have matched and are being held back.
    case marker(Int)
    /// Inside one of our sequences: discard up to the terminator.
    case discarding
    /// Inside one of our sequences, right after an ESC that may start the `ESC \` terminator.
    case discardingEscape
  }

  private static let marker = Array("\(ShellSession.oscNumber);".utf8)
  private var state = State.text

  public init() {}

  /// Appends to `output` the bytes of `input` that the terminal should receive.
  public mutating func filter(_ input: UnsafeBufferPointer<UInt8>, into output: inout [UInt8]) {
    var index = 0
    let count = input.count
    while index < count {
      let byte = input[index]
      switch state {
      case .text:
        // Copy the run up to the next ESC in one go; this is the path almost every byte takes.
        var end = index
        while end < count && input[end] != 0x1b { end += 1 }
        output.append(contentsOf: UnsafeBufferPointer(rebasing: input[index..<end]))
        if end < count {
          state = .escape
          end += 1
        }
        index = end
        continue

      case .escape:
        if byte == 0x5d { // ]
          state = .marker(0)
        } else if byte == 0x1b {
          output.append(0x1b)
        } else {
          output.append(0x1b)
          output.append(byte)
          state = .text
        }

      case .marker(let matched):
        if byte == Self.marker[matched] {
          state = matched + 1 == Self.marker.count ? .discarding : .marker(matched + 1)
        } else {
          // Someone else's sequence: release what was held back and look at this byte afresh.
          output.append(0x1b)
          output.append(0x5d)
          output.append(contentsOf: Self.marker[..<matched])
          state = .text
          continue
        }

      case .discarding:
        if byte == 0x07 {
          state = .text
        } else if byte == 0x1b {
          state = .discardingEscape
        } else if byte == 0x18 || byte == 0x1a {
          // CAN and SUB abort a sequence without being part of it.
          output.append(byte)
          state = .text
        }

      case .discardingEscape:
        if byte == 0x5c { // \
          state = .text
        } else {
          // The ESC ended our sequence and begins a new one that is not ours to drop.
          state = .escape
          continue
        }
      }
      index += 1
    }
  }

  public mutating func filter(_ input: [UInt8]) -> [UInt8] {
    var output: [UInt8] = []
    input.withUnsafeBufferPointer { filter($0, into: &output) }
    return output
  }
}
