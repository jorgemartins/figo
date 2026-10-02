import FigoCore
import FigoInstallKit
import Foundation

/// `figo doctor`: walks through every piece of the installation and says what is wrong.
enum Doctor {
  static func run() throws {
    var problems = 0
    let environment = ProcessInfo.processInfo.environment

    // The app.
    var status: AppStatus?
    if let running = try? Commands.appStatus() {
      status = running
      Output.ok("Figo app is running (version \(running.version))")
      if running.version != Figo.version {
        Output.warn("The app is version \(running.version) but this command is \(Figo.version)")
        Output.hint("Run `figo restart`.")
      }
    } else {
      problems += 1
      Output.bad("Figo app is not running")
      Output.hint("Run `figo launch`.")
    }

    // Shell integration.
    let assets = try? ShellAssets.locate()
    let integration = ShellIntegration()
    let shellStatus = integration.status(assets: assets)
    for shell in Shell.allCases {
      if shellStatus.isInstalled(shell) {
        Output.ok("\(shell.rawValue) integration is installed")
      } else if shell == .zsh {
        problems += 1
        Output.bad("zsh integration is not installed")
        Output.hint("Run `figo install`.")
      } else {
        Output.warn("\(shell.rawValue) integration is not installed")
      }
    }
    if assets != nil, shellStatus.files.contains(where: \.installed) {
      if shellStatus.scriptsCurrent && shellStatus.wrapperCurrent {
        Output.ok("Installed scripts and wrapper match this version")
      } else {
        problems += 1
        Output.bad("Installed scripts or wrapper are out of date")
        Output.hint("Run `figo install` to update them.")
      }
    }
    if !shellStatus.conflicts.isEmpty {
      problems += 1
      Output.bad("\(shellStatus.conflicts.joined(separator: " and ")) is also loaded by your shell startup files")
      Output.hint("Two wrappers and two popups will get in each other's way.")
      Output.hint("Run `figo install --disable-conflicts` to comment those lines out.")
    }

    // This terminal.
    if let session = environment["FIGO_SESSION_ID"] {
      Output.ok("This shell is running inside Figo (session \(session))")
      if let status, !status.sessions.contains(where: { $0.hello.sessionId == session }) {
        problems += 1
        Output.bad("The app does not know this session")
        Output.hint("Press Enter once; the session connects on the next prompt.")
      }
    } else if environment["FIGO_TERM"] != nil {
      Output.warn("This shell was started by Figo's wrapper falling back to a plain shell")
    } else {
      Output.warn("This shell is not running inside Figo")
      Output.hint("Shells opened before `figo install` are not wrapped; open a new window.")
    }

    // Caret position.
    if let installer = try? Locations.inputMethodInstaller() {
      let inputMethod = MainActor.assumeIsolated { installer.status() }
      if inputMethod.isComplete {
        Output.ok("Input method is installed, enabled and selected")
      } else {
        problems += 1
        Output.bad("Input method is not fully set up (registered: \(inputMethod.registered), enabled: \(inputMethod.enabled), selected: \(inputMethod.selected), running: \(inputMethod.running))")
        Output.hint("Run `figo install`.")
      }
    }
    if let status {
      if status.inputMethodConnected {
        Output.ok("Input method is connected to the app")
      } else {
        problems += 1
        Output.bad("Input method is not connected to the app")
        Output.hint("Without it Figo cannot tell where the text cursor is. Run `figo install`, then restart your terminal.")
      }
    }

    print("")
    print(problems == 0 ? "Everything looks good." : "\(problems) problem\(problems == 1 ? "" : "s") found.")
    if problems > 0 { throw CommandFailure("") }
  }
}
