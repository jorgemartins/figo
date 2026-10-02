import Darwin
import Foundation

/// Terminal output helpers. Colour is used only when writing to a terminal.
enum Output {
  static let colourful = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

  static func style(_ text: String, _ code: String) -> String {
    colourful ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text
  }

  static func bold(_ text: String) -> String { style(text, "1") }
  static func dim(_ text: String) -> String { style(text, "2") }

  static func ok(_ text: String) { print(style("✓", "32") + " " + text) }
  static func warn(_ text: String) { print(style("!", "33") + " " + text) }
  static func bad(_ text: String) { print(style("✗", "31") + " " + text) }
  static func hint(_ text: String) { print("  " + dim(text)) }

  static func error(_ text: String) {
    FileHandle.standardError.write(Data(("figo: " + text + "\n").utf8))
  }
}

/// Thrown by commands to end with a message and a non-zero exit status.
struct CommandFailure: Error {
  var message: String
  init(_ message: String) { self.message = message }
}
