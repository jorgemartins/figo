import Foundation
import Testing

@testable import FigoAppKit

@Suite final class ResourceResolverTests {
  let root: URL
  let resolver: ResourceResolver

  init() throws {
    root = try makeTemporaryDirectory("resources")
    let roots = ResourceRoots(
      web: root.appendingPathComponent("web"), bundledSpecs: root.appendingPathComponent("specs"),
      userSpecs: root.appendingPathComponent("user/specs"), bundledThemes: root.appendingPathComponent("themes"),
      userThemes: root.appendingPathComponent("user/themes"))
    resolver = ResourceResolver(roots: roots, home: "/Users/someone")
    try put("web/index.html", "<html>")
    try put("web/assets/index-abc.js", "console.log(1)")
    try put("specs/git.js", "bundled git")
    try put("specs/aws/s3.js", "bundled s3")
    try put("specs/index.json", #"{"commit":"abc","completions":["aws/s3","git"],"diffVersionedCompletions":[]}"#)
    try put("user/specs/git.js", "user git")
    try put("user/specs/mytool.js", "user tool")
    try put("user/specs/deploy/index.js", "versioned")
    try put("themes/dusk.json", "bundled dusk")
    try put("themes/moss.json", "bundled moss")
    try put("user/themes/moss.json", "user moss")
    try put("secret.txt", "do not serve")
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  private func put(_ path: String, _ contents: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  private func resolve(_ string: String) -> ResourceResponse {
    resolver.resolve(URL(string: string)!)
  }

  private func body(_ response: ResourceResponse) -> String? {
    guard case .file(let url, _) = response, let data = try? Data(contentsOf: url) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  private func contentType(_ response: ResourceResponse) -> String? {
    switch response {
    case .file(_, let type), .data(_, let type): type
    default: nil
    }
  }

  @Test func servesThePageAndItsAssets() {
    #expect(body(resolve("figo://app/index.html")) == "<html>")
    #expect(body(resolve("figo://app/")) == "<html>")
    #expect(body(resolve("figo://app/assets/index-abc.js")) == "console.log(1)")
    #expect(contentType(resolve("figo://app/assets/index-abc.js")) == "text/javascript; charset=utf-8")
    #expect(contentType(resolve("figo://app/index.html")) == "text/html; charset=utf-8")
  }

  @Test func fallsBackToTheIndexForRoutesButNotForMissingFiles() {
    #expect(body(resolve("figo://app/settings")) == "<html>")
    #expect(resolve("figo://app/missing.js") == .notFound)
  }

  @Test func userSpecsWinOverBundledOnes() {
    #expect(body(resolve("figo://specs/git.js")) == "user git")
    #expect(body(resolve("figo://specs/aws/s3.js")) == "bundled s3")
    #expect(body(resolve("figo://specs/mytool.js")) == "user tool")
    #expect(contentType(resolve("figo://specs/git.js")) == "text/javascript; charset=utf-8")
    #expect(resolve("figo://specs/nope.js") == .notFound)
  }

  @Test func userThemesWinOverBundledOnes() {
    #expect(body(resolve("figo://themes/moss.json")) == "user moss")
    #expect(body(resolve("figo://themes/dusk.json")) == "bundled dusk")
    #expect(contentType(resolve("figo://themes/dusk.json")) == "application/json; charset=utf-8")
    #expect(resolve("figo://themes/dusk.txt") == .notFound)
  }

  @Test func rejectsPathTraversal() {
    for url in [
      "figo://specs/../secret.txt", "figo://specs/%2e%2e/secret.txt", "figo://app/..%2Fsecret.txt",
      "figo://themes/..%2f..%2fsecret.json", "figo://app/assets/../../secret.txt",
    ] {
      guard case .badRequest = resolve(url) else {
        Issue.record("\(url) was not rejected: \(resolve(url))")
        continue
      }
    }
    #expect(ResourceResolver.child(of: root, "a/./b") == nil)
    #expect(ResourceResolver.child(of: root, "") == nil)
    #expect(ResourceResolver.child(of: root, "a//b")?.path == root.appendingPathComponent("a/b").path)
  }

  @Test func mergesUserSpecNamesIntoTheIndex() throws {
    guard case .data(let data, let type) = resolve("figo://specs/index.json") else {
      Issue.record("index.json was not generated")
      return
    }
    #expect(type == "application/json; charset=utf-8")
    let index = try JSONDecoder().decode(JSONValue.self, from: data)
    let completions = index["completions"]?.arrayValue?.compactMap(\.stringValue)
    #expect(completions == ["aws/s3", "deploy", "git", "mytool"])
    #expect(index["diffVersionedCompletions"]?.arrayValue?.compactMap(\.stringValue) == ["deploy"])
    #expect(index["commit"]?.stringValue == "abc")
  }

  @Test func indexWorksWithoutBundledSpecs() throws {
    let bare = ResourceResolver(
      roots: ResourceRoots(
        web: nil, bundledSpecs: nil, userSpecs: root.appendingPathComponent("user/specs"), bundledThemes: nil,
        userThemes: root))
    let index = try JSONDecoder().decode(JSONValue.self, from: bare.specIndex())
    #expect(index["completions"]?.arrayValue?.count == 3)
  }

  @Test func parsesIconURLs() {
    #expect(resolve("fig://icon?type=ts") == .icon(.fileType("ts")))
    #expect(resolve("fig://icon") == .badRequest("Missing type"))
    #expect(resolve("fig://path/Users/someone/My%20Folder/") == .icon(.path("/Users/someone/My Folder/")))
    #expect(resolve("fig://path/~/notes.md") == .icon(.path("/Users/someone/notes.md")))
    #expect(resolve("fig://elsewhere/x") == .notFound)
    #expect(resolve("https://example.com/x") == .notFound)
  }

  @Test func rendersSystemIconsAsPNG() throws {
    let png = try #require(IconRenderer.png(for: .fileType("swift")))
    #expect(png.starts(with: [0x89, 0x50, 0x4e, 0x47]))
    let folder = try #require(IconRenderer.png(for: .path(root.path)))
    #expect(folder.starts(with: [0x89, 0x50, 0x4e, 0x47]))
    #expect(IconRenderer.png(for: .path("/definitely/not/here.unknownext")) != nil)
  }

  @Test func listsThemesFromBothDirectories() {
    let catalog = ThemeCatalog(bundled: root.appendingPathComponent("themes"), user: root.appendingPathComponent("user/themes"))
    #expect(catalog.names() == ["dusk", "moss"])
    #expect(catalog.entries().map(\.isUserTheme) == [false, true])
  }

  @Test func readsThemeSwatches() throws {
    let file = root.appendingPathComponent("swatch.json")
    try Data(
      ##"{"version":"1.0","theme":{"textColor":"#111111","backgroundColor":"#222222","selection":{"backgroundColor":"#333333"}}}"##
        .utf8
    ).write(to: file)
    let swatch = try #require(ThemeCatalog.swatch(at: file))
    #expect(swatch.text == "#111111")
    #expect(swatch.background == "#222222")
    #expect(swatch.selectionBackground == "#333333")
    #expect(swatch.description == ThemeSwatch.dark.description)
  }
}
