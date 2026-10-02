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
    /// False for a file that is only looked at for other products' lines, never given ours.
    public var isStartupFile = true
  }

  /// What an install or uninstall did.
  public struct Outcome: Equatable, Sendable {
    public var changed: [URL] = []
    /// Files that were left exactly as they were, and why.
    public var skipped: [Skipped] = []
  }

  public struct Skipped: Equatable, Sendable {
    public var file: URL
    public var reason: String
  }

  public struct Status: Equatable, Sendable {
    public var files: [FileStatus]
    /// The installed integration scripts match the ones this build ships.
    public var scriptsCurrent: Bool
    /// The installed wrapper binary exists and reports this build's version.
    public var wrapperCurrent: Bool

    public func isInstalled(_ shell: Shell) -> Bool {
      let relevant = files.filter { $0.shell == shell && $0.isStartupFile }
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

  /// Every startup file bash or zsh might read, whichever of them it reads today. Which file
  /// bash picks changes when a tool creates `.bash_profile` later on, and `ZDOTDIR` can change
  /// between installing and uninstalling.
  private func candidateFiles(for shell: Shell) -> [URL] {
    switch shell {
    case .zsh:
      var directories = [home]
      if let custom = environment["ZDOTDIR"], !custom.isEmpty {
        directories.insert(URL(fileURLWithPath: custom, isDirectory: true), at: 0)
      }
      return directories.flatMap { [$0.appendingPathComponent(".zprofile"), $0.appendingPathComponent(".zshrc")] }
    case .bash:
      return [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { home.appendingPathComponent($0) }
    case .fish:
      return []
    }
  }

  /// Other files that may load a conflicting product (or hold lines from an earlier install)
  /// without being ours to add lines to.
  private func conflictOnlyFiles(for shell: Shell) -> [URL] {
    guard shell == .fish else {
      let ours = Set(startupFiles(for: shell).map(\.standardizedFileURL.path))
      var seen = ours
      return candidateFiles(for: shell).filter {
        seen.insert($0.standardizedFileURL.path).inserted && fileManager.fileExists(atPath: $0.path)
      }
    }
    let directory = fishConfigDirectory.appendingPathComponent("conf.d", isDirectory: true)
    let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".fish") && !$0.contains("figo") }.sorted().map { directory.appendingPathComponent($0) }
  }

  // MARK: - Status

  public func status(shells: [Shell] = Shell.allCases, assets: ShellAssets? = try? ShellAssets.locate()) -> Status {
    var files: [FileStatus] = []
    for shell in shells {
      for file in startupFiles(for: shell) {
        let content = (try? read(file))?.text
        files.append(
          FileStatus(
            shell: shell, path: file.path, exists: fileManager.fileExists(atPath: file.resolvingSymlinksInPath().path),
            installed: content.map { isInstalled(in: $0, file: file, shell: shell) } ?? false,
            conflicts: content.map(ShellDotfiles.conflictingProducts) ?? []))
      }
      for file in conflictOnlyFiles(for: shell) {
        let conflicts = ((try? read(file))?.text).map(ShellDotfiles.conflictingProducts) ?? []
        if !conflicts.isEmpty {
          files.append(
            FileStatus(shell: shell, path: file.path, exists: true, installed: false, conflicts: conflicts, isStartupFile: false))
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

  /// Installs or updates the integration.
  ///
  /// A startup file that cannot be changed safely is left exactly as it was and reported in
  /// `skipped`; the other files are still done.
  @discardableResult
  public func install(shells: [Shell] = Shell.allCases, assets: ShellAssets, disableConflicts: Bool = false) throws -> Outcome {
    try installAssets(assets)

    var outcome = Outcome()
    let backup = backupDirectoryForNow()
    for shell in shells {
      for file in startupFiles(for: shell) {
        do {
          let existing = try read(file)
          var updated: String
          if shell == .fish {
            let half: ShellDotfiles.Half = file.lastPathComponent.contains("pre") ? .pre : .post
            updated = ShellDotfiles.marker(half) + "\n" + ShellDotfiles.sourceLine(half, shell: .fish) + "\n"
          } else {
            updated = ShellDotfiles.installing(in: existing?.text ?? "", shell: shell)
            if breaksSyntax(from: existing?.text, to: updated, shell: shell) {
              throw Unchangeable("adding Figo's lines would leave it with a syntax error")
            }
          }
          if disableConflicts {
            let disabled = ShellDotfiles.disablingConflicts(in: updated)
            if disabled == updated || canCommentOutLines(from: updated, to: disabled, shell: shell) {
              updated = disabled
            } else {
              outcome.skipped.append(Skipped(file: file, reason: Self.conflictNotDisabled))
            }
          }
          if updated != existing?.text {
            try write(updated, encoding: existing?.encoding ?? .utf8, to: file, backupInto: backup)
            if existing == nil, shell != .fish { rememberCreated(file) }
            outcome.changed.append(file)
          }
        } catch {
          outcome.skipped.append(Skipped(file: file, reason: Self.reason(for: error)))
        }
      }
      if disableConflicts {
        for file in conflictOnlyFiles(for: shell) {
          do {
            guard let existing = try read(file) else { continue }
            let updated = ShellDotfiles.disablingConflicts(in: existing.text)
            guard updated != existing.text else { continue }
            guard canCommentOutLines(from: existing.text, to: updated, shell: shell) else {
              throw Unchangeable(Self.conflictNotDisabled)
            }
            try write(updated, encoding: existing.encoding, to: file, backupInto: backup)
            outcome.changed.append(file)
          } catch {
            outcome.skipped.append(Skipped(file: file, reason: Self.reason(for: error)))
          }
        }
      }
    }
    return outcome
  }

  private static let conflictNotDisabled =
    "another product's lines there could not be commented out safely (they are part of a larger block, or the file "
    + "could not be checked); do that by hand"

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
  /// that were disabled at install time back on.
  @discardableResult
  public func uninstall(shells: [Shell] = Shell.allCases, restoreConflicts: Bool = true, removeAssets: Bool = true) throws -> Outcome {
    var outcome = Outcome()
    let backup = backupDirectoryForNow()
    for shell in shells {
      if shell == .fish {
        for file in startupFiles(for: shell) where fileManager.fileExists(atPath: file.path) {
          do {
            try backupFile(file, into: backup)
            try fileManager.removeItem(at: file)
            outcome.changed.append(file)
          } catch {
            outcome.skipped.append(Skipped(file: file, reason: Self.reason(for: error)))
          }
        }
      }
      // For bash and zsh every file they might read is cleaned, not only the ones an install
      // would write to today.
      let files = shell == .fish ? conflictOnlyFiles(for: shell) : startupFiles(for: shell) + conflictOnlyFiles(for: shell)
      for file in files {
        do {
          guard let existing = try read(file) else { continue }
          var updated = shell == .fish ? existing.text : ShellDotfiles.removing(from: existing.text)
          if restoreConflicts { updated = ShellDotfiles.enablingConflicts(in: updated) }
          guard updated != existing.text else { continue }
          if breaksSyntax(from: existing.text, to: updated, shell: shell) {
            throw Unchangeable("removing Figo's lines would leave it with a syntax error; take them out by hand")
          }
          if updated.allSatisfy(\.isWhitespace), createdFiles().contains(file.path), !isSymbolicLink(file) {
            // The install made this file and nothing was added to it since. Left behind, an
            // empty .bash_profile would stop bash from reading .profile. A file that was there
            // before is kept even when empty: someone may have wanted exactly that.
            try backupFile(file, into: backup)
            try fileManager.removeItem(at: file)
          } else {
            try write(updated, encoding: existing.encoding, to: file, backupInto: backup)
          }
          forgetCreated(file)
          outcome.changed.append(file)
        } catch {
          outcome.skipped.append(Skipped(file: file, reason: Self.reason(for: error)))
        }
      }
    }
    if removeAssets, shells.count == Shell.allCases.count {
      // Shells that are already running keep working: they hold the binary open, and without
      // the scripts new shells simply start unwrapped.
      try? fileManager.removeItem(at: scriptsDirectory)
      try? fileManager.removeItem(at: binDirectory)
    }
    return outcome
  }

  // MARK: - Files

  /// Why a startup file is being left alone.
  private struct Unchangeable: Error {
    var reason: String
    init(_ reason: String) { self.reason = reason }
  }

  private static func reason(for error: Error) -> String {
    (error as? Unchangeable)?.reason ?? (error as NSError).localizedDescription
  }

  /// The text of a startup file, or nil when there is no such file.
  ///
  /// A file that exists but cannot be read throws. Treating it as empty would replace the
  /// user's configuration with our two lines. Text that is not UTF-8 is read byte for byte as
  /// Latin-1 and written back the same way, which changes nothing but the lines we add.
  private func read(_ file: URL) throws -> (text: String, encoding: String.Encoding)? {
    let target = file.resolvingSymlinksInPath()
    guard fileManager.fileExists(atPath: target.path) else { return nil }
    guard let data = fileManager.contents(atPath: target.path) else { throw Unchangeable("it cannot be read") }
    if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
    guard let text = String(data: data, encoding: .isoLatin1) else { throw Unchangeable("it is not a text file") }
    return (text, .isoLatin1)
  }

  private func isSymbolicLink(_ file: URL) -> Bool {
    (try? fileManager.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType == .typeSymbolicLink
  }

  /// Whether the system's own copy of `shell` accepts `content`. Nil when that cannot be found out.
  private func parses(_ content: String, as shell: Shell) -> Bool? {
    let executable: String
    switch shell {
    case .zsh: executable = "/bin/zsh"
    case .bash: executable = "/bin/bash"
    case .fish: return nil
    }
    guard fileManager.isExecutableFile(atPath: executable) else { return nil }
    let file = fileManager.temporaryDirectory.appendingPathComponent("figo-syntax-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: file) }
    guard (try? Data(content.utf8).write(to: file)) != nil else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-n", file.path]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  /// Whether commenting lines out of a startup file is known to leave it working. The lines can
  /// be part of an `if` or a function, where taking them out leaves a stray `fi` or an empty
  /// body, so this is only done when the shell accepts the file both before and after. A file
  /// it does not accept to begin with (it relies on an option set at run time, say) cannot be
  /// checked and is left alone. fish files are single commands and are not checked.
  private func canCommentOutLines(from old: String, to new: String, shell: Shell) -> Bool {
    guard shell != .fish else { return true }
    return parses(old, as: shell) == true && parses(new, as: shell) == true
  }

  // MARK: - Files the install created

  /// Startup files that did not exist before an install wrote to them, one path per line.
  private var createdFilesList: URL { data.appendingPathComponent("created-startup-files") }

  private func createdFiles() -> Set<String> {
    guard let text = try? String(contentsOf: createdFilesList, encoding: .utf8) else { return [] }
    return Set(text.split(separator: "\n").map(String.init))
  }

  private func saveCreatedFiles(_ files: Set<String>) {
    if files.isEmpty {
      try? fileManager.removeItem(at: createdFilesList)
    } else {
      try? fileManager.createDirectory(at: data, withIntermediateDirectories: true)
      try? Data((files.sorted().joined(separator: "\n") + "\n").utf8).write(to: createdFilesList, options: .atomic)
    }
  }

  private func rememberCreated(_ file: URL) {
    saveCreatedFiles(createdFiles().union([file.path]))
  }

  private func forgetCreated(_ file: URL) {
    let files = createdFiles()
    if files.contains(file.path) { saveCreatedFiles(files.subtracting([file.path])) }
  }

  /// True when a change turns a startup file the shell could parse into one it cannot. Lines are
  /// added and removed whole, which goes wrong when they sit inside an `if` or a function.
  ///
  /// A file the system's shell cannot parse to begin with (syntax newer than its bash, options
  /// set elsewhere) gives nothing to compare against and is not held back.
  private func breaksSyntax(from old: String?, to new: String, shell: Shell) -> Bool {
    guard parses(new, as: shell) == false else { return false }
    return old.map { parses($0, as: shell) != false } ?? true
  }

  private func backupDirectoryForNow() -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return backupsDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
  }

  /// A name for the backup of `file` that no other startup file shares: its path from the home
  /// folder with the folders joined by `__` (`~/.zshrc` is `dot.zshrc`, and the `.zshrc` in a
  /// `ZDOTDIR` of `~/dotfiles/zsh` is `dotfiles__zsh__dot.zshrc`).
  func backupName(for file: URL) -> String {
    let path = file.standardizedFileURL.path
    let homePath = home.standardizedFileURL.path
    let relative = path.hasPrefix(homePath + "/") ? String(path.dropFirst(homePath.count + 1)) : path
    return relative.split(separator: "/")
      .map { $0.hasPrefix(".") ? "dot" + $0 : String($0) }
      .joined(separator: "__")
  }

  private func backupFile(_ file: URL, into directory: URL) throws {
    let target = file.resolvingSymlinksInPath()
    guard fileManager.fileExists(atPath: target.path) else { return }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(backupName(for: file))
    if !fileManager.fileExists(atPath: destination.path) {
      try fileManager.copyItem(at: target, to: destination)
    }
  }

  private func write(_ content: String, encoding: String.Encoding, to file: URL, backupInto directory: URL) throws {
    // Startup files are often symbolic links into a dotfiles repository; keep the link and
    // change the file it points to.
    let target = file.resolvingSymlinksInPath()
    try backupFile(file, into: directory)
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions]
    guard let data = content.data(using: encoding) else { throw Unchangeable("its text encoding could not be kept") }
    try data.write(to: target, options: .atomic)
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
