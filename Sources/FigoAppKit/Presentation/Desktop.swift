import AppKit
import CoreGraphics
import Foundation

public struct RunningApp: Equatable, Sendable {
  public var bundleId: String?
  public var pid: Int32

  public init(bundleId: String?, pid: Int32) {
    self.bundleId = bundleId
    self.pid = pid
  }
}

/// What the presenter needs to know about an app's windows.
public struct AppWindowInfo: Equatable, Sendable {
  /// The app's front normal (layer 0) window, Quartz coordinates.
  public var bounds: CGRect?
  /// The layer of the app's frontmost window. Above 0 for windows such as iTerm2's hotkey
  /// window, which the popup has to float above.
  public var frontLayer: Int

  public init(bounds: CGRect?, frontLayer: Int = 0) {
    self.bounds = bounds
    self.frontLayer = frontLayer
  }
}

/// The parts of the window server the popup logic reads.
@MainActor
public protocol DesktopEnvironment: AnyObject {
  var frontmostApplication: RunningApp? { get }
  func windows(of pid: Int32) -> AppWindowInfo?
  var screens: [ScreenLayout] { get }
}

/// The popup window as the presenter sees it. Frames are Cocoa coordinates.
@MainActor
public protocol PopupWindowing: AnyObject {
  func show(frame: CGRect, level: Int)
  func move(to frame: CGRect, level: Int)
  func hide()
}

/// The real desktop: `NSWorkspace`, `NSScreen` and `CGWindowListCopyWindowInfo`, none of which
/// need a permission for what is read here (bounds and layers, not window titles).
@MainActor
public final class SystemDesktop: DesktopEnvironment {
  /// Windows smaller than this are helpers (drag proxies, invisible key windows), not the terminal.
  private static let minimumWindowSide: CGFloat = 40
  private static let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))

  public init() {}

  public var frontmostApplication: RunningApp? {
    NSWorkspace.shared.frontmostApplication.map {
      RunningApp(bundleId: $0.bundleIdentifier, pid: $0.processIdentifier)
    }
  }

  public func windows(of pid: Int32) -> AppWindowInfo? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
    var frontLayer: Int?
    // The list is ordered front to back.
    for window in list {
      guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
        let layer = window[kCGWindowLayer as String] as? Int, layer >= 0, layer < Self.menuLayer,
        let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
        bounds.width >= Self.minimumWindowSide, bounds.height >= Self.minimumWindowSide
      else { continue }
      if frontLayer == nil { frontLayer = layer }
      if layer == 0 { return AppWindowInfo(bounds: bounds, frontLayer: frontLayer ?? 0) }
    }
    return frontLayer.map { AppWindowInfo(bounds: nil, frontLayer: $0) }
  }

  public var screens: [ScreenLayout] {
    NSScreen.screens.map { ScreenLayout(frame: $0.frame, visibleFrame: $0.visibleFrame) }
  }
}
