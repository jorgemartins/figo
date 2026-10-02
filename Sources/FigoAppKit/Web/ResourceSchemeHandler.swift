import Foundation
import WebKit

private let log = Log("schemes")

/// Serves `figo://` and `fig://` to the popup's web view. Files are read and icons rendered on a
/// background queue; WebKit is answered on the main thread.
@MainActor
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
  private let resolver: ResourceResolver
  private let work = DispatchQueue(label: "dev.figo.resources", qos: .userInitiated)
  /// Tasks WebKit has not cancelled. Answering a stopped task raises an exception.
  private var running = Set<ObjectIdentifier>()
  private let iconCache = NSCache<NSString, NSData>()

  init(resolver: ResourceResolver) {
    self.resolver = resolver
    iconCache.countLimit = 512
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let id = ObjectIdentifier(urlSchemeTask)
    running.insert(id)
    let resolver = self.resolver
    let cacheKey = url.absoluteString
    let cached = iconCache.object(forKey: cacheKey as NSString) as Data?
    nonisolated(unsafe) let task = urlSchemeTask
    work.async { [weak self] in
      let (status, body, contentType) = Self.load(url, resolver: resolver, cachedIcon: cached)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.running.remove(id) != nil else { return }
          if contentType == "image/png", status == 200, cached == nil {
            self.iconCache.setObject(body as NSData, forKey: cacheKey as NSString)
          }
          self.respond(to: task, url: url, status: status, body: body, contentType: contentType)
        }
      }
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    running.remove(ObjectIdentifier(urlSchemeTask))
  }

  private nonisolated static func load(
    _ url: URL, resolver: ResourceResolver, cachedIcon: Data?
  ) -> (Int, Data, String) {
    let text = "text/plain; charset=utf-8"
    switch resolver.resolve(url) {
    case .file(let file, let contentType):
      guard let data = try? Data(contentsOf: file) else { return (500, Data("Unreadable".utf8), text) }
      return (200, data, contentType)
    case .data(let data, let contentType):
      return (200, data, contentType)
    case .icon(let request):
      if let cachedIcon { return (200, cachedIcon, "image/png") }
      guard let png = IconRenderer.png(for: request) else { return (500, Data("No icon".utf8), text) }
      return (200, png, "image/png")
    case .notFound:
      return (404, Data("Not found".utf8), text)
    case .badRequest(let message):
      log.warn("rejected \(url.absoluteString): \(message)")
      return (400, Data(message.utf8), text)
    }
  }

  private func respond(to task: WKURLSchemeTask, url: URL, status: Int, body: Data, contentType: String) {
    let headers = [
      "Content-Type": contentType,
      "Content-Length": String(body.count),
      // The page may be served from the Vite dev server while specs and icons still come from here.
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-cache",
    ]
    log.debug("\(status) \(url.absoluteString) (\(body.count) bytes)")
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    else {
      task.didFailWithError(URLError(.cannotParseResponse))
      return
    }
    task.didReceive(response)
    task.didReceive(body)
    task.didFinish()
  }
}
