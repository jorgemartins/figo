/// The rendition a shell uses for its own autosuggestion ("ghost text"), so that text can be
/// told apart from what the user actually typed.
public struct SuggestionStyle: Equatable, Sendable {
  /// Any of these foregrounds counts as a match. Empty means the foreground is not constrained.
  public var foregrounds: [TerminalColor] = []
  public var backgrounds: [TerminalColor] = []

  public var isEmpty: Bool { foregrounds.isEmpty && backgrounds.isEmpty }

  public func matches(_ style: CellStyle) -> Bool {
    guard !isEmpty else { return false }
    if !foregrounds.isEmpty && !foregrounds.contains(style.foreground) { return false }
    if !backgrounds.isEmpty && !backgrounds.contains(style.background) { return false }
    return true
  }

  /// Parses zsh `region_highlight` syntax as used by `ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE`,
  /// e.g. `fg=8`, `fg=#586e75,bold` or `fg=cyan,bg=black`.
  public static func zsh(_ spec: String) -> SuggestionStyle {
    var style = SuggestionStyle()
    for part in spec.split(separator: ",") {
      let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
      guard pair.count == 2 else { continue }
      let colors = color(named: pair[1])
      switch pair[0] {
      case "fg": style.foregrounds += colors
      case "bg": style.backgrounds += colors
      default: break
      }
    }
    return style
  }

  /// Parses a fish colour variable such as `fish_color_autosuggestion`, e.g. `555 brblack` or
  /// `brblack --italics`. fish uses the first colour the terminal supports, so every candidate
  /// is accepted.
  public static func fish(_ spec: String) -> SuggestionStyle {
    var style = SuggestionStyle()
    var expectsBackground = false
    for token in spec.split(separator: " ").map(String.init) {
      if expectsBackground {
        style.backgrounds += color(named: token)
        expectsBackground = false
      } else if token == "-b" {
        expectsBackground = true
      } else if token.hasPrefix("--background=") {
        style.backgrounds += color(named: String(token.dropFirst("--background=".count)))
      } else if !token.hasPrefix("-") {
        style.foregrounds += color(named: token)
      }
    }
    return style
  }

  private static let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

  /// Every way a terminal might be asked to draw the named colour.
  private static func color(named name: String) -> [TerminalColor] {
    let name = name.lowercased()
    if name == "normal" || name == "default" { return [.default] }
    if let index = names.firstIndex(of: name) { return [.indexed(UInt8(index))] }
    if name.hasPrefix("br"), let index = names.firstIndex(of: String(name.dropFirst(2))) {
      return [.indexed(UInt8(index + 8))]
    }
    if name == "grey" || name == "gray" { return [.indexed(8)] }
    // zsh writes palette indexes as plain numbers; fish writes hex without the leading #.
    let isZshHex = name.hasPrefix("#")
    let digits = isZshHex ? String(name.dropFirst()) : name
    if !isZshHex, let index = UInt8(name) {
      // "555" is ambiguous: palette entries stop at 255, so this is only reached for 0...255.
      // fish would read e.g. "100" as hex, so offer both readings.
      return [.indexed(index)] + (rgb(hex: digits).map(variants) ?? [])
    }
    return rgb(hex: digits).map(variants) ?? []
  }

  private static func rgb(hex: String) -> (UInt8, UInt8, UInt8)? {
    let scalars = Array(hex.unicodeScalars)
    guard scalars.count == 3 || scalars.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    if scalars.count == 3 {
      let r = UInt8((value >> 8) & 0xf), g = UInt8((value >> 4) & 0xf), b = UInt8(value & 0xf)
      return (r * 17, g * 17, b * 17)
    }
    return (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
  }

  /// A true-colour value plus the 256-colour palette entry a shell falls back to when the
  /// terminal does not advertise true colour.
  private static func variants(_ rgb: (UInt8, UInt8, UInt8)) -> [TerminalColor] {
    [.rgb(rgb.0, rgb.1, rgb.2), .indexed(nearestPaletteIndex(rgb))]
  }

  private static func nearestPaletteIndex(_ rgb: (UInt8, UInt8, UInt8)) -> UInt8 {
    let levels = [0, 95, 135, 175, 215, 255]
    func distance(_ a: (Int, Int, Int)) -> Int {
      let dr = a.0 - Int(rgb.0), dg = a.1 - Int(rgb.1), db = a.2 - Int(rgb.2)
      return dr * dr + dg * dg + db * db
    }
    var best = (index: 16, distance: Int.max)
    for index in 16..<232 {
      let offset = index - 16
      let candidate = (levels[offset / 36], levels[(offset / 6) % 6], levels[offset % 6])
      let d = distance(candidate)
      if d < best.distance { best = (index, d) }
    }
    for index in 232..<256 {
      let level = 8 + (index - 232) * 10
      let d = distance((level, level, level))
      if d < best.distance { best = (index, d) }
    }
    return UInt8(best.index)
  }
}
