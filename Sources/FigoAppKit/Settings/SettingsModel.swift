import FigoInstallKit
import Foundation
import SwiftUI

private let log = Log("settings-ui")

/// The Settings window's view of the settings store, plus the input method and login item
/// actions. Every write goes through `SettingsStore`.
@MainActor
final class SettingsModel: ObservableObject {
  @Published private(set) var values: [String: JSONValue]
  @Published private(set) var themes: [ThemeEntry] = []
  @Published private(set) var launchAtLogin = false
  @Published var loginItemMessage: String?
  /// Why the last change could not be written, until one is.
  @Published private(set) var saveError: String?
  @Published private(set) var inputMethodStatus: InputMethodStatus?
  @Published private(set) var setupMessage: String?
  @Published private(set) var isWorking = false

  let store: SettingsStore
  private let catalog: ThemeCatalog
  private let installer: InputMethodInstaller?
  private let inputMethodConnected: () -> Bool
  private var observation: UUID?

  init(store: SettingsStore, themes: ThemeCatalog, installer: InputMethodInstaller?, inputMethodConnected: @escaping () -> Bool) {
    self.store = store
    self.catalog = themes
    self.installer = installer
    self.inputMethodConnected = inputMethodConnected
    values = store.values
    observation = store.observe { [weak self] values, _ in self?.values = values }
    refreshThemes()
    launchAtLogin = LaunchAtLogin.isEnabled
  }

  func detach() {
    if let observation { store.removeObserver(observation) }
    observation = nil
  }

  // MARK: - Values

  func set(_ key: String, _ value: JSONValue?) {
    do {
      try store.set(key, value)
      saveError = nil
    } catch {
      log.error("writing \(key) failed: \(error)")
      saveError = (error as? SettingsError)?.description ?? "The setting could not be saved: \(error.localizedDescription)"
    }
  }

  func bool(_ key: String, default fallback: Bool, inverted: Bool = false) -> Binding<Bool> {
    Binding(
      get: { (self.values[key]?.boolValue ?? fallback) != inverted },
      set: { self.set(key, .bool($0 != inverted)) })
  }

  /// Empty text removes the key so the page's default applies.
  func text(_ key: String) -> Binding<String> {
    Binding(
      get: { self.values[key]?.stringValue ?? "" },
      set: { self.set(key, $0.isEmpty ? nil : .string($0)) })
  }

  /// A number as text; empty removes the key, anything unparsable is ignored.
  func number(_ key: String) -> Binding<String> {
    Binding(
      get: {
        guard let value = self.values[key]?.doubleValue else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(value)
      },
      set: { text in
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
          self.set(key, nil)
        } else if let value = Double(trimmed), value > 0 {
          self.set(key, .number(value))
        }
      })
  }

  /// The option's current value: the setting when there is a usable one, its default otherwise.
  func value(of option: PopupOptions.Option) -> Double {
    guard let value = values[option.key]?.doubleValue, value > 0 else { return option.fallback }
    return value
  }

  /// Moves an option one step up or down. Landing back on the default removes the setting.
  func step(_ option: PopupOptions.Option, direction: Int) {
    let next = PopupOptions.stepped(value(of: option), direction: direction, option: option)
    set(option.key, next == option.fallback ? nil : .number(next))
  }

  var themeName: String { values[SettingKey.theme]?.stringValue ?? "dark" }

  func refreshThemes() {
    themes = catalog.entries()
  }

  // MARK: - Keys

  func action(for key: String) -> Binding<String> {
    let settingKey = Keybindings.settingKey(for: key)
    return Binding(
      get: { self.values[settingKey]?.stringValue ?? "" },
      set: { self.set(settingKey, $0.isEmpty ? nil : .string($0)) })
  }

  var customBindings: [String] {
    let defaults = Set(Keybindings.defaults.map(\.key))
    return Keybindings.overrides(in: values).keys.filter { !defaults.contains($0) }.sorted()
  }

  func addBinding(key: String, action: String) {
    let key = Keybindings.normalize(key)
    guard !key.isEmpty, !action.isEmpty else { return }
    set(Keybindings.settingKey(for: key), .string(action))
  }

  // MARK: - Login item

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try LaunchAtLogin.setEnabled(enabled)
      loginItemMessage = LaunchAtLogin.needsApproval ? "Approve Figo in System Settings › General › Login Items." : nil
    } catch {
      loginItemMessage = "Could not change the login item: \(error.localizedDescription)"
    }
    launchAtLogin = LaunchAtLogin.isEnabled
    set(SettingKey.launchOnStartup, .bool(launchAtLogin))
  }

  // MARK: - Input method

  var canInstallInputMethod: Bool { installer != nil }
  var isInputMethodConnected: Bool { inputMethodConnected() }

  func refreshInputMethodStatus() {
    inputMethodStatus = installer?.status()
    if installer == nil {
      setupMessage = "Run Figo from its app bundle (scripts/bundle.sh) to install the input method."
    }
  }

  func installInputMethod() {
    guard let installer, let executable = Bundle.main.executableURL, !isWorking else { return }
    isWorking = true
    setupMessage = "Installing…"
    Task {
      setupMessage = await InputMethodSetup.install(installer, executable: executable)
      isWorking = false
      refreshInputMethodStatus()
    }
  }

  func uninstallInputMethod() {
    guard let installer, !isWorking else { return }
    setupMessage = InputMethodSetup.uninstall(installer)
    refreshInputMethodStatus()
  }
}
