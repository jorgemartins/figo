import AppKit
import WebKit

private let log = Log("web")

/// Where page events go. The web view in the app; a recorder in tests.
@MainActor
public protocol PageSink: AnyObject {
  func deliver(_ event: PageEvent)
}

/// Handles one bridge request from the page.
@MainActor
public protocol BridgeHandler: AnyObject {
  func handle(_ request: BridgeRequest) async throws -> JSONValue
  /// The page started loading again and has forgotten everything it was told.
  func pageWillLoad()
}

/// A web view that takes clicks without first activating the app.
final class PopupWebView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Hosts the popup page: loads it, answers its `figo` message handler, and delivers events by
/// calling `window.__figoReceive`. Events wait in a queue until the page has called `app.ready`.
@MainActor
public final class PopupWebHost: NSObject, PageSink, WKNavigationDelegate {
  /// Events kept while the page is loading. Beyond this the oldest are dropped; a page that
  /// never loads must not grow the queue forever.
  static let queueLimit = 512

  public let webView: WKWebView
  public weak var handler: BridgeHandler?

  private let pageURL: URL
  private var isReady = false
  private var queued: [PageEvent] = []
  private var crashesInARow = 0
  private var lastCrash: Date?

  /// `devURL` replaces the bundled page (`FIGO_WEB_URL`, the Vite dev server). The page keeps
  /// what should survive restarts in `localStorage`; with `persistentStorage` false nothing is
  /// written to disk (WebKit can only persist under `~/Library/WebKit`).
  public init(resolver: ResourceResolver, devURL: URL?, persistentStorage: Bool) {
    let configuration = WKWebViewConfiguration()
    let schemes = ResourceSchemeHandler(resolver: resolver)
    configuration.setURLSchemeHandler(schemes, forURLScheme: "figo")
    configuration.setURLSchemeHandler(schemes, forURLScheme: "fig")
    configuration.websiteDataStore = persistentStorage ? .default() : .nonPersistent()
    configuration.suppressesIncrementalRendering = false
    pageURL = devURL ?? URL(string: "figo://app/index.html")!

    let webView = PopupWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = .clear
    webView.isInspectable = true
    webView.allowsMagnification = false
    webView.allowsBackForwardNavigationGestures = false
    self.webView = webView
    super.init()

    configuration.userContentController.addScriptMessageHandler(
      MessageProxy(host: self), contentWorld: .page, name: "figo")
    webView.navigationDelegate = self
  }

  public func load() {
    log.info("loading \(pageURL.absoluteString)")
    webView.load(URLRequest(url: pageURL))
  }

  public func reload() {
    isReady = false
    load()
  }

  // MARK: - Events

  public func deliver(_ event: PageEvent) {
    guard isReady else {
      queued.append(event)
      if queued.count > Self.queueLimit { queued.removeFirst(queued.count - Self.queueLimit) }
      return
    }
    evaluate(event)
  }

  private func evaluate(_ event: PageEvent) {
    webView.evaluateJavaScript(event.script) { _, error in
      if let error { log.warn("delivering \(event.name) failed: \(error.localizedDescription)") }
    }
  }

  private func flushQueue() {
    isReady = true
    let pending = queued
    queued = []
    pending.forEach(evaluate)
  }

  // MARK: - Requests

  fileprivate func receive(_ body: Any, reply: @escaping @MainActor (Any?, String?) -> Void) {
    let request: BridgeRequest
    do {
      guard let message = JSONValue(foundation: body) else { throw BridgeError("Message is not JSON") }
      request = try BridgeRequest(message: message)
    } catch {
      log.warn("bad bridge message: \(error)")
      reply(nil, "\(error)")
      return
    }
    guard let handler else {
      reply(nil, "The app is shutting down")
      return
    }
    Task {
      do {
        let result = try await handler.handle(request)
        reply(result.foundationObject, nil)
      } catch {
        reply(nil, "\(error)")
      }
      if case .ready = request {
        // After the reply, so the page has its AppInfo before the first event arrives.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.flushQueue() } }
      }
    }
  }

  // MARK: - WKNavigationDelegate

  public func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
    // The popup only ever shows its own page; anything else (a stray link) is refused.
    if !isMainFrame || Self.isSameOrigin(url, pageURL) || url.scheme == "about" {
      decisionHandler(.allow)
    } else {
      log.warn("blocked navigation to \(url.absoluteString)")
      decisionHandler(.cancel)
    }
  }

  public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    isReady = false
    // Keys pressed for the list the old page was showing mean nothing to the new one.
    queued.removeAll { if case .keybinding = $0 { true } else { false } }
    handler?.pageWillLoad()
  }

  public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    log.error("page failed: \(error.localizedDescription)")
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    log.error("page failed to load: \(error.localizedDescription)")
  }

  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    isReady = false
    queued.removeAll { if case .keybinding = $0 { true } else { false } }
    handler?.pageWillLoad()
    // A page that keeps dying must not be reloaded in a tight loop, whether it dies before or
    // after it reports ready. Only a minute without a crash starts the count again.
    let now = Date()
    crashesInARow = lastCrash.map { now.timeIntervalSince($0) < 60 } == true ? crashesInARow + 1 : 1
    lastCrash = now
    let delay = crashesInARow == 1 ? 0 : min(0.5 * pow(2, Double(crashesInARow - 2)), 30)
    log.error("web content process terminated; reloading in \(delay)s")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
    a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
      && a.port == b.port
  }
}

/// WebKit keeps its script message handlers alive; this breaks the cycle with the host.
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandlerWithReply {
  weak var host: PopupWebHost?

  init(host: PopupWebHost) {
    self.host = host
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
  ) {
    guard let host else { return replyHandler(nil, "The app is shutting down") }
    host.receive(message.body, reply: replyHandler)
  }
}
