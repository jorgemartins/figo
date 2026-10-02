import AppKit
import FigoCore
import FigoInstallKit

private let log = Log("app")

/// Builds the app at launch and connects AppKit's notifications to `AppCore`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let resources = AppResources.locate()
  private var settings: SettingsStore!
  private var core: AppCore!
  private var server: AppServer?
  private var web: PopupWebHost!
  private var popupWindow: PopupWindowController!
  private var statusItem: StatusItemController!
  private var settingsWindow: SettingsWindowController!
  private var observers: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    settings = SettingsStore(fileURL: FigoPaths.settingsFile)
    settings.reload()
    settings.startWatching()

    let themes = ThemeCatalog(bundled: resources.themes, user: FigoPaths.userThemes)
    let environment = ProcessInfo.processInfo.environment
    let devURL = environment["FIGO_WEB_URL"].flatMap(URL.init(string:))
    // An overridden data directory means a development or test run that must leave the real
    // profile alone, so the page's storage is kept in memory then.
    let isolated = !(environment["FIGO_DATA_DIR"] ?? "").isEmpty
    web = PopupWebHost(
      resolver: ResourceResolver(roots: resources.resourceRoots), devURL: devURL, persistentStorage: !isolated)
    popupWindow = PopupWindowController(content: web.webView)
    core = AppCore(settings: settings, window: popupWindow, desktop: SystemDesktop(), themes: themes)
    core.page = web
    web.handler = core

    settingsWindow = SettingsWindowController { [unowned self] in
      SettingsModel(
        store: settings, themes: themes,
        installer: resources.inputMethodHelper.map { InputMethodInstaller(helperBundle: $0) },
        inputMethodConnected: { [unowned self] in core.inputMethod.isConnected })
    }
    statusItem = StatusItemController(
      statusText: { [unowned self] in statusLine() },
      settings: { [unowned self] in settingsWindow.show() },
      restart: { [unowned self] in restart() })
    statusItem.isVisible = settings.bool(SettingKey.hideMenubarIcon) != true

    core.onQuit = { NSApp.terminate(nil) }
    core.onOpenSettings = { [unowned self] in settingsWindow.show() }
    core.onStatusChange = { [unowned self] in statusItem.refresh() }
    settings.observe { [unowned self] values, changed in applyNativeSettings(values, changed: changed) }

    let server = AppServer(path: FigoPaths.appSocket.path)
    do {
      try server.start(core: core)
      self.server = server
    } catch {
      log.error("cannot listen on \(FigoPaths.appSocket.path): \(error)")
      NSApp.terminate(nil)
      return
    }

    observeWorkspace()
    if resources.web == nil && devURL == nil {
      log.warn("no bundled web page found; the popup will stay empty (set FIGO_WEB_URL or FIGO_RESOURCES_DIR)")
    }
    web.load()
    log.info("Figo \(Figo.version) started (pid \(getpid()))")
  }

  func applicationWillTerminate(_ notification: Notification) {
    server?.stop()
    log.info("quitting")
    // NSApplication exits right after this returns.
    LogSink.shared.flush()
  }

  /// Opening the app again (from the Finder or `open`) shows Settings, the only way back when the
  /// menu-bar icon is hidden.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    settingsWindow.show()
    return false
  }

  // MARK: - Workspace

  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
        [weak self] notification in
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let running = app.map { RunningApp(bundleId: $0.bundleIdentifier, pid: $0.processIdentifier) }
        MainActor.assumeIsolated { self?.core.frontmostApplicationChanged(running) }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.core.activeSpaceChanged() }
      })
  }

  // MARK: - Settings read natively

  private func applyNativeSettings(_ values: [String: JSONValue], changed: Set<String>) {
    if changed.contains(SettingKey.hideMenubarIcon) {
      statusItem.isVisible = values[SettingKey.hideMenubarIcon]?.boolValue != true
    }
    // Only changes made while the app runs are applied; the value found at launch is never
    // acted on, so starting the app cannot add or remove a login item by itself.
    if changed.contains(SettingKey.launchOnStartup), let enabled = values[SettingKey.launchOnStartup]?.boolValue,
      enabled != LaunchAtLogin.isEnabled
    {
      do {
        try LaunchAtLogin.setEnabled(enabled)
      } catch {
        log.error("changing the login item failed: \(error)")
      }
    }
  }

  // MARK: - Menu

  private func statusLine() -> String {
    let count = core.router.sessions.count
    let sessions = count == 1 ? "1 session" : "\(count) sessions"
    let inputMethod = core.inputMethod.isConnected ? "input method connected" : "input method not connected"
    return "Figo \(Figo.version) · \(sessions) · \(inputMethod)"
  }

  /// Starts a fresh copy once this process has exited, with the same environment, then quits.
  private func restart() {
    guard let executable = Bundle.main.executablePath else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; exec \"$0\" >/dev/null 2>&1", executable,
    ]
    do {
      try process.run()
    } catch {
      log.error("restart failed: \(error)")
      return
    }
    NSApp.terminate(nil)
  }
}
