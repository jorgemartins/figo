import FigoCore
import Foundation

/// What the popup page knows about a session's shell (`ShellContext` in `web/src/bridge/contract.ts`).
public struct ShellContext: Codable, Equatable, Sendable {
  public var sessionId: String
  public var shell: String
  public var shellPath: String?
  public var pid: Int32?
  public var cwd: String
  public var user: String?
  public var home: String
  public var env: [String: String]
  public var aliases: String
  public var terminal: String?

  public init(
    sessionId: String, shell: String, shellPath: String? = nil, pid: Int32? = nil, cwd: String,
    user: String? = nil, home: String, env: [String: String] = [:], aliases: String = "", terminal: String? = nil
  ) {
    self.sessionId = sessionId
    self.shell = shell
    self.shellPath = shellPath
    self.pid = pid
    self.cwd = cwd
    self.user = user
    self.home = home
    self.env = env
    self.aliases = aliases
    self.terminal = terminal
  }

  /// Combines everything the wrapper has reported. `fallbackHome` is used when the shell's
  /// environment has no `HOME` yet.
  public init(
    hello: TerminalHello, shell info: ShellInfo, environment: [String: String], aliases: String,
    fallbackHome: String
  ) {
    let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackHome
    let shellPath = info.shellPath ?? environment["SHELL"]
    let shellName = info.shell ?? shellPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    self.init(
      sessionId: hello.sessionId, shell: shellName, shellPath: shellPath, pid: info.pid,
      cwd: info.cwd ?? environment["PWD"] ?? home, user: info.user ?? environment["USER"], home: home,
      env: environment, aliases: aliases, terminal: hello.terminalBundleId)
  }
}

/// Events pushed to the page through `window.__figoReceive(name, payload)`.
public enum PageEvent: Equatable, Sendable {
  case session(ShellContext)
  case editBuffer(sessionId: String, buffer: String?, cursor: Int)
  case prompt(sessionId: String)
  case preExec(sessionId: String)
  case postExec(sessionId: String, command: String, exitCode: Int32)
  case keybinding(sessionId: String, action: String)
  case settings([String: JSONValue])
  case windowHidden

  public var name: String {
    switch self {
    case .session: "session"
    case .editBuffer: "editBuffer"
    case .prompt: "prompt"
    case .preExec: "preExec"
    case .postExec: "postExec"
    case .keybinding: "keybinding"
    case .settings: "settings"
    case .windowHidden: "windowHidden"
    }
  }

  public var payload: JSONValue {
    switch self {
    case .session(let context):
      return (try? JSONValue(encoding: context)) ?? .object([:])
    case .editBuffer(let sessionId, let buffer, let cursor):
      return .object([
        "sessionId": .string(sessionId), "buffer": buffer.map(JSONValue.string) ?? .null,
        "cursor": .number(Double(cursor)),
      ])
    case .prompt(let sessionId), .preExec(let sessionId):
      return .object(["sessionId": .string(sessionId)])
    case .postExec(let sessionId, let command, let exitCode):
      return .object([
        "sessionId": .string(sessionId), "command": .string(command), "exitCode": .number(Double(exitCode)),
      ])
    case .keybinding(let sessionId, let action):
      return .object(["sessionId": .string(sessionId), "action": .string(action)])
    case .settings(let settings):
      return .object(["settings": .object(settings)])
    case .windowHidden:
      return .object([:])
    }
  }

  /// The JavaScript that delivers this event to the page.
  public var script: String {
    let name = JSONValue.string(self.name).jsonText()
    return "window.__figoReceive && window.__figoReceive(\(name), \(payload.jsonText()));"
  }
}
