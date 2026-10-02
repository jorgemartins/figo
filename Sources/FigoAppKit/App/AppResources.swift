import FigoCore
import FigoInstallKit
import Foundation

/// Where the bundled page, specs and themes are. Inside Figo.app that is
/// `Contents/Resources/{web,specs,themes}`; `FIGO_RESOURCES_DIR` points elsewhere for development.
public struct AppResources: Sendable {
  public var resources: URL?
  /// The `.app` the executable runs from, if any.
  public var appBundle: URL?

  public static func locate(
    bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> AppResources {
    let appBundle = bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL : nil
    if let override = environment["FIGO_RESOURCES_DIR"], !override.isEmpty {
      return AppResources(resources: URL(fileURLWithPath: override, isDirectory: true), appBundle: appBundle)
    }
    return AppResources(resources: appBundle == nil ? nil : bundle.resourceURL, appBundle: appBundle)
  }

  public var web: URL? { existing("web") }
  public var specs: URL? { existing("specs") }
  public var themes: URL? { existing("themes") }

  /// The input method helper inside the app bundle.
  public var inputMethodHelper: URL? {
    appBundle.map(InputMethodInstaller.helperBundle(inApp:))
  }

  public var resourceRoots: ResourceRoots {
    ResourceRoots(
      web: web, bundledSpecs: specs, userSpecs: FigoPaths.userSpecs, bundledThemes: themes,
      userThemes: FigoPaths.userThemes)
  }

  private func existing(_ name: String) -> URL? {
    guard let url = resources?.appendingPathComponent(name, isDirectory: true),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return url
  }
}
