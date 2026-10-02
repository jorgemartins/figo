import Darwin
import FigoCore
import Foundation

/// Turns the environment the shell integration prepared into a `WrapperConfiguration`, and
/// provides the escape route when the wrapper cannot run.
///
/// The integration script replaces the user's shell with the wrapper (`exec`), so from that
/// point the wrapper is the only thing standing between the user and having no shell at all.
/// Whatever goes wrong, the outcome must be a working shell.
public enum Launch {
  /// Variables that only carry launch parameters and must not leak into the shell.
  private static let launchVariables = ["FIGO_SHELL", "FIGO_IS_LOGIN_SHELL"]

  public static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> WrapperConfiguration
  {
    let shellPath = shellPath(environment: environment)
    let sessionId = newSessionId()

    var childEnvironment = environment
    for name in launchVariables { childEnvironment[name] = nil }
    // Marks the shell as wrapped: the integration script must not start a second wrapper, and
    // only emits its escape sequences when it knows the session to address them to.
    childEnvironment["FIGO_TERM"] = Figo.version
    childEnvironment["FIGO_SESSION_ID"] = sessionId
    // A tmux server started from a wrapped shell hands FIGO_TERM down to every pane. This lets
    // the script tell "inherited through tmux" from "wrapped inside this pane".
    if environment["TMUX"] != nil {
      childEnvironment["FIGO_TERM_TMUX"] = Figo.version
    } else {
      childEnvironment["FIGO_TERM_TMUX"] = nil
    }

    return WrapperConfiguration(
      shellPath: shellPath,
      arguments: arguments(shellPath: shellPath, login: environment["FIGO_IS_LOGIN_SHELL"] == "1"),
      environment: childEnvironment, sessionId: sessionId, socketPath: FigoPaths.appSocket.path)
  }

  static func shellPath(environment: [String: String]) -> String {
    for candidate in [environment["FIGO_SHELL"], environment["SHELL"], "/bin/zsh"] {
      if let candidate, candidate.hasPrefix("/"), access(candidate, X_OK) == 0 { return candidate }
    }
    return "/bin/sh"
  }

  /// A leading dash in argv[0] is how `login` tells a shell it is a login shell.
  static func arguments(shellPath: String, login: Bool) -> [String] {
    let name = shellPath.split(separator: "/").last.map(String.init) ?? shellPath
    return [login ? "-" + name : name]
  }

  static func newSessionId() -> String {
    var generator = SystemRandomNumberGenerator()
    let value = UInt64.random(in: .min ... .max, using: &generator)
    let hex = String(value, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
  }

  /// Replaces this process with the plain shell. Used when the wrapper cannot start.
  public static func execShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
    let shellPath = shellPath(environment: environment)
    var childEnvironment = environment
    for name in launchVariables { childEnvironment[name] = nil }
    // Without this the shell's startup files would try to launch the wrapper again, forever.
    // No session id is set, so the integration stays silent.
    childEnvironment["FIGO_TERM"] = Figo.version
    childEnvironment["FIGO_SESSION_ID"] = nil

    var argv: [UnsafeMutablePointer<CChar>?] =
      arguments(shellPath: shellPath, login: environment["FIGO_IS_LOGIN_SHELL"] == "1").map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(shellPath, &argv, &envp)
    // Even the shell could not be started; there is nothing left to try.
    perror("figoterm: \(shellPath)")
    exit(127)
  }
}
