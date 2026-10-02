import Foundation
import Testing

@testable import FigoInstallKit

private let preZsh = ShellDotfiles.sourceLine(.pre, shell: .zsh)
private let postZsh = ShellDotfiles.sourceLine(.post, shell: .zsh)

@Suite struct ShellDotfilesTests {
  @Test func sourceLinesPointAtTheInstalledScripts() {
    #expect(preZsh == #"[[ -f "${HOME}/Library/Application Support/figo/shell/pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/figo/shell/pre.zsh""#)
    #expect(ShellDotfiles.sourceLine(.post, shell: .bash).contains("post.bash"))
    #expect(ShellDotfiles.sourceLine(.pre, shell: .fish) == #"test -f "$HOME/Library/Application Support/figo/shell/pre.fish"; and source "$HOME/Library/Application Support/figo/shell/pre.fish""#)
  }

  @Test func installsAroundExistingContent() {
    let original = "export EDITOR=vim\nalias ll='ls -l'\n"
    let installed = ShellDotfiles.installing(in: original, shell: .zsh)
    #expect(installed == """
      # Figo pre block. Keep at the top of this file.
      \(preZsh)

      export EDITOR=vim
      alias ll='ls -l'

      # Figo post block. Keep at the bottom of this file.
      \(postZsh)

      """)
    #expect(ShellDotfiles.isInstalled(in: installed, shell: .zsh))
    #expect(!ShellDotfiles.isInstalled(in: original, shell: .zsh))
  }

  @Test func installIsIdempotentAndRemovalRestoresTheOriginal() {
    for original in ["export A=1\n", "export A=1", "", "\n", "# comment\n\nexport A=1\n\n", "a\n\n\nb\n"] {
      let once = ShellDotfiles.installing(in: original, shell: .bash)
      let twice = ShellDotfiles.installing(in: once, shell: .bash)
      #expect(once == twice, "idempotent for \(original.debugDescription)")
      let removed = ShellDotfiles.removing(from: once)
      // The only permitted differences: a file always ends with a newline once edited, and a
      // file that held nothing but blank lines comes back empty.
      var normalised = original.hasSuffix("\n") || original.isEmpty ? original : original + "\n"
      if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { normalised = "" }
      #expect(removed == normalised, "restores \(original.debugDescription), got \(removed.debugDescription)")
    }
  }

  @Test func emptyFileGetsJustTheTwoBlocks() {
    let installed = ShellDotfiles.installing(in: "", shell: .zsh)
    #expect(installed == "# Figo pre block. Keep at the top of this file.\n\(preZsh)\n\n# Figo post block. Keep at the bottom of this file.\n\(postZsh)\n")
  }

  @Test func shebangStaysFirst() {
    let installed = ShellDotfiles.installing(in: "#!/bin/zsh\nexport A=1\n", shell: .zsh)
    let lines = installed.components(separatedBy: "\n")
    #expect(lines[0] == "#!/bin/zsh")
    #expect(lines[1] == "# Figo pre block. Keep at the top of this file.")
    #expect(lines[2] == preZsh)
  }

  @Test func goesOutsideAnotherProductsBlocks() {
    let kiro = """
      # Kiro CLI pre block. Keep at the top of this file.
      [[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.pre.zsh"
      export A=1
      # Kiro CLI post block. Keep at the bottom of this file.
      [[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.post.zsh"

      """
    let lines = ShellDotfiles.installing(in: kiro, shell: .zsh).components(separatedBy: "\n")
    #expect(lines[1] == preZsh)
    #expect(lines[lines.count - 2] == postZsh)
    #expect(ShellDotfiles.conflictingProducts(in: kiro) == ["Kiro CLI"])
  }

  @Test func aLineTheUserAddedToIsKept() {
    // Only the marker goes; what was appended to our line is the user's.
    let edited = "# Figo pre block. Keep at the top of this file.\n\(preZsh); export KEEP_ME=important\n\nexport A=1\n"
    let removed = ShellDotfiles.removing(from: edited)
    #expect(removed.contains("export KEEP_ME=important"))
    #expect(!removed.contains("# Figo pre block"))
    let installed = ShellDotfiles.installing(in: edited, shell: .zsh)
    #expect(installed.contains("export KEEP_ME=important"))
    #expect(installed.hasPrefix("# Figo pre block. Keep at the top of this file.\n\(preZsh)\n"))
    #expect(installed.contains("export A=1"))
  }

  @Test func removalLeavesALineTheUserWrappedInTheirOwnBlock() {
    // Taking the line out would leave `then` with nothing after it, which bash does not parse.
    let content = "if [[ \"$TERM_PROGRAM\" != vscode ]]; then\n  \(preZsh)\nfi\nexport A=1\n"
    #expect(ShellDotfiles.removing(from: content) == content)
    // A bare copy of the line, without its marker comment, is still taken out.
    #expect(ShellDotfiles.removing(from: preZsh + "\nexport A=1\n") == "export A=1\n")
  }

  @Test func disablingConflictsIsReversible() {
    let content = """
      [[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.pre.zsh" ]] && builtin source "x"
      export A=1
      # a comment mentioning kiro-cli/shell/ stays as it is
      test -x ~/.local/bin/kiro-cli; and eval (~/.local/bin/kiro-cli init fish pre --rcfile 00_fig_pre | string split0)

      """
    let disabled = ShellDotfiles.disablingConflicts(in: content)
    #expect(ShellDotfiles.conflictingProducts(in: disabled).isEmpty)
    #expect(disabled.components(separatedBy: "\n").filter { $0.hasPrefix("# [disabled by Figo] ") }.count == 2)
    #expect(disabled.contains("\nexport A=1\n"))
    #expect(ShellDotfiles.enablingConflicts(in: disabled) == content)
  }
}

@Suite struct ShellIntegrationTests {
  /// A throwaway home directory with fake assets to install from.
  private struct Sandbox {
    let root: URL
    let home: URL
    let data: URL
    let assets: ShellAssets
    let integration: ShellIntegration

    init() throws {
      let fileManager = FileManager.default
      root = fileManager.temporaryDirectory.appendingPathComponent("figo-install-\(UUID().uuidString)")
      home = root.appendingPathComponent("home")
      data = home.appendingPathComponent("Library/Application Support/figo")
      let source = root.appendingPathComponent("source/shell")
      try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
      try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
      for name in ["pre.zsh", "post.zsh", "pre.bash", "post.bash", "pre.fish", "post.fish", "bash-preexec.sh"] {
        try Data("# \(name)\n".utf8).write(to: source.appendingPathComponent(name))
      }
      let wrapper = root.appendingPathComponent("source/figoterm")
      try Data("#!/bin/sh\necho figoterm\n".utf8).write(to: wrapper)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      assets = ShellAssets(scriptsSource: source, wrapper: wrapper)
      integration = ShellIntegration(home: home, data: data, environment: ["HOME": home.path])
    }

    func read(_ name: String) -> String? {
      try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
    }

    func write(_ name: String, _ content: String) throws {
      let file = home.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: file)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func installsScriptsWrapperAndStartupLines() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write(".zshrc", "export A=1\n")
    try sandbox.write(".profile", "export B=2\n")

    let changed = try sandbox.integration.install(assets: sandbox.assets).changed
    #expect(changed.count == 6)

    #expect(sandbox.read(".zshrc")?.contains("export A=1") == true)
    #expect(ShellDotfiles.isInstalled(in: sandbox.read(".zshrc") ?? "", shell: .zsh))
    #expect(ShellDotfiles.isInstalled(in: sandbox.read(".zprofile") ?? "", shell: .zsh))
    #expect(ShellDotfiles.isInstalled(in: sandbox.read(".bashrc") ?? "", shell: .bash))
    // bash reads only the first login file that exists, here the existing .profile.
    #expect(ShellDotfiles.isInstalled(in: sandbox.read(".profile") ?? "", shell: .bash))
    #expect(sandbox.read(".bash_profile") == nil)
    #expect(sandbox.read(".config/fish/conf.d/00_figo_pre.fish")?.contains("pre.fish") == true)
    #expect(sandbox.read(".config/fish/conf.d/99_figo_post.fish")?.contains("post.fish") == true)

    let fileManager = FileManager.default
    #expect(fileManager.fileExists(atPath: sandbox.data.appendingPathComponent("shell/pre.zsh").path))
    #expect(fileManager.fileExists(atPath: sandbox.data.appendingPathComponent("shell/bash-preexec.sh").path))
    for name in ["figoterm", "zsh (figoterm)", "bash (figoterm)", "fish (figoterm)"] {
      #expect(fileManager.isExecutableFile(atPath: sandbox.data.appendingPathComponent("bin/\(name)").path), "\(name)")
    }

    let status = sandbox.integration.status(assets: sandbox.assets)
    #expect(Shell.allCases.allSatisfy(status.isInstalled))
    #expect(status.scriptsCurrent && status.wrapperCurrent)
    #expect(status.conflicts.isEmpty)

    // A second install has nothing to do.
    let second = try sandbox.integration.install(assets: sandbox.assets)
    #expect(second == ShellIntegration.Outcome())
  }

  @Test func backsUpBeforeChangingAndUninstallRestores() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write(".zshrc", "export A=1\n")
    try sandbox.write(".bashrc", "export B=2\n")

    try sandbox.integration.install(assets: sandbox.assets)
    let backups = sandbox.data.appendingPathComponent("backups")
    let stamps = try FileManager.default.contentsOfDirectory(atPath: backups.path)
    #expect(stamps.count == 1)
    let saved = try String(contentsOf: backups.appendingPathComponent(stamps[0]).appendingPathComponent("dot.zshrc"), encoding: .utf8)
    #expect(saved == "export A=1\n")

    try sandbox.integration.uninstall()
    #expect(sandbox.read(".zshrc") == "export A=1\n")
    #expect(sandbox.read(".bashrc") == "export B=2\n")
    #expect(sandbox.read(".config/fish/conf.d/00_figo_pre.fish") == nil)
    #expect(!FileManager.default.fileExists(atPath: sandbox.data.appendingPathComponent("bin").path))
    #expect(!sandbox.integration.status(assets: sandbox.assets).isInstalled(.zsh))
  }

  @Test func writesThroughSymbolicLinks() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write("dotfiles/zshrc", "export A=1\n")
    try FileManager.default.createSymbolicLink(
      at: sandbox.home.appendingPathComponent(".zshrc"), withDestinationURL: sandbox.home.appendingPathComponent("dotfiles/zshrc"))

    try sandbox.integration.install(shells: [.zsh], assets: sandbox.assets)
    let attributes = try FileManager.default.attributesOfItem(atPath: sandbox.home.appendingPathComponent(".zshrc").path)
    #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    #expect(ShellDotfiles.isInstalled(in: sandbox.read("dotfiles/zshrc") ?? "", shell: .zsh))
  }

  @Test func reportsAndOptionallyDisablesConflicts() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let kiroLine = #"[[ -f "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/kiro-cli/shell/zshrc.pre.zsh""#
    try sandbox.write(".zshrc", kiroLine + "\nexport A=1\n")
    try sandbox.write(".config/fish/conf.d/00_fig_pre.fish", "test -x ~/.local/bin/kiro-cli; and eval (~/.local/bin/kiro-cli init fish pre --rcfile 00_fig_pre | string split0)\n")

    try sandbox.integration.install(assets: sandbox.assets)
    #expect(sandbox.integration.status(assets: sandbox.assets).conflicts == ["Kiro CLI"])
    #expect(sandbox.read(".zshrc")?.contains("\n" + kiroLine + "\n") == true)

    try sandbox.integration.install(assets: sandbox.assets, disableConflicts: true)
    #expect(sandbox.integration.status(assets: sandbox.assets).conflicts.isEmpty)
    #expect(sandbox.read(".zshrc")?.contains("# [disabled by Figo] " + kiroLine) == true)
    #expect(sandbox.read(".config/fish/conf.d/00_fig_pre.fish")?.hasPrefix("# [disabled by Figo] ") == true)

    try sandbox.integration.uninstall()
    #expect(sandbox.read(".zshrc") == kiroLine + "\nexport A=1\n")
    #expect(sandbox.read(".config/fish/conf.d/00_fig_pre.fish")?.hasPrefix("test -x") == true)
  }

  @Test func keepsAStartupFileThatIsNotUTF8() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    // "# configuração" in Latin-1, which is not valid UTF-8.
    let original = Data("# configura".utf8) + Data([0xe7, 0xe3]) + Data("o\nexport A=1\n".utf8)
    let file = sandbox.home.appendingPathComponent(".zshrc")
    try original.write(to: file)

    let outcome = try sandbox.integration.install(shells: [.zsh], assets: sandbox.assets)
    #expect(outcome.skipped.isEmpty)
    let installed = try Data(contentsOf: file)
    #expect(installed.range(of: original) != nil, "the user's bytes are all still there")
    #expect(installed.starts(with: Data("# Figo pre block".utf8)))
    #expect(sandbox.integration.status(shells: [.zsh], assets: sandbox.assets).isInstalled(.zsh))

    try sandbox.integration.uninstall(shells: [.zsh])
    let restored = try Data(contentsOf: file)
    #expect(restored == original)
  }

  @Test func leavesAnUnreadableStartupFileAlone() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write(".zshrc", "export A=1\n")
    let path = sandbox.home.appendingPathComponent(".zshrc").path
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

    let outcome = try sandbox.integration.install(shells: [.zsh], assets: sandbox.assets)
    #expect(outcome.skipped.map(\.file.lastPathComponent) == [".zshrc"])
    // The other file is still done.
    #expect(outcome.changed.map(\.lastPathComponent) == [".zprofile"])
    #expect(!sandbox.integration.status(shells: [.zsh], assets: sandbox.assets).isInstalled(.zsh))

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    #expect(sandbox.read(".zshrc") == "export A=1\n")
  }

  @Test func doesNotCommentOutAConflictInsideABlock() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let guarded = "if [ -f \"$HOME/.fig/shell/bashrc.pre.bash\" ]; then\n  . \"$HOME/.fig/shell/bashrc.pre.bash\"\nfi\nexport A=1\n"
    try sandbox.write(".bashrc", guarded)

    let outcome = try sandbox.integration.install(shells: [.bash], assets: sandbox.assets, disableConflicts: true)
    #expect(outcome.skipped.map(\.file.lastPathComponent) == [".bashrc"])
    let content = try #require(sandbox.read(".bashrc"))
    #expect(content.contains(guarded), "commenting out two of the three lines would leave a stray fi")
    #expect(!content.contains("[disabled by Figo]"))
    // Figo's own lines still went in.
    #expect(ShellDotfiles.isInstalled(in: content, shell: .bash))
  }

  @Test func doesNotCommentOutAConflictInAFileItCannotCheck() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    // `bash -n` does not run the shopt, so it rejects the pattern in the function: the file is
    // fine when run, but nothing can be said about what an edit does to it.
    let unverifiable =
      "shopt -s extglob\nstrip() { echo \"${1##+(a)}\"; }\n"
      + "if [ -f \"$HOME/.fig/shell/bashrc.pre.bash\" ]; then\n  . \"$HOME/.fig/shell/bashrc.pre.bash\"\nfi\n"
    try sandbox.write(".bashrc", unverifiable)

    let outcome = try sandbox.integration.install(shells: [.bash], assets: sandbox.assets, disableConflicts: true)
    #expect(outcome.skipped.map(\.file.lastPathComponent) == [".bashrc"])
    let content = try #require(sandbox.read(".bashrc"))
    #expect(content.contains(unverifiable))
    #expect(!content.contains("[disabled by Figo]"))
    #expect(ShellDotfiles.isInstalled(in: content, shell: .bash))
  }

  @Test func uninstallKeepsAnEmptyFileThatWasThereBefore() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    // Kept empty on purpose: it stops bash from reading an old .profile.
    try sandbox.write(".bash_profile", "")
    try sandbox.write(".profile", "export OLD=1\n")
    try sandbox.integration.install(shells: [.bash], assets: sandbox.assets)
    #expect(ShellDotfiles.isInstalled(in: sandbox.read(".bash_profile") ?? "", shell: .bash))

    try sandbox.integration.uninstall(shells: [.bash])
    #expect(sandbox.read(".bash_profile") == "")
    #expect(sandbox.read(".profile") == "export OLD=1\n")
  }

  @Test func backupsOfFilesWithTheSameNameDoNotCollide() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let integration = sandbox.integration
    #expect(integration.backupName(for: sandbox.home.appendingPathComponent(".zshrc")) == "dot.zshrc")
    #expect(integration.backupName(for: sandbox.home.appendingPathComponent("dotfiles/zsh/.zshrc")) == "dotfiles__zsh__dot.zshrc")
    #expect(
      integration.backupName(for: sandbox.home.appendingPathComponent(".config/fish/conf.d/00_fig_pre.fish"))
        == "dot.config__fish__conf.d__00_fig_pre.fish")
  }

  @Test func reinstallAndUninstallKeepAGuardTheUserPutAroundOurLine() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let pre = ShellDotfiles.sourceLine(.pre, shell: .bash)
    let custom = "if [[ \"$TERM_PROGRAM\" != vscode ]]; then\n  \(pre)\nfi\nexport A=1\n"
    try sandbox.write(".bashrc", custom)

    try sandbox.integration.install(shells: [.bash], assets: sandbox.assets)
    #expect(sandbox.read(".bashrc")?.contains(custom) == true)
    try sandbox.integration.uninstall(shells: [.bash])
    #expect(sandbox.read(".bashrc") == custom)
  }

  @Test func uninstallCleansFilesBashNoLongerReads() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    let amazonQ = #"[[ -f "${HOME}/Library/Application Support/amazon-q/shell/profile.pre.bash" ]] && builtin source "${HOME}/Library/Application Support/amazon-q/shell/profile.pre.bash""#
    try sandbox.write(".profile", amazonQ + "\nexport A=1\n")
    try sandbox.integration.install(shells: [.bash], assets: sandbox.assets, disableConflicts: true)
    #expect(sandbox.read(".profile")?.contains("# [disabled by Figo] ") == true)

    // Another tool creates .bash_profile afterwards; bash now reads that one instead.
    try sandbox.write(".bash_profile", "export B=2\n")
    try sandbox.integration.uninstall(shells: [.bash])
    #expect(sandbox.read(".profile") == amazonQ + "\nexport A=1\n")
    #expect(sandbox.read(".bash_profile") == "export B=2\n")
  }

  @Test func uninstallRemovesFilesThatOnlyHeldOurLines() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write(".zshrc", "export A=1\n")
    try sandbox.integration.install(shells: [.zsh, .bash], assets: sandbox.assets)
    #expect(sandbox.read(".zprofile") != nil)
    #expect(sandbox.read(".bash_profile") != nil)

    try sandbox.integration.uninstall(shells: [.zsh, .bash])
    #expect(sandbox.read(".zprofile") == nil)
    // An empty .bash_profile would stop bash from reading .profile.
    #expect(sandbox.read(".bash_profile") == nil)
    #expect(sandbox.read(".zshrc") == "export A=1\n")
  }

  @Test func aFileThatOnlyHoldsAConflictDoesNotCountAsInstalled() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.write(".config/fish/conf.d/00_fig_pre.fish", "test -x ~/.local/bin/kiro-cli; and eval (~/.local/bin/kiro-cli init fish pre | string split0)\n")
    let status = sandbox.integration.status(assets: sandbox.assets)
    #expect(status.conflicts == ["Kiro CLI"])
    #expect(status.files.allSatisfy { !$0.installed })
    #expect(!status.isInstalled(.fish))
  }

  @Test func detectsOutdatedAssets() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanUp() }
    try sandbox.integration.install(assets: sandbox.assets)
    try Data("# changed\n".utf8).write(to: sandbox.assets.scriptsSource.appendingPathComponent("post.zsh"))
    let status = sandbox.integration.status(assets: sandbox.assets)
    #expect(!status.scriptsCurrent)
    #expect(status.wrapperCurrent)
  }
}
