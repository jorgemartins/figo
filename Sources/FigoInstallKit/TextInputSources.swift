import Carbon
import Foundation

/// Thin wrappers over the Text Input Sources API. TIS expects the main thread.
@MainActor
enum TextInputSources {
  static func register(_ bundle: URL) throws {
    try check("TISRegisterInputSource", TISRegisterInputSource(bundle as CFURL))
  }

  /// The input source with this id, including installed sources that are not enabled.
  static func find(_ id: String) -> TISInputSource? {
    let properties = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(properties, true)?.takeRetainedValue() as? [TISInputSource] else {
      return nil
    }
    return list.first
  }

  static func isEnabled(_ source: TISInputSource) -> Bool {
    bool(source, kTISPropertyInputSourceIsEnabled)
  }

  static func isSelected(_ source: TISInputSource) -> Bool {
    bool(source, kTISPropertyInputSourceIsSelected)
  }

  static func enable(_ source: TISInputSource) throws {
    try check("TISEnableInputSource", TISEnableInputSource(source))
  }

  static func disable(_ source: TISInputSource) throws {
    try check("TISDisableInputSource", TISDisableInputSource(source))
  }

  static func select(_ source: TISInputSource) throws {
    try check("TISSelectInputSource", TISSelectInputSource(source))
  }

  static func deselect(_ source: TISInputSource) throws {
    try check("TISDeselectInputSource", TISDeselectInputSource(source))
  }

  private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
    // Follows the get rule: the value belongs to the source.
    guard let raw = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
  }

  private static func check(_ operation: String, _ status: OSStatus) throws {
    guard status == noErr else { throw InputMethodError.osStatus(operation: operation, code: status) }
  }
}
