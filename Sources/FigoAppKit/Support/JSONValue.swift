import Foundation

/// Any JSON value. Settings and everything crossing the web bridge are plain JSON, so this is
/// the one type used for values whose shape the app does not care about.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue {
  /// Converts what `JSONSerialization` or WebKit hand over (NSDictionary, NSNumber, …).
  /// Returns nil for anything that has no JSON equivalent.
  public init?(foundation value: Any) {
    switch value {
    case is NSNull:
      self = .null
    case let number as NSNumber:
      // Booleans arrive as NSNumber too; only the CF type tells them apart from 0 and 1.
      self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
    case let string as String:
      self = .string(string)
    case let array as [Any]:
      var values: [JSONValue] = []
      for element in array {
        guard let converted = JSONValue(foundation: element) else { return nil }
        values.append(converted)
      }
      self = .array(values)
    case let dictionary as [String: Any]:
      var values: [String: JSONValue] = [:]
      for (key, element) in dictionary {
        guard let converted = JSONValue(foundation: element) else { return nil }
        values[key] = converted
      }
      self = .object(values)
    default:
      return nil
    }
  }

  /// The Foundation form WebKit accepts as a script message reply.
  public var foundationObject: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): NSNumber(value: value)
    case .number(let value): NSNumber(value: value)
    case .string(let value): value
    case .array(let values): values.map(\.foundationObject)
    case .object(let values): values.mapValues(\.foundationObject)
    }
  }

  /// Converts any `Encodable` value through JSON.
  public init<Value: Encodable>(encoding value: Value) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  /// Decodes a typed value from this JSON.
  public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }

  /// Compact JSON text, which is also a valid JavaScript expression.
  public func jsonText(sortedKeys: Bool = false) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}
