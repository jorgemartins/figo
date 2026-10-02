/// Parameters of a CSI sequence, e.g. the `1;31` in `ESC [ 1 ; 31 m`.
///
/// Sub-parameters (`38:2:255:0:0`) are stored flat next to their parent, flagged in `isSub`.
public struct VTParams: Equatable, Sendable {
  public private(set) var values: [Int] = []
  public private(set) var isSub: [Bool] = []

  static let maxCount = 32
  static let maxValue = 65535

  public init() {}

  public init(_ values: [Int]) {
    self.values = values
    self.isSub = Array(repeating: false, count: values.count)
  }

  public var count: Int { values.count }

  /// The parameter at `index`, or `fallback` when it is missing or zero. Terminals treat an
  /// omitted parameter and an explicit 0 the same way for almost every sequence.
  public func value(_ index: Int, default fallback: Int) -> Int {
    guard index < values.count, values[index] != 0 else { return fallback }
    return values[index]
  }

  /// The parameter at `index` as written, or 0 when missing.
  public func raw(_ index: Int) -> Int {
    index < values.count ? values[index] : 0
  }

  mutating func reset() {
    values.removeAll(keepingCapacity: true)
    isSub.removeAll(keepingCapacity: true)
  }

  mutating func push(_ value: Int, sub: Bool) {
    guard values.count < Self.maxCount else { return }
    values.append(value)
    isSub.append(sub)
  }
}

/// Receives the decoded events of a terminal byte stream.
public protocol VTHandler {
  /// A printable character.
  mutating func print(_ scalar: Unicode.Scalar)
  /// A run of printable ASCII (0x20...0x7e). Text makes up nearly all terminal output, so
  /// handlers that can place a whole run at once are much faster than one call per character.
  mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>)
  /// A C0 control such as BEL, BS, HT, LF or CR.
  mutating func execute(_ byte: UInt8)
  /// `ESC [ <prefix> <params> <intermediates> <final>`; `prefix` is one of `<=>?` or 0.
  mutating func csiDispatch(params: VTParams, prefix: UInt8, intermediates: [UInt8], final: UInt8)
  /// `ESC <intermediates> <final>`.
  mutating func escDispatch(intermediates: [UInt8], final: UInt8)
  /// The payload of `ESC ] ... (BEL | ESC \)`, without the introducer or terminator.
  mutating func oscDispatch(_ payload: [UInt8])
}

extension VTHandler {
  public mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
    for byte in bytes {
      print(Unicode.Scalar(byte))
    }
  }
}

/// A streaming parser for terminal output, following the DEC ANSI state machine described at
/// https://vt100.net/emu/dec_ansi_parser with UTF-8 input and `:` sub-parameters.
///
/// Device control, SOS, PM and APC strings are recognised so their contents are never
/// mistaken for text, but they are not reported.
public struct VTParser: Sendable {
  private enum State: Sendable {
    case ground
    case escape
    case escapeIntermediate
    case csiEntry
    case csiParam
    case csiIntermediate
    case csiIgnore
    case oscString
    /// DCS, SOS, PM and APC: swallowed until the string terminator.
    case ignoredString
  }

  /// Larger OSC payloads (clipboard transfers, inline images) are dropped rather than buffered.
  static let maxOSCLength = 64 * 1024

  private var state = State.ground
  private var params = VTParams()
  private var currentParam = 0
  private var hasCurrentParam = false
  private var currentIsSub = false
  private var prefix: UInt8 = 0
  private var intermediates: [UInt8] = []
  private var osc: [UInt8] = []
  private var oscOverflowed = false

  // UTF-8 decoding of text in the ground state.
  private var utf8Pending = 0
  private var utf8Value: UInt32 = 0
  private var utf8Minimum: UInt32 = 0

  public init() {}

  public mutating func feed<H: VTHandler>(_ bytes: UnsafeBufferPointer<UInt8>, handler: inout H) {
    var index = 0
    let count = bytes.count
    while index < count {
      if state == .ground && utf8Pending == 0 {
        var end = index
        while end < count, bytes[end] >= 0x20, bytes[end] < 0x7f { end += 1 }
        if end > index {
          handler.printASCII(UnsafeBufferPointer(rebasing: bytes[index..<end]))
          index = end
          continue
        }
      }
      advance(bytes[index], handler: &handler)
      index += 1
    }
  }

  public mutating func feed<H: VTHandler>(_ bytes: [UInt8], handler: inout H) {
    bytes.withUnsafeBufferPointer { feed($0, handler: &handler) }
  }

  private mutating func advance<H: VTHandler>(_ byte: UInt8, handler: inout H) {
    // Text is by far the most common input, so it is handled before anything else.
    if state == .ground {
      if utf8Pending == 0 {
        if byte >= 0x20 && byte < 0x7f {
          handler.print(Unicode.Scalar(byte))
          return
        }
        if byte >= 0x80 {
          beginUTF8(byte, handler: &handler)
          return
        }
      } else if byte & 0xc0 == 0x80 {
        continueUTF8(byte, handler: &handler)
        return
      } else {
        // The sequence was cut short; report it and reprocess this byte normally.
        utf8Pending = 0
        handler.print("\u{FFFD}")
        advance(byte, handler: &handler)
        return
      }
    }

    // Transitions that apply in every state.
    switch byte {
    case 0x1b:
      if state == .oscString { finishOSC(handler: &handler) }
      utf8Pending = 0
      enterEscape()
      return
    case 0x18, 0x1a:
      // CAN and SUB abort whatever sequence is in progress.
      state = .ground
      utf8Pending = 0
      return
    default:
      break
    }

    switch state {
    case .ground:
      // Only C0 controls and DEL reach here.
      if byte < 0x20 { handler.execute(byte) }

    case .escape:
      switch byte {
      case 0x00...0x1f: handler.execute(byte)
      case 0x20...0x2f:
        intermediates.append(byte)
        state = .escapeIntermediate
      case 0x5b: // [
        state = .csiEntry
      case 0x5d: // ]
        osc.removeAll(keepingCapacity: true)
        oscOverflowed = false
        state = .oscString
      case 0x50, 0x58, 0x5e, 0x5f: // P X ^ _
        state = .ignoredString
      case 0x30...0x7e:
        handler.escDispatch(intermediates: intermediates, final: byte)
        state = .ground
      default:
        break
      }

    case .escapeIntermediate:
      switch byte {
      case 0x00...0x1f: handler.execute(byte)
      case 0x20...0x2f: intermediates.append(byte)
      case 0x30...0x7e:
        handler.escDispatch(intermediates: intermediates, final: byte)
        state = .ground
      default:
        break
      }

    case .csiEntry, .csiParam:
      switch byte {
      case 0x00...0x1f: handler.execute(byte)
      case 0x30...0x39:
        currentParam = min(currentParam * 10 + Int(byte - 0x30), VTParams.maxValue)
        hasCurrentParam = true
        state = .csiParam
      case 0x3a, 0x3b: // : ;
        params.push(currentParam, sub: currentIsSub)
        currentParam = 0
        hasCurrentParam = true
        currentIsSub = byte == 0x3a
        state = .csiParam
      case 0x3c...0x3f: // < = > ?
        if state == .csiEntry {
          prefix = byte
          state = .csiParam
        } else {
          state = .csiIgnore
        }
      case 0x20...0x2f:
        intermediates.append(byte)
        state = .csiIntermediate
      case 0x40...0x7e:
        dispatchCSI(byte, handler: &handler)
      default:
        break
      }

    case .csiIntermediate:
      switch byte {
      case 0x00...0x1f: handler.execute(byte)
      case 0x20...0x2f: intermediates.append(byte)
      case 0x30...0x3f: state = .csiIgnore
      case 0x40...0x7e: dispatchCSI(byte, handler: &handler)
      default: break
      }

    case .csiIgnore:
      switch byte {
      case 0x00...0x1f: handler.execute(byte)
      case 0x40...0x7e: state = .ground
      default: break
      }

    case .oscString:
      if byte == 0x07 {
        finishOSC(handler: &handler)
        state = .ground
      } else if byte >= 0x20 {
        if osc.count < Self.maxOSCLength {
          osc.append(byte)
        } else {
          oscOverflowed = true
        }
      }

    case .ignoredString:
      // Terminated by ESC \ (handled above) or, for robustness, BEL.
      if byte == 0x07 { state = .ground }
    }
  }

  private mutating func enterEscape() {
    state = .escape
    params.reset()
    currentParam = 0
    hasCurrentParam = false
    currentIsSub = false
    prefix = 0
    intermediates.removeAll(keepingCapacity: true)
  }

  private mutating func dispatchCSI<H: VTHandler>(_ final: UInt8, handler: inout H) {
    if hasCurrentParam {
      params.push(currentParam, sub: currentIsSub)
    }
    handler.csiDispatch(params: params, prefix: prefix, intermediates: intermediates, final: final)
    state = .ground
  }

  private mutating func finishOSC<H: VTHandler>(handler: inout H) {
    if !oscOverflowed {
      handler.oscDispatch(osc)
    }
    osc.removeAll(keepingCapacity: true)
    oscOverflowed = false
  }

  private mutating func beginUTF8<H: VTHandler>(_ byte: UInt8, handler: inout H) {
    switch byte {
    case 0xc2...0xdf:
      utf8Pending = 1
      utf8Value = UInt32(byte & 0x1f)
      utf8Minimum = 0x80
    case 0xe0...0xef:
      utf8Pending = 2
      utf8Value = UInt32(byte & 0x0f)
      utf8Minimum = 0x800
    case 0xf0...0xf4:
      utf8Pending = 3
      utf8Value = UInt32(byte & 0x07)
      utf8Minimum = 0x10000
    default:
      handler.print("\u{FFFD}")
    }
  }

  private mutating func continueUTF8<H: VTHandler>(_ byte: UInt8, handler: inout H) {
    utf8Value = (utf8Value << 6) | UInt32(byte & 0x3f)
    utf8Pending -= 1
    guard utf8Pending == 0 else { return }
    if utf8Value >= utf8Minimum, let scalar = Unicode.Scalar(utf8Value) {
      handler.print(scalar)
    } else {
      handler.print("\u{FFFD}")
    }
  }
}
