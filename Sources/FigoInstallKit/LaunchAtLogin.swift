import Foundation
import ServiceManagement

/// Starting Figo at login, through the app's own login item (`SMAppService.mainApp`) rather than
/// a LaunchAgent plist. Only ever changed by an explicit user action.
public enum LaunchAtLogin {
  public static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// True when macOS wants the user to approve the login item in System Settings.
  public static var needsApproval: Bool {
    SMAppService.mainApp.status == .requiresApproval
  }

  public static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      guard SMAppService.mainApp.status != .enabled else { return }
      try SMAppService.mainApp.register()
    } else {
      guard SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval else { return }
      try SMAppService.mainApp.unregister()
    }
  }
}
