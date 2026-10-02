import FigoCore
import Foundation

public struct BridgeError: Error, Equatable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}

/// `AppInfo` in `web/src/bridge/contract.ts`, the answer to `app.ready`.
public struct AppInfo: Codable, Equatable, Sendable {
  public var version: String
  public var home: String
  public var user: String
  public var macosVersion: String
  public var settings: [String: JSONValue]
  public var themes: [String]

  public init(
    version: String, home: String, user: String, macosVersion: String, settings: [String: JSONValue], themes: [String]
  ) {
    self.version = version
    self.home = home
    self.user = user
    self.macosVersion = macosVersion
    self.settings = settings
    self.themes = themes
  }
}

/// A call from the page (`NativeRequests` in `web/src/bridge/contract.ts`), decoded from the
/// `{method, params}` message the page posts to the `figo` message handler.
public enum BridgeRequest: Equatable, Sendable {
  case ready
  case log(level: LogLevel, message: String)
  case reportState(JSONValue)
  case position(PositionRequest)
  case insert(sessionId: String, text: String, insertionBuffer: String?)
  case setIntercept(sessionId: String, InterceptConfiguration)
  case runProcess(sessionId: String, ProcessRequest)
  case listDirectory(sessionId: String, path: String)
  /// A nil value removes the key.
  case setSetting(key: String, value: JSONValue?)

  public var method: String {
    switch self {
    case .ready: "app.ready"
    case .log: "app.log"
    case .reportState: "app.reportState"
    case .position: "window.position"
    case .insert: "shell.insert"
    case .setIntercept: "shell.setIntercept"
    case .runProcess: "process.run"
    case .listDirectory: "fs.list"
    case .setSetting: "settings.set"
    }
  }

  /// Decodes a script message body: `{method: string, params: object}`.
  public init(message: JSONValue) throws {
    guard let method = message["method"]?.stringValue else { throw BridgeError("Message has no method") }
    try self.init(method: method, params: message["params"] ?? .object([:]))
  }

  public init(method: String, params: JSONValue) throws {
    do {
      switch method {
      case "app.ready":
        self = .ready
      case "app.log":
        let p = try params.decode(LogParams.self)
        self = .log(level: LogLevel(name: p.level) ?? .info, message: p.message)
      case "app.reportState":
        self = .reportState(params["state"] ?? .null)
      case "window.position":
        self = .position(try params.decode(PositionRequest.self))
      case "shell.insert":
        let p = try params.decode(InsertParams.self)
        self = .insert(sessionId: p.sessionId, text: p.text, insertionBuffer: p.insertionBuffer)
      case "shell.setIntercept":
        let p = try params.decode(InterceptParams.self)
        self = .setIntercept(
          sessionId: p.sessionId,
          InterceptConfiguration(interceptBound: p.interceptBound, interceptGlobal: p.interceptGlobal, bindings: p.bindings))
      case "process.run":
        let p = try params.decode(ProcessParams.self)
        let request = ProcessRequest(
          executable: p.executable, arguments: p.args ?? [], workingDirectory: p.cwd, environment: p.env ?? [:],
          timeoutMilliseconds: p.timeoutMs.map { Int($0.rounded()) })
        self = .runProcess(sessionId: p.sessionId, request)
      case "fs.list":
        let p = try params.decode(ListParams.self)
        self = .listDirectory(sessionId: p.sessionId, path: p.path)
      case "settings.set":
        guard let key = params["key"]?.stringValue else { throw BridgeError("settings.set needs a key") }
        let value = params["value"]
        self = .setSetting(key: key, value: value == .null ? nil : value)
      default:
        throw BridgeError("Unknown method \(method)")
      }
    } catch let error as BridgeError {
      throw error
    } catch {
      throw BridgeError("Invalid params for \(method): \(Self.describe(error))")
    }
  }

  private static func describe(_ error: Error) -> String {
    switch error as? DecodingError {
    case .keyNotFound(let key, _)?: "missing \(key.stringValue)"
    case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?, .dataCorrupted(let context)?:
      "bad value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
    default: "\(error)"
    }
  }

  private struct LogParams: Decodable {
    var level: String
    var message: String
  }

  private struct InsertParams: Decodable {
    var sessionId: String
    var text: String
    var insertionBuffer: String?
  }

  private struct InterceptParams: Decodable {
    var sessionId: String
    var interceptBound: Bool
    var interceptGlobal: Bool
    var bindings: [String: String]
  }

  private struct ProcessParams: Decodable {
    var sessionId: String
    var executable: String
    var args: [String]?
    var cwd: String?
    var env: [String: String?]?
    var timeoutMs: Double?
  }

  private struct ListParams: Decodable {
    var sessionId: String
    var path: String
  }
}

/// What a bridge request resolves with, in the shapes the contract specifies.
public enum BridgeReply {
  public static func process(_ result: ProcessResult) -> JSONValue {
    .object([
      "stdout": .string(result.stdout), "stderr": .string(result.stderr), "exitCode": .number(Double(result.exitCode)),
    ])
  }

  public static func directory(_ entries: [DirectoryEntry]) -> JSONValue {
    .object([
      "entries": .array(
        entries.map {
          .object(["name": .string($0.name), "kind": .string($0.kind.rawValue), "isSymlink": .bool($0.isSymlink)])
        })
    ])
  }

  public static func position(_ result: PositionResult) -> JSONValue {
    .object(["isAbove": .bool(result.isAbove), "isClipped": .bool(result.isClipped)])
  }

  public static func appInfo(_ info: AppInfo) -> JSONValue {
    (try? JSONValue(encoding: info)) ?? .null
  }
}
