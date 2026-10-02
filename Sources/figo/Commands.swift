import Darwin
import FigoCore
import FigoInstallKit
import Foundation

enum Commands {
  static let usage = """
    Figo: autocomplete for your terminal.

    Usage: figo <command>

      install [--shells zsh,bash,fish] [--disable-conflicts] [--skip-input-method]
                         Set up the shell integration and the input method
      uninstall          Remove everything `install` set up
      doctor             Check that every piece is in place and working
      launch | quit | restart
                         Control the menu-bar app
      status [--json]    What the app currently knows (sessions, popup, caret)
      settings           Show all settings
      settings get <key>
      settings set <key> <value>
      settings unset <key>
      settings open      Open the settings window
      theme              List themes
      theme set <name>   Switch theme
      theme import <dir> Copy theme files (*.json) from a folder into your themes
      debug type <text> [--session <id>]
                         Type into a session as if on the keyboard (for testing)
      version
    """

  static func run(_ arguments: [String]) throws {
    var arguments = arguments
    guard !arguments.isEmpty else {
      print(usage)
      return
    }
    let command = arguments.removeFirst()
    switch command {
    case "help", "--help", "-h": print(usage)
    case "version", "--version", "-V": print("figo \(Figo.version)")
    case "install": try install(arguments)
    case "uninstall": try uninstall(arguments)
    case "doctor": try Doctor.run()
    case "launch": try launch()
    case "quit": try quit()
    case "restart":
      try quit()
      try launch()
    case "status": try status(json: arguments.contains("--json"))
    case "settings": try settings(arguments)
    case "theme", "themes": try theme(arguments)
    case "debug": try debug(arguments)
    case "_finish-input-method-install":
      // Selecting an input source only takes effect when observed from a fresh process.
      print(MainActor.assumeIsolated { InputMethodInstaller.finishInstallation() }.rawValue)
    default:
      throw CommandFailure("unknown command '\(command)'. Run `figo help`.")
    }
  }

  // MARK: - Install

  private static func parseShells(_ arguments: [String]) throws -> [Shell] {
    guard let index = arguments.firstIndex(of: "--shells"), index + 1 < arguments.count else { return Shell.allCases }
    return try arguments[index + 1].split(separator: ",").map { name in
      guard let shell = Shell(rawValue: String(name)) else { throw CommandFailure("unknown shell '\(name)'") }
      return shell
    }
  }

  static func install(_ arguments: [String]) throws {
    let shells = try parseShells(arguments)
    let assets = try ShellAssets.locate()
    let integration = ShellIntegration()

    let changed = try integration.install(
      shells: shells, assets: assets, disableConflicts: arguments.contains("--disable-conflicts"))
    Output.ok("Shell integration installed for \(shells.map(\.rawValue).joined(separator: ", "))")
    for file in changed { Output.hint("updated \(abbreviate(file.path))") }
    if !changed.isEmpty { Output.hint("backups are in \(abbreviate(integration.backupsDirectory.path))") }

    let conflicts = integration.status(shells: shells, assets: assets).conflicts
    if !conflicts.isEmpty {
      Output.warn("\(conflicts.joined(separator: " and ")) is also set up in your shell startup files.")
      Output.hint("Both would wrap your shell and show their own popup. Run `figo install --disable-conflicts`")
      Output.hint("to comment those lines out (undone by `figo uninstall`).")
    }

    if !arguments.contains("--skip-input-method") {
      try installInputMethod()
    }

    linkCommandLineTool()
    if !AppClient.isAppRunning, Locations.appBundle != nil {
      try launch()
    }
    print("")
    print("Open a new terminal window to start using Figo.")
  }

  private static func installInputMethod() throws {
    let installer = try Locations.inputMethodInstaller()
    try MainActor.assumeIsolated { try installer.install() }
    // Enabling and selecting can only be confirmed from a process started afterwards.
    var result = "unknown"
    for _ in 0..<40 {
      result = runSelf(["_finish-input-method-install"]).trimmingCharacters(in: .whitespacesAndNewlines)
      if result == InputMethodFinishResult.selected.rawValue { break }
      usleep(500_000)
    }
    if result == InputMethodFinishResult.selected.rawValue {
      Output.ok("Input method installed (it tells Figo where your text cursor is)")
      Output.hint("Terminals that were already open need to be restarted to pick it up.")
    } else {
      Output.warn("Input method installed but not active yet (\(result)). Run `figo doctor` after restarting your terminal.")
    }
  }

  /// Puts `figo` on the PATH when there is a conventional per-user bin directory for it.
  private static func linkCommandLineTool() {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath(), Locations.appBundle != nil else { return }
    let directory = FigoPaths.home.appendingPathComponent(".local/bin", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    let link = directory.appendingPathComponent("figo")
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == executable.path { return }
    try? FileManager.default.removeItem(at: link)
    if (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)) != nil {
      Output.ok("`figo` command linked into \(abbreviate(directory.path))")
    }
  }

  static func uninstall(_ arguments: [String]) throws {
    let integration = ShellIntegration()
    let changed = try integration.uninstall()
    Output.ok("Shell integration removed")
    for file in changed { Output.hint("updated \(abbreviate(file.path))") }

    if let installer = try? Locations.inputMethodInstaller() {
      let wasInstalled = MainActor.assumeIsolated { installer.status() }.registered || installer.bundleState() != .missing
      try MainActor.assumeIsolated { try installer.uninstall() }
      if wasInstalled { Output.ok("Input method removed") }
    }
    let link = FigoPaths.home.appendingPathComponent(".local/bin/figo")
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
      try? FileManager.default.removeItem(at: link)
    }
    if AppClient.isAppRunning { try quit() }
    print("")
    print("Terminals that are already open keep working until you close them.")
  }

  // MARK: - App

  static func launch() throws {
    if AppClient.isAppRunning {
      Output.ok("Figo is already running")
      return
    }
    guard let bundle = Locations.appBundle else {
      throw CommandFailure("Cannot find Figo.app next to this command.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", bundle.path]
    try process.run()
    process.waitUntilExit()
    for _ in 0..<50 {
      if AppClient.isAppRunning {
        Output.ok("Figo started")
        return
      }
      usleep(100_000)
    }
    throw CommandFailure("Figo did not start. See \(abbreviate(FigoPaths.logs.appendingPathComponent("app.log").path)).")
  }

  static func quit() throws {
    guard AppClient.isAppRunning else {
      Output.ok("Figo is not running")
      return
    }
    _ = try? AppClient.request(.quit)
    for _ in 0..<50 {
      if !AppClient.isAppRunning {
        Output.ok("Figo quit")
        return
      }
      usleep(100_000)
    }
    throw CommandFailure("Figo did not quit.")
  }

  static func appStatus() throws -> AppStatus {
    switch try AppClient.request(.status) {
    case .status(let status): return status
    case .failure(let message): throw CommandFailure(message)
    case .ok: throw CommandFailure("unexpected answer from Figo")
    }
  }

  static func status(json: Bool) throws {
    let status = try appStatus()
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      print(String(decoding: try encoder.encode(status), as: UTF8.self))
      return
    }
    print("Figo \(status.version), pid \(status.pid)")
    print("Input method: \(status.inputMethodConnected ? "connected" : "not connected")")
    print("Focused app:  \(status.focusedBundleId ?? "unknown")")
    print("Popup:        \(status.popupVisible ? "visible" : "hidden")")
    print("Sessions:     \(status.sessions.count)")
    for session in status.sessions {
      let marker = session.isCurrent ? "→" : " "
      let shell = session.shell.shell ?? "?"
      let terminal = session.hello.terminalBundleId ?? session.hello.termProgram ?? "unknown terminal"
      let buffer = session.editBuffer.map { " \(Output.dim("›")) \($0.text)" } ?? ""
      print(" \(marker) \(session.hello.sessionId)  \(shell)  \(terminal)  \(abbreviate(session.shell.cwd ?? ""))\(buffer)")
    }
  }

  // MARK: - Settings and themes

  static func settings(_ arguments: [String]) throws {
    var settings = try SettingsFile.read()
    switch arguments.first {
    case nil, "list":
      if settings.isEmpty { print(Output.dim("No settings changed from their defaults.")) }
      for key in settings.keys.sorted() {
        print("\(key) = \(SettingsFile.render(settings[key]!))")
      }
    case "get":
      guard arguments.count == 2 else { throw CommandFailure("usage: figo settings get <key>") }
      guard let value = settings[arguments[1]] else { throw CommandFailure("\(arguments[1]) is not set") }
      print(SettingsFile.render(value))
    case "set":
      guard arguments.count == 3 else { throw CommandFailure("usage: figo settings set <key> <value>") }
      settings[arguments[1]] = SettingsFile.parseValue(arguments[2])
      try SettingsFile.write(settings)
    case "unset":
      guard arguments.count == 2 else { throw CommandFailure("usage: figo settings unset <key>") }
      settings[arguments[1]] = nil
      try SettingsFile.write(settings)
    case "open":
      if !AppClient.isAppRunning { try launch() }
      _ = try AppClient.request(.openSettings)
    case let other?:
      throw CommandFailure("unknown settings command '\(other)'")
    }
  }

  static func themeNames() -> [String] {
    var names: Set<String> = ["dark", "light", "system"]
    for directory in [Locations.bundledThemes, FigoPaths.userThemes].compactMap({ $0 }) {
      for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".json") {
        names.insert(String(file.dropLast(5)))
      }
    }
    return names.sorted()
  }

  static func theme(_ arguments: [String]) throws {
    switch arguments.first {
    case nil, "list":
      let current = (try SettingsFile.read())["autocomplete.theme"] as? String ?? "dark"
      for name in themeNames() {
        print(name == current ? "\(Output.bold("* " + name))" : "  \(name)")
      }
    case "set":
      guard arguments.count == 2 else { throw CommandFailure("usage: figo theme set <name>") }
      guard themeNames().contains(arguments[1]) else {
        throw CommandFailure("no theme named '\(arguments[1])'. Run `figo theme` for the list.")
      }
      var settings = try SettingsFile.read()
      settings["autocomplete.theme"] = arguments[1]
      try SettingsFile.write(settings)
      Output.ok("Theme set to \(arguments[1])")
    case "import":
      guard arguments.count == 2 else { throw CommandFailure("usage: figo theme import <directory>") }
      let source = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
      let files = ((try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }
      guard !files.isEmpty else { throw CommandFailure("no .json theme files in \(source.path)") }
      try FileManager.default.createDirectory(at: FigoPaths.userThemes, withIntermediateDirectories: true)
      for file in files {
        let destination = FigoPaths.userThemes.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
      }
      Output.ok("Imported \(files.count) themes into \(abbreviate(FigoPaths.userThemes.path))")
    case let other?:
      throw CommandFailure("unknown theme command '\(other)'")
    }
  }

  // MARK: - Debug

  static func debug(_ arguments: [String]) throws {
    guard arguments.first == "type", arguments.count >= 2 else {
      throw CommandFailure("usage: figo debug type <text> [--session <id>]")
    }
    var session: String?
    if let index = arguments.firstIndex(of: "--session"), index + 1 < arguments.count {
      session = arguments[index + 1]
    }
    // Lets tests write control characters: \r, \n, \t, \e and \xHH.
    let text = unescape(arguments[1])
    switch try AppClient.request(.simulateInput(sessionId: session, text: text)) {
    case .failure(let message): throw CommandFailure(message)
    default: break
    }
  }

  static func unescape(_ text: String) -> String {
    var result = ""
    var iterator = text.makeIterator()
    while let character = iterator.next() {
      guard character == "\\" else {
        result.append(character)
        continue
      }
      switch iterator.next() {
      case "r"?: result.append("\r")
      case "n"?: result.append("\n")
      case "t"?: result.append("\t")
      case "e"?: result.append("\u{1b}")
      case "\\"?: result.append("\\")
      case "x"?:
        let digits = String([iterator.next(), iterator.next()].compactMap { $0 })
        if let value = UInt8(digits, radix: 16) { result.append(Character(UnicodeScalar(value))) }
      case let other?:
        result.append("\\")
        result.append(other)
      case nil:
        result.append("\\")
      }
    }
    return result
  }

  // MARK: - Helpers

  static func abbreviate(_ path: String) -> String {
    let home = FigoPaths.home.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  /// Runs this executable again with other arguments and returns what it printed.
  static func runSelf(_ arguments: [String]) -> String {
    guard let executable = Bundle.main.executableURL else { return "" }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}
