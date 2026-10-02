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

  @Test func updatesAnOlderBlockInPlace() {
    let old = "# Figo pre block. Keep at the top of this file.\nsource \"$HOME/Library/Application Support/figo/shell/old-pre.zsh\"\n\nexport A=1\n"
    let installed = ShellDotfiles.installing(in: old, shell: .zsh)
    #expect(!installed.contains("old-pre.zsh"))
    #expect(installed.components(separatedBy: preZsh).count == 2)
    #expect(installed.contains("export A=1"))
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

    let changed = try sandbox.integration.install(assets: sandbox.assets)
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
    #expect(try sandbox.integration.install(assets: sandbox.assets).isEmpty)
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
