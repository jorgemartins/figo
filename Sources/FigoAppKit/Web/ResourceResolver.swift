import Foundation

/// The directories the custom URL schemes serve from.
public struct ResourceRoots: Equatable, Sendable {
  /// The built page (`Contents/Resources/web`).
  public var web: URL?
  public var bundledSpecs: URL?
  public var userSpecs: URL
  public var bundledThemes: URL?
  public var userThemes: URL

  public init(web: URL?, bundledSpecs: URL?, userSpecs: URL, bundledThemes: URL?, userThemes: URL) {
    self.web = web
    self.bundledSpecs = bundledSpecs
    self.userSpecs = userSpecs
    self.bundledThemes = bundledThemes
    self.userThemes = userThemes
  }
}

public enum IconRequest: Equatable, Hashable, Sendable {
  /// `fig://icon?type=<ext>`: the system icon for a file type.
  case fileType(String)
  /// `fig://path/<absolute path>`: the Finder icon of that file or folder.
  case path(String)
}

public enum ResourceResponse: Equatable, Sendable {
  case file(URL, contentType: String)
  case data(Data, contentType: String)
  case icon(IconRequest)
  case notFound
  case badRequest(String)
}

/// Maps `figo://` and `fig://` URLs to what should be served. Pure apart from reading the
/// directories it is given, so it can be tested without a web view.
public struct ResourceResolver: Sendable {
  public let roots: ResourceRoots
  /// Used to expand `~` in icon paths.
  public let home: String

  public init(roots: ResourceRoots, home: String = NSHomeDirectory()) {
    self.roots = roots
    self.home = home
  }

  public func resolve(_ url: URL) -> ResourceResponse {
    switch (url.scheme?.lowercased(), url.host?.lowercased()) {
    case ("figo", "app"): return app(url.path)
    case ("figo", "specs"): return specs(url.path)
    case ("figo", "themes"): return themes(url.path)
    case ("fig", "icon"): return fileTypeIcon(url)
    case ("fig", "path"): return pathIcon(url)
    default: return .notFound
    }
  }

  // MARK: - figo://app

  private func app(_ path: String) -> ResourceResponse {
    guard let web = roots.web else { return .notFound }
    let relative = path.isEmpty || path == "/" ? "index.html" : path
    guard let file = Self.child(of: web, relative) else { return .badRequest("Invalid path") }
    if Self.isFile(file) { return .file(file, contentType: Self.contentType(for: file)) }
    // The page is a single-page app: unknown routes without an extension get the page itself.
    if file.pathExtension.isEmpty, let index = Self.child(of: web, "index.html"), Self.isFile(index) {
      return .file(index, contentType: Self.contentType(for: index))
    }
    return .notFound
  }

  // MARK: - figo://specs

  private func specs(_ path: String) -> ResourceResponse {
    if path == "/index.json" {
      return .data(specIndex(), contentType: Self.contentType(forExtension: "json"))
    }
    return firstFile(path, in: [roots.userSpecs, roots.bundledSpecs])
  }

  /// The bundled index with the user's own specs merged into `completions`. A user spec named
  /// like a bundled one simply replaces it when loaded, so names are de-duplicated.
  public func specIndex() -> Data {
    var index: [String: JSONValue] = [:]
    if let bundled = roots.bundledSpecs.flatMap({ Self.child(of: $0, "index.json") }),
      let data = try? Data(contentsOf: bundled),
      let object = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue
    {
      index = object
    }
    var completions = Set((index["completions"]?.arrayValue ?? []).compactMap(\.stringValue))
    var versioned = Set((index["diffVersionedCompletions"]?.arrayValue ?? []).compactMap(\.stringValue))
    for name in userSpecNames() {
      // A folder with an index.js is one spec split by CLI version.
      if name == "index" { continue }
      if name.hasSuffix("/index") {
        let folder = String(name.dropLast("/index".count))
        completions.insert(folder)
        versioned.insert(folder)
      } else {
        completions.insert(name)
      }
    }
    index["completions"] = .array(completions.sorted().map(JSONValue.string))
    index["diffVersionedCompletions"] = .array(versioned.sorted().map(JSONValue.string))
    return Data(JSONValue.object(index).jsonText(sortedKeys: true).utf8)
  }

  /// Spec names (paths without `.js`) under the user's spec directory.
  public func userSpecNames() -> [String] {
    // The path-based enumerator yields paths relative to the root, which stay correct even when
    // the root sits behind a symbolic link (/var → /private/var).
    guard let enumerator = FileManager.default.enumerator(atPath: roots.userSpecs.path) else { return [] }
    var names: [String] = []
    for case let relative as String in enumerator where relative.hasSuffix(".js") {
      guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
      names.append(String(relative.dropLast(".js".count)))
    }
    return names.sorted()
  }

  // MARK: - figo://themes

  private func themes(_ path: String) -> ResourceResponse {
    guard path.hasSuffix(".json") else { return .notFound }
    return firstFile(path, in: [roots.userThemes, roots.bundledThemes])
  }

  // MARK: - fig://

  private func fileTypeIcon(_ url: URL) -> ResourceResponse {
    let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "type" }?.value
    guard let type, !type.isEmpty else { return .badRequest("Missing type") }
    return .icon(.fileType(type))
  }

  private func pathIcon(_ url: URL) -> ResourceResponse {
    // `URL.path` drops a trailing slash, which is how the page marks folders that may not exist.
    let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    var path = encoded.removingPercentEncoding ?? url.path
    if path.hasPrefix("/~") { path.removeFirst() }
    if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
    guard path.hasPrefix("/") else { return .badRequest("Not an absolute path") }
    return .icon(.path(path))
  }

  // MARK: - Helpers

  private func firstFile(_ path: String, in directories: [URL?]) -> ResourceResponse {
    for directory in directories.compactMap({ $0 }) {
      guard let file = Self.child(of: directory, path) else { return .badRequest("Invalid path") }
      if Self.isFile(file) { return .file(file, contentType: Self.contentType(for: file)) }
    }
    return .notFound
  }

  /// `relative` inside `root`, or nil if it tries to leave it (`..`) or is empty. `relative` is
  /// already percent-decoded, so `%2e%2e` arrives here as `..` and is rejected too.
  public static func child(of root: URL, _ relative: String) -> URL? {
    let components = relative.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty,
      !components.contains(where: { $0 == ".." || $0 == "." || $0.contains("\0") || $0.contains("\\") })
    else { return nil }
    return root.appendingPathComponent(components.joined(separator: "/"))
  }

  private static func isFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  public static func contentType(for url: URL) -> String {
    contentType(forExtension: url.pathExtension)
  }

  public static func contentType(forExtension pathExtension: String) -> String {
    switch pathExtension.lowercased() {
    case "html", "htm": "text/html; charset=utf-8"
    // Specs are loaded with dynamic import(), which insists on a JavaScript MIME type.
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "json", "map": "application/json; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "txt": "text/plain; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "ico": "image/x-icon"
    case "woff": "font/woff"
    case "woff2": "font/woff2"
    case "ttf": "font/ttf"
    case "otf": "font/otf"
    case "wasm": "application/wasm"
    default: "application/octet-stream"
    }
  }
}
