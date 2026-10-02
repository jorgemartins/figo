import AppKit
import FigoInstallKit
import SwiftUI

/// The panes of the Settings window, in toolbar order.
private enum SettingsPane: Int, CaseIterable {
  case general
  case appearance
  case keys
  case setup

  /// Every pane has the same size, so switching between them never moves the window.
  static let size = NSSize(width: 700, height: 580)

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .keys: "Keys"
    case .setup: "Setup"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintpalette"
    case .keys: "keyboard"
    case .setup: "wrench.and.screwdriver"
    }
  }

  @MainActor
  func view(model: SettingsModel) -> AnyView {
    let pane: AnyView =
      switch self {
      case .general: AnyView(GeneralTab(model: model))
      case .appearance: AnyView(AppearanceTab(model: model))
      case .keys: AnyView(KeysTab(model: model))
      case .setup: AnyView(SetupTab(model: model))
      }
    return AnyView(pane.frame(width: Self.size.width, height: Self.size.height))
  }
}

/// The content of the Settings window: one toolbar button per pane, as in every Mac app's
/// settings. A SwiftUI `TabView` only looks like that inside a SwiftUI `Settings` scene; in a
/// plain window it draws the old boxed tab strip, so the tabs are AppKit's and only the panes
/// are SwiftUI.
@MainActor
final class SettingsTabViewController: NSTabViewController {
  private static let selectedPaneKey = "settings.selectedPane"

  init(model: SettingsModel) {
    super.init(nibName: nil, bundle: nil)
    tabStyle = .toolbar
    for pane in SettingsPane.allCases {
      let item = NSTabViewItem(viewController: NSHostingController(rootView: pane.view(model: model)))
      item.label = pane.title
      item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
      addTabViewItem(item)
    }
    // Reopen on the pane that was last looked at.
    let remembered = UserDefaults.standard.integer(forKey: Self.selectedPaneKey)
    if SettingsPane(rawValue: remembered) != nil {
      selectedTabViewItemIndex = remembered
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("not used")
  }

  var paneTitles: [String] { tabViewItems.map(\.label) }

  override func viewDidAppear() {
    super.viewDidAppear()
    updateWindowTitle()
  }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.selectedPaneKey)
    updateWindowTitle()
  }

  /// Settings windows are titled after the pane they show.
  private func updateWindowTitle() {
    guard selectedTabViewItemIndex >= 0, selectedTabViewItemIndex < tabViewItems.count else { return }
    view.window?.title = tabViewItems[selectedTabViewItemIndex].label
  }
}

// MARK: - General

private struct GeneralTab: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    Form {
      Section {
        Toggle("Enable autocomplete", isOn: model.bool(SettingKey.disable, default: false, inverted: true))
        Toggle(
          "Launch at login",
          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        if let message = model.loginItemMessage {
          Text(message).font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Show menu-bar icon", isOn: model.bool(SettingKey.hideMenubarIcon, default: false, inverted: true))
        if model.values[SettingKey.hideMenubarIcon]?.boolValue == true {
          Text("Open Figo again from the Finder, or run `figo settings`, to get back here.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section {
        LabeledContent("Settings file") {
          Button(model.store.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([model.store.fileURL])
          }
          .buttonStyle(.link)
          .lineLimit(1)
          .truncationMode(.middle)
        }
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - Appearance

private struct AppearanceTab: View {
  @ObservedObject var model: SettingsModel

  private static let builtIns = [
    ThemeEntry(name: "dark", swatch: .dark, isUserTheme: false),
    ThemeEntry(name: "light", swatch: .light, isUserTheme: false),
  ]
  private static let sidebarWidth: CGFloat = 200
  /// Room for the preview at the largest text size, so stepping the size never moves the
  /// buttons being clicked.
  private static let previewHeight: CGFloat = 170

  private var entries: [ThemeEntry] { Self.builtIns + model.themes }

  var body: some View {
    HStack(spacing: 0) {
      themeList.frame(width: Self.sidebarWidth)
      Divider()
      Form {
        Section {
          PopupPreview(model: model, swatch: currentSwatch, maxWidth: SettingsPane.size.width - Self.sidebarWidth - 80)
            .frame(maxWidth: .infinity)
            .frame(height: Self.previewHeight)
        }
        Section("Text") {
          LabeledContent("Font") { FontMenu(model: model) }
          StepperRow(title: "Font size", option: PopupOptions.fontSize, model: model)
        }
        Section("Size") {
          StepperRow(title: "Width", option: PopupOptions.width, model: model)
          StepperRow(
            title: "Maximum height", option: PopupOptions.height, model: model,
            detail: { height in
              let rows = PopupOptions.visibleRows(height: height, fontSize: model.value(of: PopupOptions.fontSize))
              return rows == 1 ? "1 row" : "\(rows) rows"
            })
        }
      }
      .formStyle(.grouped)
    }
    .onAppear { model.refreshThemes() }
  }

  /// Every theme in one column. Being a list, the arrow keys walk through it and the preview
  /// beside it follows.
  private var themeList: some View {
    let selection = Binding<String?>(
      get: { model.themeName },
      set: { name in
        guard let name, name != model.themeName else { return }
        model.set(SettingKey.theme, name == "dark" ? nil : .string(name))
      })
    return ScrollViewReader { scroller in
      List(selection: selection) {
        ForEach(entries) { entry in
          ThemeTile(entry: entry).tag(entry.name)
        }
      }
      .listStyle(.sidebar)
      // With some forty themes the chosen one is usually out of sight when the pane opens.
      // The list is read from disk as the pane appears, so wait for it before scrolling.
      .task(id: model.themes.count) {
        await Task.yield()
        scroller.scrollTo(model.themeName, anchor: .center)
      }
    }
  }

  private var currentSwatch: ThemeSwatch {
    entries.first { $0.name == model.themeName }?.swatch ?? .dark
  }
}

/// The popup as the current settings would draw it: theme, font, text size and width.
private struct PopupPreview: View {
  @ObservedObject var model: SettingsModel
  let swatch: ThemeSwatch
  /// The pane is narrower than the widest popup; the preview shows as much of it as fits.
  let maxWidth: CGFloat

  private static let rows = [("checkout", true), ("cherry-pick", false), ("clean", false)]

  var body: some View {
    let fontSize = model.value(of: PopupOptions.fontSize)
    let rowHeight = fontSize * 1.5625
    let width = min(model.value(of: PopupOptions.width), maxWidth)
    let family = model.values[SettingKey.fontFamily]?.stringValue

    VStack(alignment: .leading, spacing: 0) {
      ForEach(Self.rows, id: \.0) { name, selected in
        HStack(spacing: 5) {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color(red: 0.56, green: 0.36, blue: 0.86))
            .frame(width: rowHeight * 0.75, height: rowHeight * 0.75)
            .overlay(Text("$").font(.system(size: rowHeight * 0.5, weight: .bold)).foregroundStyle(.white))
          Text(name)
            .font(.custom(family ?? "Monaco", size: fontSize))
            .foregroundStyle(Color(hex: selected ? swatch.selectionText : swatch.text))
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.leading, fontSize * 0.375)
        .frame(height: rowHeight)
        .background(selected ? Color(hex: swatch.selectionBackground) : Color.clear)
      }
      HStack {
        // Without a font of its own the popup writes descriptions in the system font.
        Text("Switch branches or restore working tree files")
          .font(family.map { Font.custom($0, size: fontSize) } ?? .system(size: fontSize))
          .italic()
          .lineLimit(1)
        Spacer(minLength: 4)
        Text("⌃k").font(.system(size: rowHeight * 0.5)).italic()
      }
      .foregroundStyle(Color(hex: swatch.description))
      .padding(.horizontal, 5)
      .frame(height: rowHeight)
      .overlay(alignment: .top) { Rectangle().fill(Color(hex: swatch.description).opacity(0.25)).frame(height: 1) }
    }
    .frame(width: width)
    .background(Color(hex: swatch.background))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .shadow(color: .black.opacity(0.35), radius: 3)
    .animation(.easeOut(duration: 0.12), value: fontSize)
    .animation(.easeOut(duration: 0.12), value: width)
  }
}

/// Chooses the popup's font from the fonts installed on this Mac, fixed-pitch ones first.
private struct FontMenu: View {
  @ObservedObject var model: SettingsModel

  private static let defaultLabel = "Default (Monaco)"

  var body: some View {
    let selection = model.text(SettingKey.fontFamily)
    Menu {
      Picker("", selection: selection) {
        Text(Self.defaultLabel).tag("")
      }
      .pickerStyle(.inline)
      .labelsHidden()
      Picker("Fixed width", selection: selection) {
        ForEach(PopupOptions.monospacedFamilies, id: \.self) { Text($0).tag($0) }
      }
      .pickerStyle(.inline)
      Divider()
      Menu("Other Fonts") {
        Picker("", selection: selection) {
          ForEach(PopupOptions.otherFamilies, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    } label: {
      Text(selection.wrappedValue.isEmpty ? Self.defaultLabel : selection.wrappedValue)
    }
    .fixedSize()
  }
}

/// A numeric setting shown as its value with − and + buttons, and a button to go back to the
/// default once it has been changed.
private struct StepperRow: View {
  let title: String
  let option: PopupOptions.Option
  @ObservedObject var model: SettingsModel
  var detail: ((Double) -> String)?

  var body: some View {
    let value = model.value(of: option)
    let isCustom = model.values[option.key] != nil
    LabeledContent(title) {
      HStack(spacing: 8) {
        if let detail {
          Text(detail(value)).foregroundStyle(.tertiary)
        }
        Text(PopupOptions.format(value, unit: option.unit))
          .monospacedDigit()
          .foregroundStyle(isCustom ? .primary : .secondary)
          .frame(minWidth: 56, alignment: .trailing)
        HStack(spacing: 2) {
          Button {
            model.step(option, direction: -1)
          } label: {
            Image(systemName: "minus").frame(width: 14, height: 14)
          }
          .disabled(value <= option.range.lowerBound)
          .help("Smaller")
          Button {
            model.step(option, direction: 1)
          } label: {
            Image(systemName: "plus").frame(width: 14, height: 14)
          }
          .disabled(value >= option.range.upperBound)
          .help("Larger")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Button {
          model.set(option.key, nil)
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .help("Back to the default (\(PopupOptions.format(option.fallback, unit: option.unit)))")
        .opacity(isCustom ? 1 : 0)
        .disabled(!isCustom)
      }
    }
  }
}

/// A theme in the list: three lines of the popup in its colours, and its name.
private struct ThemeTile: View {
  let entry: ThemeEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      VStack(alignment: .leading, spacing: 0) {
        Text("checkout")
          .padding(.horizontal, 6).padding(.vertical, 2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(Color(hex: entry.swatch.selectionText))
          .background(Color(hex: entry.swatch.selectionBackground))
        Text("commit")
          .padding(.horizontal, 6).padding(.vertical, 2)
          .foregroundStyle(Color(hex: entry.swatch.text))
        Text("Record changes")
          .padding(.horizontal, 6).padding(.bottom, 3)
          .foregroundStyle(Color(hex: entry.swatch.description))
          .font(.system(size: 9))
      }
      .font(.system(size: 10, design: .monospaced))
      .background(Color(hex: entry.swatch.background))
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
      HStack(spacing: 4) {
        Text(entry.name).font(.callout).lineLimit(1)
        if entry.isUserTheme { Image(systemName: "person.fill").font(.caption2).foregroundStyle(.secondary) }
      }
    }
    .padding(.vertical, 4)
  }
}

extension Color {
  /// A colour as theme files write them: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(r, g, b)` or
  /// `rgba(r, g, b, a)`. Anything else is grey.
  init(hex: String) {
    if let components = Self.themeColorComponents(hex) {
      self = Color(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
    } else {
      self = .gray
    }
  }

  static func themeColorComponents(_ text: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    var value = text.trimmingCharacters(in: .whitespaces).lowercased()

    if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") {
      let parts = value[value.index(after: open)..<close]
        .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
        .compactMap { Double($0) }
      guard parts.count == 3 || parts.count == 4 else { return nil }
      return (parts[0] / 255, parts[1] / 255, parts[2] / 255, parts.count == 4 ? parts[3] : 1)
    }

    if value.hasPrefix("#") { value.removeFirst() }
    if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
    guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
    let hasAlpha = value.count == 8
    return (
      Double((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255, Double((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
      Double((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255, hasAlpha ? Double(number & 0xff) / 255 : 1
    )
  }
}

// MARK: - Keys

private struct KeysTab: View {
  @ObservedObject var model: SettingsModel
  @State private var newKey = ""
  @State private var newAction = "insertSelected"

  var body: some View {
    Form {
      Section {
        ForEach(Keybindings.defaults, id: \.key) { binding in
          KeyRow(key: binding.key, defaultAction: binding.action, selection: model.action(for: binding.key))
        }
      } header: {
        Text("Default bindings")
      } footer: {
        Text("Keys are only taken from the shell while the popup is visible.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Your bindings") {
        ForEach(model.customBindings, id: \.self) { key in
          HStack {
            KeyRow(key: key, defaultAction: nil, selection: model.action(for: key))
            Button {
              model.set(Keybindings.settingKey(for: key), nil)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
          }
        }
        HStack {
          TextField("Key", text: $newKey, prompt: Text("control+y"))
            .frame(width: 150)
          Picker("", selection: $newAction) {
            ForEach(Keybindings.actions, id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden()
          Button("Add") {
            model.addBinding(key: newKey, action: newAction)
            newKey = ""
          }
          .disabled(Keybindings.normalize(newKey).isEmpty)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct KeyRow: View {
  let key: String
  let defaultAction: String?
  @Binding var selection: String

  var body: some View {
    HStack {
      Text(key).font(.system(.body, design: .monospaced))
      Spacer()
      Picker("", selection: $selection) {
        if let defaultAction {
          Text("Default (\(defaultAction))").tag("")
        }
        ForEach(Keybindings.actions, id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden()
      .frame(width: 260)
    }
  }
}

// MARK: - Setup

private struct SetupTab: View {
  @ObservedObject var model: SettingsModel

  var body: some View {
    Form {
      Section {
        if let status = model.inputMethodStatus {
          StatusRow(title: "In ~/Library/Input Methods", ok: Self.bundleOK(status.bundle), detail: Self.describe(status.bundle))
          StatusRow(title: "Registered", ok: status.registered)
          StatusRow(title: "Enabled", ok: status.enabled)
          StatusRow(title: "Selected", ok: status.selected)
          StatusRow(title: "Running", ok: status.running)
        }
        StatusRow(title: "Connected to Figo", ok: model.isInputMethodConnected)
        HStack {
          Button(model.inputMethodStatus?.bundle == .missing ? "Install" : "Reinstall") { model.installInputMethod() }
          Button("Uninstall") { model.uninstallInputMethod() }
            .disabled(model.inputMethodStatus?.bundle == .missing)
          Spacer()
          if model.isWorking { ProgressView().controlSize(.small) }
          Button("Refresh") { model.refreshInputMethodStatus() }
        }
        .disabled(!model.canInstallInputMethod || model.isWorking)
        if let message = model.setupMessage {
          Text(message).font(.caption).foregroundStyle(.secondary)
        }
      } header: {
        Text("Input method")
      } footer: {
        Text(
          "Figo finds the text cursor through an invisible input method that never handles keys. Terminals that were already open need to be restarted after installing."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear { model.refreshInputMethodStatus() }
  }

  private static func bundleOK(_ state: InputMethodBundleState) -> Bool {
    switch state {
    case .missing: false
    case .link(_, let current): current
    case .copy: true
    }
  }

  private static func describe(_ state: InputMethodBundleState) -> String? {
    switch state {
    case .missing: nil
    case .link(let destination, let current): current ? "linked" : "links to \(destination)"
    case .copy: "copied"
    }
  }
}

private struct StatusRow: View {
  let title: String
  let ok: Bool
  var detail: String?

  var body: some View {
    HStack {
      Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
        .foregroundStyle(ok ? Color.green : Color.secondary)
      Text(title)
      Spacer()
      if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
    }
  }
}

/// The Settings window. The app activates while it is open, which also hides the popup.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private var window: NSWindow?
  private var model: SettingsModel?
  private let makeModel: () -> SettingsModel

  init(makeModel: @escaping () -> SettingsModel) {
    self.makeModel = makeModel
  }

  func show() {
    if window == nil {
      let model = makeModel()
      let window = NSWindow(contentViewController: SettingsTabViewController(model: model))
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.toolbarStyle = .preference
      window.setContentSize(SettingsPane.size)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      self.window = window
      self.model = model
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    model?.detach()
    model = nil
    window = nil
  }
}
