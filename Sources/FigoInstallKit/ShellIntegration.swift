import FigoCore
import Foundation

/// Installs Figo into the user's shells: the integration scripts, the pty wrapper binary, and
/// the two lines in each startup file that load them.
///
/// Everything it touches is the user's own configuration, so every change is preceded by a
/// backup and can be undone with `uninstall`.
public struct ShellIntegration {
  public enum Failure: Error, CustomStringConvertible {
    case missingAsset(String)

    public var description: String {
      switch self {
      case .missingAsset(let what): return "Cannot find \(what). Is Figo installed correctly?"
      }
    }
  }

  /// One startup file and what is in it.
  public struct FileStatus: Equatable, Sendable {
    public var shell: Shell
    public var path: String
    public var exists: Bool
    public var installed: Bool
    /// Names of other products this file loads that wrap the shell the same way.
    public var conflicts: [String]
  }

  public struct Status: Equatable, Sendable {
    public var files: [FileStatus]
    /// The installed integration scripts match the ones this build ships.
    public var scriptsCurrent: Bool
    /// The installed wrapper binary exists and reports this build's version.
    public var wrapperCurrent: Bool

    public func isInstalled(_ shell: Shell) -> Bool {
      let relevant = files.filter { $0.shell == shell }
      return !relevant.isEmpty && relevant.allSatisfy { $0.installed }
    }

    public var conflicts: [String] {
      var names: [String] = []
      for name in files.flatMap(\.conflicts) where !names.contains(name) { names.append(name) }
      return names
    }
  }

  let home: URL
  public let data: URL
  let environment: [String: String]
  let fileManager = FileManager.default

  public init(
    home: URL = FigoPaths.home, data: URL = FigoPaths.data,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.home = home
    self.data = data
    self.environment = environment
  }

  public var scriptsDirectory: URL { data.appendingPathComponent("shell", isDirectory: true) }
  public var binDirectory: URL { data.appendingPathComponent("bin", isDirectory: true) }
  public var backupsDirectory: URL { data.appendingPathComponent("backups", isDirectory: true) }

  // MARK: - Startup files

  /// The files each shell reads at startup that need the two lines. Login shells read a
  /// profile before (zsh) or instead of (bash) the interactive file, and the wrapper should
  /// start as early as possible so that as little as possible runs twice.
  public func startupFiles(for shell: Shell) -> [URL] {
    switch shell {
    case .zsh:
      let directory = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? home
      return [directory.appendingPathComponent(".zprofile"), directory.appendingPathComponent(".zshrc")]
    case .bash:
      // bash reads only the first of these that exists.
      let candidates = [".bash_profile", ".bash_login", ".profile"].map { home.appendingPathComponent($0) }
      let login = candidates.first { fileManager.fileExists(atPath: $0.path) } ?? candidates[0]
      return [login, home.appendingPathComponent(".bashrc")]
    case .fish:
      let directory = fishConfigDirectory.appendingPathComponent("conf.d", isDirectory: true)
      // fish loads conf.d in name order, which is what puts these first and last.
      return [directory.appendingPathComponent("00_figo_pre.fish"), directory.appendingPathComponent("99_figo_post.fish")]
    }
  }

  private var fishConfigDirectory: URL {
    let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
      ?? home.appendingPathComponent(".config", isDirectory: true)
    return base.appendingPathComponent("fish", isDirectory: true)
  }

  /// Other files that may load a conflicting product without being ours to add lines to.
  private func conflictOnlyFiles(for shell: Shell) -> [URL] {
    guard shell == .fish else { return [] }
    let directory = fishConfigDirectory.appendingPathComponent("conf.d", isDirectory: true)
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".fish") && !$0.contains("figo") }.sorted().map { directory.appendingPathComponent($0) }
  }

  // MARK: - Status

  public func status(shells: [Shell] = Shell.allCases, assets: ShellAssets? = try? ShellAssets.locate()) -> Status {
    var files: [FileStatus] = []
    for shell in shells {
      for file in startupFiles(for: shell) {
        let content = read(file)
        files.append(
          FileStatus(
            shell: shell, path: file.path, exists: content != nil,
            installed: content.map { isInstalled(in: $0, file: file, shell: shell) } ?? false,
            conflicts: content.map(ShellDotfiles.conflictingProducts) ?? []))
      }
      for file in conflictOnlyFiles(for: shell) {
        let conflicts = read(file).map(ShellDotfiles.conflictingProducts) ?? []
        if !conflicts.isEmpty {
          files.append(FileStatus(shell: shell, path: file.path, exists: true, installed: true, conflicts: conflicts))
        }
      }
    }
    return Status(
      files: files, scriptsCurrent: assets.map(scriptsAreCurrent) ?? false, wrapperCurrent: assets.map(wrapperIsCurrent) ?? false)
  }

  private func isInstalled(in content: String, file: URL, shell: Shell) -> Bool {
    guard shell == .fish else { return ShellDotfiles.isInstalled(in: content, shell: shell) }
    let half: ShellDotfiles.Half = file.lastPathComponent.contains("pre") ? .pre : .post
    return content.components(separatedBy: "\n").contains(ShellDotfiles.sourceLine(half, shell: .fish))
  }

  // MARK: - Install

  /// Installs or updates the integration. Returns the files that were changed.
  @discardableResult
  public func install(shells: [Shell] = Shell.allCases, assets: ShellAssets, disableConflicts: Bool = false) throws -> [URL] {
    try installAssets(assets)

    var changed: [URL] = []
    let backup = backupDirectoryForNow()
    for shell in shells {
      for file in startupFiles(for: shell) {
        let existing = read(file)
        var updated: String
        if shell == .fish {
          let half: ShellDotfiles.Half = file.lastPathComponent.contains("pre") ? .pre : .post
          updated = ShellDotfiles.marker(half) + "\n" + ShellDotfiles.sourceLine(half, shell: .fish) + "\n"
        } else {
          updated = ShellDotfiles.installing(in: existing ?? "", shell: shell)
        }
        if disableConflicts { updated = ShellDotfiles.disablingConflicts(in: updated) }
        if updated != existing {
          try write(updated, to: file, backupInto: backup)
          changed.append(file)
        }
      }
      if disableConflicts {
        for file in conflictOnlyFiles(for: shell) {
          guard let existing = read(file) else { continue }
          let updated = ShellDotfiles.disablingConflicts(in: existing)
          if updated != existing {
            try write(updated, to: file, backupInto: backup)
            changed.append(file)
          }
        }
      }
    }
    return changed
  }

  /// Copies the scripts and the wrapper binary to their installed locations.
  public func installAssets(_ assets: ShellAssets) throws {
    try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
    for script in try assets.scripts() {
      try replace(scriptsDirectory.appendingPathComponent(script.lastPathComponent), withCopyOf: script)
    }

    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let wrapper = binDirectory.appendingPathComponent("figoterm")
    try replace(wrapper, withCopyOf: assets.wrapper)
    // macOS names a process after its executable file, and terminals show that name in tab
    // titles. Hard links named after each shell make a wrapped tab read "zsh (figoterm)".
    for shell in Shell.allCases {
      let link = binDirectory.appendingPathComponent("\(shell.rawValue) (figoterm)")
      try? fileManager.removeItem(at: link)
      try fileManager.linkItem(at: wrapper, to: link)
    }
  }

  private func scriptsAreCurrent(_ assets: ShellAssets) -> Bool {
    guard let scripts = try? assets.scripts(), !scripts.isEmpty else { return false }
    return scripts.allSatisfy { script in
      fileManager.contentsEqual(atPath: script.path, andPath: scriptsDirectory.appendingPathComponent(script.lastPathComponent).path)
    }
  }

  private func wrapperIsCurrent(_ assets: ShellAssets) -> Bool {
    let installed = binDirectory.appendingPathComponent("figoterm")
    guard fileManager.contentsEqual(atPath: assets.wrapper.path, andPath: installed.path) else { return false }
    return Shell.allCases.allSatisfy {
      fileManager.isExecutableFile(atPath: binDirectory.appendingPathComponent("\($0.rawValue) (figoterm)").path)
    }
  }

  // MARK: - Uninstall

  /// Removes the two lines from every startup file, and optionally turns conflicting products
  /// that were disabled at install time back on. Returns the files that were changed.
  @discardableResult
  public func uninstall(shells: [Shell] = Shell.allCases, restoreConflicts: Bool = true, removeAssets: Bool = true) throws -> [URL] {
    var changed: [URL] = []
    let backup = backupDirectoryForNow()
    for shell in shells {
      for file in startupFiles(for: shell) {
        guard let existing = read(file) else { continue }
        if shell == .fish {
          try backupFile(file, into: backup)
          try fileManager.removeItem(at: file)
          changed.append(file)
          continue
        }
        var updated = ShellDotfiles.removing(from: existing)
        if restoreConflicts { updated = ShellDotfiles.enablingConflicts(in: updated) }
        if updated != existing {
          try write(updated, to: file, backupInto: backup)
          changed.append(file)
        }
      }
      if restoreConflicts {
        for file in conflictOnlyFiles(for: shell) {
          guard let existing = read(file) else { continue }
          let updated = ShellDotfiles.enablingConflicts(in: existing)
          if updated != existing {
            try write(updated, to: file, backupInto: backup)
            changed.append(file)
          }
        }
      }
    }
    if removeAssets, shells.count == Shell.allCases.count {
      // Shells that are already running keep working: they hold the binary open, and without
      // the scripts new shells simply start unwrapped.
      try? fileManager.removeItem(at: scriptsDirectory)
      try? fileManager.removeItem(at: binDirectory)
    }
    return changed
  }

  // MARK: - Files

  private func read(_ file: URL) -> String? {
    try? String(contentsOf: file.resolvingSymlinksInPath(), encoding: .utf8)
  }

  private func backupDirectoryForNow() -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return backupsDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
  }

  private func backupFile(_ file: URL, into directory: URL) throws {
    let target = file.resolvingSymlinksInPath()
    guard fileManager.fileExists(atPath: target.path) else { return }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = file.lastPathComponent.hasPrefix(".") ? "dot" + file.lastPathComponent : file.lastPathComponent
    let destination = directory.appendingPathComponent(name)
    if !fileManager.fileExists(atPath: destination.path) {
      try fileManager.copyItem(at: target, to: destination)
    }
  }

  private func write(_ content: String, to file: URL, backupInto directory: URL) throws {
    // Startup files are often symbolic links into a dotfiles repository; keep the link and
    // change the file it points to.
    let target = file.resolvingSymlinksInPath()
    try backupFile(file, into: directory)
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions]
    try Data(content.utf8).write(to: target, options: .atomic)
    if let permissions {
      try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
    }
  }

  /// Replaces `destination` in one step, so a shell starting at that moment sees either the
  /// old file or the new one, never half of it.
  private func replace(_ destination: URL, withCopyOf source: URL) throws {
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
    try fileManager.copyItem(at: source, to: temporary)
    if rename(temporary.path, destination.path) != 0 {
      try? fileManager.removeItem(at: temporary)
      throw CocoaError(.fileWriteUnknown)
    }
  }
}

/// Where this build keeps the files that get installed for the shells.
public struct ShellAssets: Sendable {
  /// Directory holding `pre.zsh`, `post.zsh`, … and bash-preexec.
  public var scriptsSource: URL
  /// The `figoterm` binary.
  public var wrapper: URL

  public init(scriptsSource: URL, wrapper: URL) {
    self.scriptsSource = scriptsSource
    self.wrapper = wrapper
  }

  func scripts() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: scriptsSource, includingPropertiesForKeys: nil)
      .filter { ["zsh", "bash", "fish", "sh", "md"].contains($0.pathExtension) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Finds the assets next to the running executable: inside the app bundle
  /// (`Contents/MacOS` and `Contents/Resources/shell`), or in a development checkout
  /// (`.build/<configuration>` and `shell/` at the package root).
  public static func locate(
    executable: URL? = Bundle.main.executableURL, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> ShellAssets {
    let fileManager = FileManager.default
    if let scripts = environment["FIGO_SHELL_SCRIPTS"], let wrapper = environment["FIGO_TERM_BINARY"] {
      return ShellAssets(scriptsSource: URL(fileURLWithPath: scripts, isDirectory: true), wrapper: URL(fileURLWithPath: wrapper))
    }
    guard let directory = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else {
      throw ShellIntegration.Failure.missingAsset("the Figo executable")
    }
    let wrapper = directory.appendingPathComponent("figoterm")
    guard fileManager.isExecutableFile(atPath: wrapper.path) else {
      throw ShellIntegration.Failure.missingAsset("the figoterm binary next to \(directory.path)")
    }

    var candidates = [directory.deletingLastPathComponent().appendingPathComponent("Resources/shell", isDirectory: true)]
    var ancestor = directory
    for _ in 0..<5 {
      ancestor = ancestor.deletingLastPathComponent()
      if fileManager.fileExists(atPath: ancestor.appendingPathComponent("Package.swift").path) {
        candidates.append(ancestor.appendingPathComponent("shell", isDirectory: true))
      }
    }
    guard let scripts = candidates.first(where: { fileManager.fileExists(atPath: $0.appendingPathComponent("pre.zsh").path) }) else {
      throw ShellIntegration.Failure.missingAsset("the shell integration scripts")
    }
    return ShellAssets(scriptsSource: scripts, wrapper: wrapper)
  }
}
