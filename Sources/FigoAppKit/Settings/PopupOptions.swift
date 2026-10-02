import AppKit
import Foundation

/// The popup's adjustable sizes: their defaults, limits, and how the − and + buttons move them.
public enum PopupOptions {
  public struct Option: Equatable, Sendable {
    public var key: String
    public var fallback: Double
    public var step: Double
    public var range: ClosedRange<Double>
    public var unit: String
  }

  /// The popup's own default is 12.8 pt, an odd value inherited from Fig; stepping from it
  /// lands on whole sizes.
  public static let fontSize = Option(key: SettingKey.fontSize, fallback: 12.8, step: 1, range: 9...24, unit: "pt")
  public static let width = Option(key: SettingKey.width, fallback: 320, step: 20, range: 200...640, unit: "px")
  public static let height = Option(key: SettingKey.height, fallback: 140, step: 20, range: 60...400, unit: "px")

  /// The next value up (`direction` 1) or down (-1) on the option's grid of steps, within its range.
  public static func stepped(_ value: Double, direction: Int, option: Option) -> Double {
    let position = value / option.step
    // A value that is already on the grid moves one whole step; one between two grid lines
    // moves to the nearer line in that direction (12.8 → 13 going up, 12 going down).
    let next = direction > 0 ? (position.rounded(.down) + 1) : (position.rounded(.up) - 1)
    return min(max(next * option.step, option.range.lowerBound), option.range.upperBound)
  }

  public static func format(_ value: Double, unit: String) -> String {
    let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    return "\(number) \(unit)"
  }

  /// How many suggestion rows fit in a popup of this height, leaving room for the description
  /// footer, which is as tall as a row. A row is 1.5625 times the font size.
  public static func visibleRows(height: Double, fontSize: Double) -> Int {
    let rowHeight = fontSize * 1.5625
    return max(Int(((height - rowHeight) / rowHeight).rounded(.down)), 1)
  }

  /// Installed font families that are fixed-pitch, which is what suits a list of commands.
  @MainActor
  public static let monospacedFamilies: [String] = fontFamilies(fixedPitch: true)

  @MainActor
  public static let otherFamilies: [String] = fontFamilies(fixedPitch: false)

  @MainActor
  private static func fontFamilies(fixedPitch: Bool) -> [String] {
    let manager = NSFontManager.shared
    return manager.availableFontFamilies.filter { family in
      // Families starting with a dot are the system's private fonts.
      guard !family.hasPrefix("."), let font = manager.font(withFamily: family, traits: [], weight: 5, size: 12) else {
        return false
      }
      return font.isFixedPitch == fixedPitch
    }
  }
}
