import Foundation
import Testing

@testable import FigoInstallKit

/// Only the file placement is exercised here. Registering, enabling and selecting input sources
/// changes the machine's configuration, so it is never done by tests.
@Suite final class InputMethodInstallerTests {
  let root: URL
  let installer: InputMethodInstaller

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("figo-install-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let helper = InputMethodInstaller.helperBundle(inApp: root.appendingPathComponent("Figo.app"))
    try FileManager.default.createDirectory(
      at: helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try Data("binary".utf8).write(to: helper.appendingPathComponent("Contents/MacOS/FigoInputMethod"))
    installer = InputMethodInstaller(
      helperBundle: helper, inputMethodsDirectory: root.appendingPathComponent("Library/Input Methods"))
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  @Test func helperLivesInTheAppsHelpersFolder() {
    let helper = InputMethodInstaller.helperBundle(inApp: URL(fileURLWithPath: "/Applications/Figo.app"))
    #expect(helper.path == "/Applications/Figo.app/Contents/Helpers/FigoInputMethod.app")
    #expect(installer.installedBundle.lastPathComponent == "FigoInputMethod.app")
    #expect(installer.installedBundle.deletingLastPathComponent().lastPathComponent == "Input Methods")
  }

  @Test func symlinksTheHelperAndRecognisesIt() throws {
    #expect(installer.bundleState() == .missing)
    try installer.placeBundle(.symlink)
    #expect(installer.bundleState() == .link(destination: installer.helperBundle.path, current: true))
    // Placing again replaces the link rather than failing.
    try installer.placeBundle(.symlink)
    #expect(installer.bundleState() == .link(destination: installer.helperBundle.path, current: true))
  }

  @Test func detectsALinkToAnotherCopy() throws {
    try FileManager.default.createDirectory(at: installer.inputMethodsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: installer.installedBundle.path, withDestinationPath: "/Old/Figo.app")
    #expect(installer.bundleState() == .link(destination: "/Old/Figo.app", current: false))
    // Dangling links are replaced too.
    try installer.placeBundle(.symlink)
    #expect(installer.bundleState() == .link(destination: installer.helperBundle.path, current: true))
  }

  @Test func copiesWhenAskedTo() throws {
    try installer.placeBundle(.copy)
    #expect(installer.bundleState() == .copy)
    let copied = installer.installedBundle.appendingPathComponent("Contents/MacOS/FigoInputMethod")
    #expect(try String(contentsOf: copied, encoding: .utf8) == "binary")
  }

  @Test func removesWhateverIsPlaced() throws {
    try installer.removePlacedBundle()
    try installer.placeBundle(.copy)
    try installer.removePlacedBundle()
    #expect(installer.bundleState() == .missing)
    try installer.placeBundle(.symlink)
    try installer.removePlacedBundle()
    #expect(installer.bundleState() == .missing)
    #expect(FileManager.default.fileExists(atPath: installer.helperBundle.path), "the app's copy is untouched")
  }

  @Test func refusesAMissingHelper() {
    let missing = InputMethodInstaller(
      helperBundle: root.appendingPathComponent("Nope.app"), inputMethodsDirectory: installer.inputMethodsDirectory)
    #expect(throws: InputMethodError.helperMissing(root.appendingPathComponent("Nope.app").path)) {
      try missing.placeBundle()
    }
  }

  /// The helper's Info.plist (copied into the bundle by scripts/bundle.sh) has to agree with the
  /// identifiers the installer and the helper use.
  @Test func infoPlistMatchesTheIdentity() throws {
    let plistURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/InputMethod-Info.plist")
    let plist = try #require(
      PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
    #expect(plist["CFBundleIdentifier"] as? String == InputMethodIdentity.bundleIdentifier)
    #expect(InputMethodIdentity.bundleIdentifier.contains(".inputmethod."))
    #expect(plist["TISInputSourceID"] as? String == InputMethodIdentity.inputSourceID)
    #expect(plist["InputMethodConnectionName"] as? String == InputMethodIdentity.connectionName)
    #expect(plist["InputMethodServerControllerClass"] as? String == InputMethodIdentity.controllerClassName)
    #expect(plist["InputMethodType"] as? String == "palette")
    #expect(plist["ComponentInvisibleInSystemUI"] as? Bool == true)
    #expect(plist["LSBackgroundOnly"] as? Bool == true)
    #expect(plist["CFBundleExecutable"] as? String == "FigoInputMethod")
  }
}
