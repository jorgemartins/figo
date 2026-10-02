import AppKit
import Foundation

/// Identifiers of Figo's input method helper. macOS only treats a bundle as an input method when
/// its identifier contains `.inputmethod.`; the TIS input source id is the same string.
public enum InputMethodIdentity {
  public static let bundleIdentifier = "dev.figo.inputmethod.Figo"
  public static let inputSourceID = bundleIdentifier
  public static let connectionName = "\(bundleIdentifier)_Connection"
  /// The Objective-C name of the `IMKInputController` subclass (`InputMethodServerControllerClass`).
  public static let controllerClassName = "FigoInputController"
  public static let bundleName = "FigoInputMethod.app"
}

/// How the helper bundle is put into `~/Library/Input Methods`.
public enum InputMethodPlacement: String, Codable, Sendable {
  /// A symbolic link to the copy inside Figo.app, so app updates update the input method too.
  case symlink
  /// A real copy, for when the app lives somewhere a link should not point (a disk image).
  case copy
}

/// What is at the install location.
public enum InputMethodBundleState: Equatable, Codable, Sendable {
  case missing
  /// A link; `current` is true when it points at this app's helper.
  case link(destination: String, current: Bool)
  case copy
}

public struct InputMethodStatus: Equatable, Codable, Sendable {
  public var bundle: InputMethodBundleState
  /// Known to the Text Input Sources system.
  public var registered: Bool
  public var enabled: Bool
  public var selected: Bool
  /// The helper process is running (macOS starts it once the source is selected).
  public var running: Bool

  public var isComplete: Bool {
    bundle != .missing && registered && enabled && selected
  }
}

public enum InputMethodError: Error, Equatable, CustomStringConvertible {
  case helperMissing(String)
  case osStatus(operation: String, code: Int32)
  case notRegistered

  public var description: String {
    switch self {
    case .helperMissing(let path): "The input method bundle is missing at \(path)"
    case .osStatus(let operation, let code): "\(operation) failed with OSStatus \(code)"
    case .notRegistered: "The input method is not registered"
    }
  }
}

/// The steps of finishing an install that must run in a fresh process: a process that called
/// `TISEnableInputSource` never sees the source become enabled (an upstream finding), so the
/// enable is observed, and the source selected, by another process.
public enum InputMethodFinishResult: String, Codable, Sendable {
  case selected
  case notRegistered
  case notEnabled
  case notSelected
}

/// Installs, inspects and removes Figo's input method. Every function that talks to the system
/// is explicit; nothing here runs on its own.
public struct InputMethodInstaller: Sendable {
  /// `Figo.app/Contents/Helpers/FigoInputMethod.app`.
  public var helperBundle: URL
  /// `~/Library/Input Methods`.
  public var inputMethodsDirectory: URL

  public init(helperBundle: URL, inputMethodsDirectory: URL = InputMethodInstaller.defaultInputMethodsDirectory) {
    self.helperBundle = helperBundle
    self.inputMethodsDirectory = inputMethodsDirectory
  }

  public static var defaultInputMethodsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods", isDirectory: true)
  }

  public static func helperBundle(inApp appBundle: URL) -> URL {
    appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
      .appendingPathComponent(InputMethodIdentity.bundleName, isDirectory: true)
  }

  /// Where the helper goes: `~/Library/Input Methods/FigoInputMethod.app`.
  public var installedBundle: URL {
    inputMethodsDirectory.appendingPathComponent(helperBundle.lastPathComponent, isDirectory: true)
  }

  // MARK: - Files

  /// Puts the helper into the input methods directory, replacing whatever is there.
  public func placeBundle(_ placement: InputMethodPlacement = .symlink) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: helperBundle.path) else { throw InputMethodError.helperMissing(helperBundle.path) }
    try manager.createDirectory(at: inputMethodsDirectory, withIntermediateDirectories: true)
    try removePlacedBundle()
    switch placement {
    case .symlink: try manager.createSymbolicLink(at: installedBundle, withDestinationURL: helperBundle)
    case .copy: try manager.copyItem(at: helperBundle, to: installedBundle)
    }
  }

  public func bundleState() -> InputMethodBundleState {
    let manager = FileManager.default
    if let destination = try? manager.destinationOfSymbolicLink(atPath: installedBundle.path) {
      let resolved = URL(fileURLWithPath: destination, relativeTo: inputMethodsDirectory).standardizedFileURL
      return .link(destination: destination, current: resolved.path == helperBundle.standardizedFileURL.path)
    }
    return manager.fileExists(atPath: installedBundle.path) ? .copy : .missing
  }

  /// Removes the link or copy. Missing is fine.
  public func removePlacedBundle() throws {
    let manager = FileManager.default
    // `fileExists` follows links, so a dangling link has to be found through its attributes.
    if (try? manager.attributesOfItem(atPath: installedBundle.path)) != nil {
      try manager.removeItem(at: installedBundle)
    }
  }

  // MARK: - System

  /// Places the bundle, registers it with the Text Input Sources system and enables it. Finish
  /// with `finishInstallation()` in a fresh process.
  @MainActor
  public func install(_ placement: InputMethodPlacement = .symlink) throws {
    try placeBundle(placement)
    try TextInputSources.register(installedBundle)
    guard let source = TextInputSources.find(InputMethodIdentity.inputSourceID) else {
      throw InputMethodError.notRegistered
    }
    try TextInputSources.enable(source)
  }

  /// Selects the input source once it shows up as enabled. Meant to run in a process that did
  /// not call `install()`; retry it for a few seconds until it answers `.selected`.
  @MainActor
  public static func finishInstallation() -> InputMethodFinishResult {
    guard let source = TextInputSources.find(InputMethodIdentity.inputSourceID) else { return .notRegistered }
    guard TextInputSources.isEnabled(source) else { return .notEnabled }
    if !TextInputSources.isSelected(source) {
      try? TextInputSources.select(source)
    }
    return TextInputSources.isSelected(source) ? .selected : .notSelected
  }

  /// Reads the current state; changes nothing. The enabled flag can lag in the process that
  /// enabled the source (see `InputMethodFinishResult`).
  @MainActor
  public func status() -> InputMethodStatus {
    let source = TextInputSources.find(InputMethodIdentity.inputSourceID)
    return InputMethodStatus(
      bundle: bundleState(), registered: source != nil, enabled: source.map(TextInputSources.isEnabled) ?? false,
      selected: source.map(TextInputSources.isSelected) ?? false,
      running: !NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodIdentity.bundleIdentifier)
        .isEmpty)
  }

  /// Deselects and disables the source, stops the helper and removes the bundle.
  @MainActor
  public func uninstall() throws {
    if let source = TextInputSources.find(InputMethodIdentity.inputSourceID) {
      if TextInputSources.isSelected(source) { try? TextInputSources.deselect(source) }
      if TextInputSources.isEnabled(source) { try? TextInputSources.disable(source) }
    }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodIdentity.bundleIdentifier) {
      app.terminate()
    }
    try removePlacedBundle()
  }
}
