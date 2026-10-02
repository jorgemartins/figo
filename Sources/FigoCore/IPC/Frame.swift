import Foundation

/// Messages travel over unix sockets as a 4-byte big-endian length followed by that many
/// bytes of JSON.
public enum Frame {
  public static let headerLength = 4
  /// Anything larger is treated as a corrupt stream rather than buffered.
  public static let maxPayloadLength = 16 * 1024 * 1024

  public static func encode(_ payload: Data) -> Data {
    var length = UInt32(payload.count).bigEndian
    var frame = Data(capacity: headerLength + payload.count)
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
  }

  public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
    encode(try JSONEncoder().encode(message))
  }
}

/// Reassembles frames from a byte stream that arrives in arbitrary pieces.
public struct FrameDecoder {
  public enum Failure: Error, Equatable {
    case payloadTooLarge(Int)
  }

  private var buffer = Data()

  public init() {}

  public mutating func append(_ bytes: Data) {
    buffer.append(bytes)
  }

  public mutating func append(_ bytes: UnsafeRawBufferPointer) {
    buffer.append(contentsOf: bytes)
  }

  /// The next complete payload, or nil when more bytes are needed.
  public mutating func next() throws -> Data? {
    guard buffer.count >= Frame.headerLength else { return nil }
    let length = buffer.prefix(Frame.headerLength).reduce(0) { ($0 << 8) | Int($1) }
    guard length <= Frame.maxPayloadLength else { throw Failure.payloadTooLarge(length) }
    guard buffer.count >= Frame.headerLength + length else { return nil }

    let start = buffer.startIndex + Frame.headerLength
    let payload = buffer.subdata(in: start..<start + length)
    buffer.removeSubrange(buffer.startIndex..<start + length)
    return payload
  }
}
