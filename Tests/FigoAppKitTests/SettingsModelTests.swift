import AppKit
import Foundation
import SwiftUI
import Testing

@testable import FigoAppKit

@MainActor
@Suite final class SettingsModelTests {
  static let bundledThemes = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/themes")

  let directory: URL
  let store: SettingsStore
  let model: SettingsModel

  init() throws {
    directory = try makeTemporaryDirectory("model")
    store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    model = SettingsModel(
      store: store, themes: ThemeCatalog(bundled: Self.bundledThemes, user: directory), installer: nil,
      inputMethodConnected: { false })
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  @Test func invertedTogglesWriteTheStoredMeaning() {
    let enabled = model.bool(SettingKey.disable, default: false, inverted: true)
    #expect(enabled.wrappedValue)
    enabled.wrappedValue = false
    #expect(store.bool(SettingKey.disable) == true)
    #expect(!enabled.wrappedValue)
  }

  @Test func numberFieldsParseClearAndIgnoreJunk() {
    let width = model.number(SettingKey.width)
    #expect(width.wrappedValue == "")
    width.wrappedValue = "400"
    #expect(store.double(SettingKey.width) == 400)
    #expect(width.wrappedValue == "400")
    width.wrappedValue = "wide"
    #expect(store.double(SettingKey.width) == 400)
    width.wrappedValue = "12.5"
    #expect(width.wrappedValue == "12.5")
    width.wrappedValue = ""
    #expect(store.values[SettingKey.width] == nil)
  }

  @Test func textFieldsRemoveTheKeyWhenEmptied() {
    let font = model.text(SettingKey.fontFamily)
    font.wrappedValue = "JetBrains Mono"
    #expect(store.string(SettingKey.fontFamily) == "JetBrains Mono")
    font.wrappedValue = ""
    #expect(store.values[SettingKey.fontFamily] == nil)
  }

  @Test func keyOverridesAreStoredPerKey() {
    model.action(for: "enter").wrappedValue = "ignore"
    #expect(store.string("autocomplete.keybindings.enter") == "ignore")
    model.action(for: "enter").wrappedValue = ""
    #expect(store.values["autocomplete.keybindings.enter"] == nil)

    model.addBinding(key: " Ctrl + Y ", action: "execute")
    #expect(store.string("autocomplete.keybindings.control+y") == "execute")
    model.addBinding(key: "tab", action: "insertSelected")
    #expect(model.customBindings == ["control+y"], "default keys are edited in their own rows")
    #expect(Keybindings.overrides(in: store.values) == ["control+y": "execute", "tab": "insertSelected"])
  }

  @Test func bundledThemesFollowTheSchema() throws {
    let catalog = ThemeCatalog(bundled: Self.bundledThemes, user: Self.bundledThemes.appendingPathComponent("none"))
    #expect(catalog.names().count >= 5)
    for name in catalog.names() {
      let data = try Data(contentsOf: Self.bundledThemes.appendingPathComponent("\(name).json"))
      let theme = try JSONDecoder().decode(JSONValue.self, from: data)
      #expect(theme["version"] == .string("1.0"), "\(name)")
      // The page throws away a theme that lacks any of these, nested objects included.
      for path in [
        ["textColor"], ["backgroundColor"], ["matchBackgroundColor"], ["selection", "textColor"],
        ["selection", "backgroundColor"], ["description", "textColor"], ["description", "borderColor"],
      ] {
        let value = path.reduce(theme["theme"]) { $0?[$1] }
        #expect(value?.stringValue?.hasPrefix("#") == true, "\(name) is missing \(path.joined(separator: "."))")
      }
    }
  }

  @Test func settingsWindowHasOneToolbarPanePerSection() {
    let controller = SettingsTabViewController(model: model)
    #expect(controller.tabStyle == .toolbar)
    #expect(controller.paneTitles == ["General", "Appearance", "Keys", "Setup"])
    // Every pane lays out, and each toolbar button has an icon.
    for item in controller.tabViewItems {
      #expect(item.image != nil, "\(item.label) has no icon")
      let view = item.viewController?.view
      view?.layoutSubtreeIfNeeded()
      #expect((view?.fittingSize.width ?? 0) > 0, "\(item.label) did not lay out")
    }
  }

  @Test func parsesTheColourFormatsThemeFilesUse() throws {
    let rgb = try #require(Color.themeColorComponents("rgb(0, 255, 0)"))
    #expect(rgb.red == 0 && rgb.green == 1 && rgb.blue == 0 && rgb.alpha == 1)
    let compact = try #require(Color.themeColorComponents("rgb(30,90,199)"))
    #expect(abs(compact.blue - 199.0 / 255) < 0.0001)
    let short = try #require(Color.themeColorComponents("#000"))
    #expect(short.red == 0 && short.alpha == 1)
    // Nonsense is no colour; it must not stop the app.
    for nonsense in ["rgb)(", "rgb(", "rgb)1,2,3(", "rgba(1,2)", "#12", ""] {
      #expect(Color.themeColorComponents(nonsense) == nil, "\(nonsense)")
    }
    let translucent = try #require(Color.themeColorComponents("#ADD7FF40"))
    #expect(abs(translucent.alpha - 64.0 / 255) < 0.0001)
    #expect(abs(translucent.red - 173.0 / 255) < 0.0001)
    #expect(try #require(Color.themeColorComponents("rgba(1, 2, 3, 0.5)")).alpha == 0.5)
    // halloween.json has a five-digit value; it is not a colour.
    #expect(Color.themeColorComponents("#00000") == nil)
    #expect(Color.themeColorComponents("tomato") == nil)
  }

  @Test func steppingMovesAlongWholeStepsWithinTheRange() {
    let size = PopupOptions.fontSize
    // From the odd default, the first press lands on a whole size.
    #expect(PopupOptions.stepped(12.8, direction: 1, option: size) == 13)
    #expect(PopupOptions.stepped(12.8, direction: -1, option: size) == 12)
    #expect(PopupOptions.stepped(13, direction: 1, option: size) == 14)
    #expect(PopupOptions.stepped(13, direction: -1, option: size) == 12)
    #expect(PopupOptions.stepped(24, direction: 1, option: size) == 24)
    #expect(PopupOptions.stepped(9, direction: -1, option: size) == 9)
    #expect(PopupOptions.stepped(320, direction: 1, option: PopupOptions.width) == 340)
    #expect(PopupOptions.stepped(330, direction: -1, option: PopupOptions.width) == 320)
  }

  @Test func steppingWritesTheSettingAndTheDefaultRemovesIt() {
    #expect(model.value(of: PopupOptions.width) == 320)
    model.step(PopupOptions.width, direction: 1)
    #expect(model.values[SettingKey.width]?.doubleValue == 340)
    model.step(PopupOptions.width, direction: -1)
    #expect(model.values[SettingKey.width] == nil)
    #expect(model.value(of: PopupOptions.width) == 320)
  }

  @Test func describesSizes() {
    #expect(PopupOptions.format(12.8, unit: "pt") == "12.8 pt")
    #expect(PopupOptions.format(13, unit: "pt") == "13 pt")
    // 140 px at the default size: six 20 px rows above a 20 px footer.
    #expect(PopupOptions.visibleRows(height: 140, fontSize: 12.8) == 6)
    #expect(PopupOptions.visibleRows(height: 200, fontSize: 12.8) == 9)
    #expect(PopupOptions.visibleRows(height: 60, fontSize: 24) == 1)
  }

  @Test func listsInstalledFontsByPitch() {
    #expect(PopupOptions.monospacedFamilies.contains("Menlo"))
    #expect(PopupOptions.monospacedFamilies.contains("Monaco"))
    #expect(!PopupOptions.monospacedFamilies.contains("Helvetica"))
    #expect(PopupOptions.otherFamilies.contains("Helvetica"))
    #expect(!PopupOptions.otherFamilies.contains { $0.hasPrefix(".") })
  }

  @Test func normalizesKeyNames() {
    #expect(Keybindings.normalize("Ctrl+Shift+K") == "control+shift+k")
    #expect(Keybindings.normalize("cmd + i") == "command+i")
    #expect(Keybindings.normalize("Escape") == "esc")
  }
}
