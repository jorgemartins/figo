/// One unit of terminal input: a key press, or bytes that are not a key (pastes, mouse reports,
/// replies to terminal queries) and are only ever forwarded.
public struct InputToken: Equatable, Sendable {
  /// The bytes exactly as received, which is what the shell gets if the key is not intercepted.
  public var bytes: [UInt8]
  /// The key in binding notation (see `KeyName`), or nil when this is not a key press.
  public var key: String?

  public init(bytes: [UInt8], key: String?) {
    self.bytes = bytes
    self.key = key
  }
}

/// The notation keys are written in, both in settings and on the wire:
/// `[control+][option+][shift+][command+]<key>`, where `<key>` is a name such as `enter`, `tab`,
/// `esc`, `up`, `f5`, or a single character. Letters combined with control or option are
/// lowercase; shift plus a letter is written as the uppercase letter.
public enum KeyName {
  private static let aliases: [String: String] = [
    "ctrl": "control", "alt": "option", "opt": "option", "meta": "command", "cmd": "command",
    "super": "command", "return": "enter", "escape": "esc", "arrowup": "up", "arrowdown": "down",
    "arrowleft": "left", "arrowright": "right", "del": "delete", "ins": "insert", "pgup": "pageup",
    "pgdn": "pagedown", "pgdown": "pagedown", "spacebar": "space",
  ]
  private static let modifierOrder = ["control", "option", "shift", "command"]

  static func compose(control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = false, key: String)
    -> String
  {
    var key = key
    var shift = shift
    if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first, scalar.properties.isAlphabetic {
      if shift && !control && !option && !command {
        key = key.uppercased()
        shift = false
      } else if control || option || command {
        key = key.lowercased()
      }
    }
    var parts: [String] = []
    if control { parts.append("control") }
    if option { parts.append("option") }
    if shift { parts.append("shift") }
    if command { parts.append("command") }
    parts.append(key)
    return parts.joined(separator: "+")
  }

  /// Rewrites a user-written binding such as `Ctrl+K` or `alt+arrowup` into canonical form.
  public static func normalize(_ binding: String) -> String {
    var parts = binding.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    // A trailing "+" means the key itself is "+": "control++".
    if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
      parts.removeLast(2)
      parts.append("+")
    }
    guard var key = parts.popLast(), !key.isEmpty else { return binding }

    var modifiers = Set<String>()
    for part in parts {
      let lowered = part.lowercased()
      modifiers.insert(aliases[lowered] ?? lowered)
    }
    if key.unicodeScalars.count > 1 {
      let lowered = key.lowercased()
      key = aliases[lowered] ?? lowered
    }
    return compose(
      control: modifiers.contains("control"), option: modifiers.contains("option"),
      shift: modifiers.contains("shift"), command: modifiers.contains("command"), key: key)
  }
}

/// Splits raw terminal input into keys and pass-through sequences.
///
/// It understands the legacy xterm encodings, application cursor mode, xterm's modifyOtherKeys
/// and the kitty keyboard protocol's `CSI … u` form (which shells such as fish switch on).
public struct KeyParser: Sendable {
  private var pending: [UInt8] = []

  /// True between the markers a terminal puts around pasted text (`ESC [ 200 ~` … `ESC [ 201 ~`).
  /// Nothing inside a paste is a key press, however large the paste is and however slowly it
  /// arrives: a pasted Return must reach the shell, not accept a suggestion.
  public private(set) var isInPaste = false
  /// How much of the marker that would change `isInPaste` has been seen so far.
  private var markerProgress = 0

  private static let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
  private static let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]

  public init() {}

  /// True when input is being held back because it may be the start of a longer sequence.
  public var hasPending: Bool { !pending.isEmpty }

  /// Parses `input` (after anything held back from earlier calls).
  ///
  /// With `flush` false, a trailing incomplete escape sequence is held back until more input
  /// arrives. The caller should call again with `flush` true after a short pause, at which
  /// point a lone ESC is the Escape key and anything else incomplete is passed through.
  public mutating func parse(_ input: [UInt8], flush: Bool) -> [InputToken] {
    var tokens: [InputToken] = []
    var index = 0

    // The opening marker can be split between input that was only observed and input that is
    // parsed: its first bytes have gone to the shell already, and the rest follows them.
    if !isInPaste, markerProgress > 0, pending.isEmpty {
      var matched = 0
      while matched < input.count, !isInPaste, markerProgress > 0, input[matched] == Self.pasteStart[markerProgress] {
        followMarker(input[matched])
        matched += 1
      }
      if matched < input.count, !isInPaste { markerProgress = 0 }
      if matched > 0 { tokens.append(InputToken(bytes: Array(input[..<matched]), key: nil)) }
      pending.append(contentsOf: input[matched...])
    } else {
      pending.append(contentsOf: input)
    }

    while index < pending.count {
      if isInPaste {
        // Passed on as it comes; only the marker that ends the paste is looked for.
        let start = index
        while index < pending.count, isInPaste {
          followMarker(pending[index])
          index += 1
        }
        tokens.append(InputToken(bytes: Array(pending[start..<index]), key: nil))
        continue
      }
      switch next(from: index, flush: flush) {
      case .token(let token):
        index += token.bytes.count
        tokens.append(token)
      case .pasteStart(let token):
        index += token.bytes.count
        tokens.append(token)
        isInPaste = true
        markerProgress = 0
      case .incomplete:
        pending.removeFirst(index)
        return tokens
      }
    }
    pending.removeAll(keepingCapacity: true)
    // The other way round: the start of an opening marker was held back and is now let through
    // because parsing stops here. `observe` has to know how far it had got.
    if flush, !isInPaste, let last = tokens.last, last.key == nil, last.bytes.count < Self.pasteStart.count,
      Self.pasteStart.starts(with: last.bytes)
    {
      markerProgress = last.bytes.count
    }
    return tokens
  }

  /// Follows the paste markers in input that is passed on without being parsed, so that a paste
  /// already under way is known about if parsing starts in the middle of it.
  public mutating func observe(_ input: [UInt8]) {
    for byte in input { followMarker(byte) }
  }

  /// Forgets a paste whose end never arrived. For when a new command line starts.
  public mutating func endPaste() {
    isInPaste = false
    markerProgress = 0
  }

  private mutating func followMarker(_ byte: UInt8) {
    let marker = isInPaste ? Self.pasteEnd : Self.pasteStart
    if byte == marker[markerProgress] {
      markerProgress += 1
      if markerProgress == marker.count {
        isInPaste.toggle()
        markerProgress = 0
      }
    } else {
      markerProgress = byte == marker[0] ? 1 : 0
    }
  }

  private enum Step {
    case token(InputToken)
    /// The marker that opens a bracketed paste.
    case pasteStart(InputToken)
    case incomplete
  }

  private func token(_ range: Range<Int>, _ key: String?) -> Step {
    .token(InputToken(bytes: Array(pending[range]), key: key))
  }

  private func next(from start: Int, flush: Bool) -> Step {
    let byte = pending[start]
    let remaining = pending.count - start

    switch byte {
    case 0x1b:
      if remaining == 1 {
        return flush ? token(start..<start + 1, "esc") : .incomplete
      }
      return escape(from: start, flush: flush)
    case 0x0d: return token(start..<start + 1, "enter")
    case 0x09: return token(start..<start + 1, "tab")
    case 0x7f, 0x08: return token(start..<start + 1, "backspace")
    case 0x00: return token(start..<start + 1, "control+space")
    case 0x01...0x1a:
      let letter = String(UnicodeScalar(byte + 0x60))
      return token(start..<start + 1, "control+" + letter)
    case 0x1c...0x1f:
      let symbol = String(UnicodeScalar(byte + 0x40))
      return token(start..<start + 1, "control+" + symbol.lowercased())
    case 0x20:
      return token(start..<start + 1, "space")
    case 0x21...0x7e:
      return token(start..<start + 1, String(UnicodeScalar(byte)))
    default:
      return utf8(from: start, flush: flush)
    }
  }

  private func utf8(from start: Int, flush: Bool) -> Step {
    let lead = pending[start]
    let length: Int
    switch lead {
    case 0xc2...0xdf: length = 2
    case 0xe0...0xef: length = 3
    case 0xf0...0xf4: length = 4
    default: return token(start..<start + 1, nil)
    }
    if start + length > pending.count {
      return flush ? token(start..<pending.count, nil) : .incomplete
    }
    let slice = pending[start..<start + length]
    guard slice.dropFirst().allSatisfy({ $0 & 0xc0 == 0x80 }) else { return token(start..<start + 1, nil) }
    return token(start..<start + length, String(decoding: slice, as: UTF8.self))
  }

  private func escape(from start: Int, flush: Bool) -> Step {
    let second = pending[start + 1]
    switch second {
    case 0x5b: // [
      return csi(from: start, flush: flush)
    case 0x4f: // O: SS3
      guard start + 2 < pending.count else {
        return flush ? token(start..<start + 2, "option+O") : .incomplete
      }
      let final = pending[start + 2]
      return token(start..<start + 3, Self.ss3Keys[final])
    case 0x5d, 0x50, 0x5f, 0x5e, 0x58: // ] P _ ^ X: string sequences, replies to terminal queries
      return string(from: start, flush: flush)
    case 0x1b:
      // ESC ESC: the first is the Escape key on its own.
      return token(start..<start + 1, "esc")
    default:
      // ESC followed by a key is how terminals send Option/Alt combinations.
      guard case .token(let inner) = next(from: start + 1, flush: flush) else { return .incomplete }
      let key = inner.key.map { Self.addingOption(to: $0) }
      return token(start..<start + 1 + inner.bytes.count, key)
    }
  }

  private static func addingOption(to key: String) -> String {
    var parts = key.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard let name = parts.popLast() else { return key }
    return KeyName.compose(
      control: parts.contains("control"), option: true, shift: parts.contains("shift"),
      command: parts.contains("command"), key: name.isEmpty ? "+" : name)
  }

  /// Sequences that end with BEL or `ESC \`.
  private func string(from start: Int, flush: Bool) -> Step {
    var index = start + 2
    while index < pending.count {
      if pending[index] == 0x07 { return token(start..<index + 1, nil) }
      if pending[index] == 0x1b, index + 1 < pending.count, pending[index + 1] == 0x5c {
        return token(start..<index + 2, nil)
      }
      index += 1
    }
    return flush ? token(start..<pending.count, nil) : .incomplete
  }

  private func csi(from start: Int, flush: Bool) -> Step {
    var index = start + 2
    // X10 mouse reports are `CSI M` followed by three raw bytes.
    if index < pending.count, pending[index] == 0x4d {
      guard index + 3 < pending.count else { return flush ? token(start..<pending.count, nil) : .incomplete }
      return token(start..<index + 4, nil)
    }
    while index < pending.count, (0x30...0x3f).contains(pending[index]) { index += 1 }
    let parametersEnd = index
    while index < pending.count, (0x20...0x2f).contains(pending[index]) { index += 1 }
    guard index < pending.count else {
      return flush ? token(start..<pending.count, nil) : .incomplete
    }
    let final = pending[index]
    guard (0x40...0x7e).contains(final) else {
      // Not a well-formed sequence; give up on the introducer and let the rest be parsed as text.
      return token(start..<start + 2, nil)
    }
    let end = index + 1
    let parameterText = String(decoding: pending[start + 2..<parametersEnd], as: UTF8.self)

    if final == 0x7e, parameterText == "200" {
      return .pasteStart(InputToken(bytes: Array(pending[start..<end]), key: nil))
    }
    guard parametersEnd == index else { return token(start..<end, nil) }
    return token(start..<end, Self.csiKey(parameters: parameterText, final: final))
  }

  // MARK: - Key tables

  private static let ss3Keys: [UInt8: String] = [
    0x41: "up", 0x42: "down", 0x43: "right", 0x44: "left", 0x48: "home", 0x46: "end",
    0x50: "f1", 0x51: "f2", 0x52: "f3", 0x53: "f4", 0x4d: "enter",
  ]

  private static let letterKeys: [UInt8: String] = [
    0x41: "up", 0x42: "down", 0x43: "right", 0x44: "left", 0x48: "home", 0x46: "end",
    0x50: "f1", 0x51: "f2", 0x52: "f3", 0x53: "f4",
  ]

  private static let tildeKeys: [Int: String] = [
    1: "home", 2: "insert", 3: "delete", 4: "end", 5: "pageup", 6: "pagedown", 7: "home", 8: "end",
    11: "f1", 12: "f2", 13: "f3", 14: "f4", 15: "f5", 17: "f6", 18: "f7", 19: "f8", 20: "f9",
    21: "f10", 23: "f11", 24: "f12",
  ]

  /// Functional keys the kitty protocol reports by code point or private-use code.
  private static let codePointKeys: [Int: String] = [
    13: "enter", 9: "tab", 27: "esc", 127: "backspace", 8: "backspace", 32: "space",
    57414: "enter", // keypad enter
  ]

  private static func csiKey(parameters: String, final: UInt8) -> String? {
    // Private-prefixed sequences (`CSI ? … c`, `CSI < … M`, `CSI > …`) are reports, not keys.
    if let first = parameters.utf8.first, (0x3c...0x3f).contains(first) { return nil }

    // Each field may carry sub-fields after a colon (alternate keys, event type).
    let fields = parameters.split(separator: ";", omittingEmptySubsequences: false).map { field in
      field.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
    }
    func number(_ field: Int, _ sub: Int = 0) -> Int? {
      guard field < fields.count, sub < fields[field].count else { return nil }
      return fields[field][sub]
    }

    // Modifiers are transmitted as 1 + bitmask. Key releases (event type 3) are not key presses.
    let mask = max((number(1) ?? 1) - 1, 0)
    if number(1, 1) == 3 { return nil }
    func compose(_ key: String) -> String {
      KeyName.compose(control: mask & 4 != 0, option: mask & 2 != 0, shift: mask & 1 != 0, command: mask & 8 != 0, key: key)
    }

    switch final {
    case 0x5a: // Z
      return KeyName.compose(shift: true, key: "tab")
    case 0x7e: // ~
      guard let code = number(0) else { return nil }
      if code == 27 {
        // xterm modifyOtherKeys: CSI 27 ; modifiers ; code ~
        guard let key = number(2).flatMap(keyName(codePoint:)) else { return nil }
        return compose(key)
      }
      return tildeKeys[code].map(compose)
    case 0x75: // u
      guard let key = number(0).flatMap(keyName(codePoint:)) else { return nil }
      return compose(key)
    default:
      guard fields.count <= 2, number(0) == nil || number(0) == 1 else { return nil }
      return letterKeys[final].map(compose)
    }
  }

  private static func keyName(codePoint: Int) -> String? {
    if let named = codePointKeys[codePoint] { return named }
    // The number comes straight from the input and can be anything, including too big for 32 bits.
    guard codePoint >= 0x21, let value = UInt32(exactly: codePoint), let scalar = Unicode.Scalar(value) else { return nil }
    // The private-use range carries keypad and media keys that nothing can be bound to.
    if (0xe000...0xf8ff).contains(codePoint) { return nil }
    return String(scalar)
  }
}
