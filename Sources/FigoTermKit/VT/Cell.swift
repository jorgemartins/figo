/// A terminal colour as selected by SGR.
public enum TerminalColor: Equatable, Sendable {
  case `default`
  case indexed(UInt8)
  case rgb(UInt8, UInt8, UInt8)
}

/// Rendition attributes that matter for recognising what a shell drew.
public struct CellStyle: Equatable, Sendable {
  public var foreground = TerminalColor.default
  public var background = TerminalColor.default
  public var bold = false
  public var dim = false
  public var italic = false
  public var underline = false
  public var inverse = false
  public var hidden = false

  public init() {}
}

/// Where a cell's content came from, according to the shell integration markers that were
/// active when it was printed.
public struct CellOrigin: OptionSet, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  /// Drawn as part of the prompt (PS1, PS2 or a right prompt).
  public static let prompt = CellOrigin(rawValue: 1 << 0)
}

/// One character position on the screen.
///
/// Deliberately a plain value with no references: every byte of shell output ends up in one of
/// these, so copying and clearing them has to be as cheap as copying an integer. The rare
/// combining marks live in a side table on the screen instead.
public struct Cell: Equatable, Sendable {
  /// 0 for a cell nothing was printed to.
  public var scalar: UInt32 = 0
  /// 1 for normal cells, 2 for the leading half of a wide character, 0 for its trailing half.
  public var width: UInt8 = 1
  public var origin = CellOrigin()
  public var style = CellStyle()

  public static let blank = Cell()

  public var isBlank: Bool { scalar == 0 && width == 1 }
}

/// How many columns a character occupies. Deliberately small: it only has to agree with the
/// terminal for the characters that realistically appear on a command line.
func columnWidth(of scalar: Unicode.Scalar) -> Int {
  let value = scalar.value
  if value < 0x300 { return 1 }

  switch scalar.properties.generalCategory {
  case .nonspacingMark, .enclosingMark, .format:
    return 0
  default:
    break
  }
  if (0xfe00...0xfe0f).contains(value) || (0xe0100...0xe01ef).contains(value) { return 0 }

  switch value {
  case 0x1100...0x115f, 0x2329...0x232a, 0x2e80...0x303e, 0x3041...0x33ff, 0x3400...0x4dbf,
    0x4e00...0x9fff, 0xa000...0xa4cf, 0xa960...0xa97f, 0xac00...0xd7a3, 0xf900...0xfaff,
    0xfe30...0xfe4f, 0xff00...0xff60, 0xffe0...0xffe6, 0x1f300...0x1f64f, 0x1f680...0x1f6ff,
    0x1f900...0x1f9ff, 0x1fa70...0x1faff, 0x20000...0x3fffd:
    return 2
  default:
    return scalar.properties.isEmojiPresentation ? 2 : 1
  }
}
