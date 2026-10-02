import Foundation

/// The shells Figo integrates with.
public enum Shell: String, CaseIterable, Sendable {
  case zsh
  case bash
  case fish

  /// File extension of the integration scripts for this shell (`pre.zsh`, `post.bash`, …).
  var scriptExtension: String { rawValue }
}

/// Pure text operations on shell startup files.
///
/// Integration means two lines in a startup file: one at the very top that sources `pre.<shell>`
/// (it has to run before anything else so that the rest of the file runs inside the wrapper) and
/// one at the very bottom that sources `post.<shell>` (it has to run after prompt themes and
/// plugins have been set up). Each line is preceded by a comment that marks it as ours, which is
/// how it is found again to update or remove it.
public enum ShellDotfiles {
  public enum Half: String, Sendable {
    case pre
    case post
  }

  static func marker(_ half: Half) -> String {
    switch half {
    case .pre: return "# Figo pre block. Keep at the top of this file."
    case .post: return "# Figo post block. Keep at the bottom of this file."
    }
  }

  /// Where the scripts are installed, written so that the startup file works for any home directory.
  static let scriptsDirectory = "${HOME}/Library/Application Support/figo/shell"

  /// The line that sources one half of the integration, if its script exists.
  public static func sourceLine(_ half: Half, shell: Shell) -> String {
    let script = "\(scriptsDirectory)/\(half.rawValue).\(shell.scriptExtension)"
    switch shell {
    case .zsh, .bash:
      return "[[ -f \"\(script)\" ]] && builtin source \"\(script)\""
    case .fish:
      let fishScript = script.replacingOccurrences(of: "${HOME}", with: "$HOME")
      return "test -f \"\(fishScript)\"; and source \"\(fishScript)\""
    }
  }

  /// True when `content` sources both halves.
  public static func isInstalled(in content: String, shell: Shell) -> Bool {
    let lines = content.components(separatedBy: "\n")
    return lines.contains(sourceLine(.pre, shell: shell)) && lines.contains(sourceLine(.post, shell: shell))
  }

  /// Returns `content` with the integration added, replacing any earlier version of it.
  public static func installing(in content: String, shell: Shell) -> String {
    var lines = removing(from: content).components(separatedBy: "\n")
    // A file that ends with a newline splits into a trailing empty element.
    let endsWithNewline = lines.last == ""
    if endsWithNewline { lines.removeLast() }

    let pre = [marker(.pre), sourceLine(.pre, shell: shell), ""]
    let post = ["", marker(.post), sourceLine(.post, shell: shell)]
    if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
      // Nothing of the user's to set the blocks apart from.
      return (pre + post.dropFirst()).joined(separator: "\n") + "\n"
    }

    // A shebang has to stay on the first line. The blank lines are always added, never
    // borrowed from the file, so that removal takes out exactly what was put in.
    let insertion = lines.first?.hasPrefix("#!") == true ? 1 : 0
    lines.insert(contentsOf: pre, at: insertion)
    lines.append(contentsOf: post)
    return lines.joined(separator: "\n") + "\n"
  }

  /// Returns `content` without the integration.
  public static func removing(from content: String) -> String {
    var lines = content.components(separatedBy: "\n")
    for half in [Half.pre, Half.post] {
      while let index = lines.firstIndex(of: marker(half)) {
        var end = index + 1
        // Only the line exactly as Figo writes it goes with the marker. One that was added to
        // (`…; export SOMETHING=1`) holds something of the user's and is left where it is.
        if end < lines.count, isOwnLine(lines[end]) { end += 1 }
        // Take the blank line that was added to set the block apart, but only one.
        if half == .pre, end < lines.count, lines[end].isEmpty {
          end += 1
        } else if half == .post, index > 0, lines[index - 1].isEmpty {
          lines.removeSubrange(index - 1..<end)
          continue
        }
        lines.removeSubrange(index..<end)
      }
    }
    // A source line whose marker comment was deleted by hand is still ours, as long as it is
    // the whole line exactly as Figo writes it. One that was wrapped in something of the user's
    // own (an `if`, a function) stays: taking it out could leave an empty block, which bash
    // does not parse.
    lines.removeAll(where: isOwnLine)
    return lines.joined(separator: "\n")
  }

  private static func isOwnLine(_ line: String) -> Bool {
    Shell.allCases.contains { shell in
      line == sourceLine(.pre, shell: shell) || line == sourceLine(.post, shell: shell)
    }
  }

  // MARK: - Other products

  private static let conflictSignatures: [(String, String)] = [
    ("kiro-cli/shell/", "Kiro CLI"),
    ("kiro-cli init ", "Kiro CLI"),
    ("codewhisperer/shell/", "CodeWhisperer"),
    ("/cw init ", "CodeWhisperer"),
    ("amazon-q/shell/", "Amazon Q"),
    ("/q init ", "Amazon Q"),
    (".fig/shell/", "Fig"),
    ("/fig init ", "Fig"),
  ]

  static let disabledPrefix = "# [disabled by Figo] "

  private static func conflict(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix("#") else { return nil }
    return conflictSignatures.first { trimmed.contains($0.0) }?.1
  }

  /// Other products that wrap the shell the same way. Running two wrappers at once means two
  /// popups fighting over the same keys.
  public static func conflictingProducts(in content: String) -> [String] {
    var found: [String] = []
    for line in content.components(separatedBy: "\n") {
      if let product = conflict(in: line), !found.contains(product) {
        found.append(product)
      }
    }
    return found
  }

  /// Comments out the lines that load a conflicting product, in a way `enablingConflicts` undoes.
  public static func disablingConflicts(in content: String) -> String {
    content.components(separatedBy: "\n")
      .map { conflict(in: $0) == nil ? $0 : disabledPrefix + $0 }
      .joined(separator: "\n")
  }

  public static func enablingConflicts(in content: String) -> String {
    content.components(separatedBy: "\n")
      .map { $0.hasPrefix(disabledPrefix) ? String($0.dropFirst(disabledPrefix.count)) : $0 }
      .joined(separator: "\n")
  }
}
