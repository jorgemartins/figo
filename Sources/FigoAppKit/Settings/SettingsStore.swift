import Foundation

private let log = Log("settings")

/// Keys the native side reads itself. Everything else belongs to the page.
public enum SettingKey {
  public static let disable = "autocomplete.disable"
  public static let height = "autocomplete.height"
  public static let width = "autocomplete.width"
  public static let theme = "autocomplete.theme"
  public static let fontFamily = "autocomplete.fontFamily"
  public static let fontSize = "autocomplete.fontSize"
  public static let keybindingPrefix = "autocomplete.keybindings."
  public static let launchOnStartup = "app.launchOnStartup"
  public static let hideMenubarIcon = "app.hideMenubarIcon"
}

public enum SettingsError: Error, CustomStringConvertible {
  case unreadableFile(String)

  public var description: String {
    switch self {
    case .unreadableFile(let path):
      return "\(path) is not valid JSON, so it was left as it is. Fix or delete it to change settings here."
    }
  }
}

/// The settings file: one flat JSON object with dotted keys (`{"autocomplete.height": 200}`).
///
/// The file is the source of truth. Writes re-read it first so edits made by hand or by the CLI
/// in the meantime are kept, and a watcher reloads it when anything else changes it.
@MainActor
public final class SettingsStore {
  public typealias Observer = (_ settings: [String: JSONValue], _ changedKeys: Set<String>) -> Void

  public let fileURL: URL
  public private(set) var values: [String: JSONValue] = [:]

  private var observers: [UUID: Observer] = [:]
  private var watcher: DirectoryWatcher?
  private var targetWatcher: DirectoryWatcher?
  private var watchedTarget: String?

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  /// Registers `observer` for changes; keep the token to remove it again.
  @discardableResult
  public func observe(_ observer: @escaping Observer) -> UUID {
    let token = UUID()
    observers[token] = observer
    return token
  }

  public func removeObserver(_ token: UUID) {
    observers[token] = nil
  }

  /// Re-reads the file and notifies observers when anything changed. Returns the changed keys.
  /// A file that cannot be parsed (for instance half-way through being saved by an editor) is
  /// ignored and the previous values are kept.
  @discardableResult
  public func reload() -> Set<String> {
    guard let fresh = readFile() else { return [] }
    return apply(fresh)
  }

  /// Sets `key`, or removes it when `value` is nil, and writes the file.
  ///
  /// Throws without writing when the file is there but cannot be understood: it is probably in
  /// the middle of being edited by hand, and writing would throw that work away.
  public func set(_ key: String, _ value: JSONValue?) throws {
    guard var fresh = readFile() else { throw SettingsError.unreadableFile(fileURL.path) }
    if let value, value != .null {
      fresh[key] = value
    } else {
      fresh[key] = nil
    }
    try write(fresh)
    apply(fresh)
  }

  public func bool(_ key: String) -> Bool? { values[key]?.boolValue }
  public func double(_ key: String) -> Double? { values[key]?.doubleValue }
  public func string(_ key: String) -> String? { values[key]?.stringValue }

  /// Keys whose values differ between two maps, including added and removed ones.
  public static func changedKeys(from old: [String: JSONValue], to new: [String: JSONValue]) -> Set<String> {
    Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
  }

  @discardableResult
  private func apply(_ fresh: [String: JSONValue]) -> Set<String> {
    let changed = Self.changedKeys(from: values, to: fresh)
    guard !changed.isEmpty else { return [] }
    values = fresh
    for observer in observers.values { observer(fresh, changed) }
    return changed
  }

  /// Nil when the file exists but is not a JSON object.
  private func readFile() -> [String: JSONValue]? {
    guard let data = try? Data(contentsOf: fileURL) else {
      // No file means no settings, not an error.
      return FileManager.default.fileExists(atPath: fileURL.path) ? nil : [:]
    }
    if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) { return [:] }
    guard let object = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
      log.warn("ignoring \(fileURL.path): not a JSON object")
      return nil
    }
    return object
  }

  private func write(_ settings: [String: JSONValue]) throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(JSONValue.object(settings))
    data.append(0x0a)
    // Replacing the file through a symbolic link would replace the link; write to what it
    // points at, as people who keep their settings in a dotfiles repository expect.
    try data.write(to: fileURL.resolvingSymlinksInPath(), options: .atomic)
  }

  // MARK: - Watching

  /// Reloads whenever something in the settings directory changes. Editors save by replacing the
  /// file, so the directory is watched rather than the file itself.
  public func startWatching() {
    guard watcher == nil else { return }
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    watcher = DirectoryWatcher(directory: directory) { [weak self] in
      self?.reload()
      self?.watchLinkTarget()
    }
    watchLinkTarget()
  }

  /// When the settings file is a symbolic link (kept in a dotfiles repository), edits happen in
  /// the folder it points into, which the watcher above never sees.
  private func watchLinkTarget() {
    let target = fileURL.resolvingSymlinksInPath().deletingLastPathComponent()
    let linked = target.standardizedFileURL.path != fileURL.deletingLastPathComponent().standardizedFileURL.path
    guard linked else {
      targetWatcher = nil
      watchedTarget = nil
      return
    }
    guard watchedTarget != target.path else { return }
    watchedTarget = target.path
    targetWatcher = DirectoryWatcher(directory: target) { [weak self] in
      self?.reload()
    }
  }

  public func stopWatching() {
    watcher = nil
    targetWatcher = nil
    watchedTarget = nil
  }
}
