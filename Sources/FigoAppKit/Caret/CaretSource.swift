import FigoCore
import Foundation

/// Where the focused text field's insertion point is, in Cocoa screen coordinates.
public struct CaretReading: Equatable, Sendable {
  public var rect: ScreenRect
  /// The app that answered, when known.
  public var bundleId: String?
  /// Worked out from the window and the character grid rather than reported by the terminal.
  public var isEstimated: Bool

  public init(rect: ScreenRect, bundleId: String?, isEstimated: Bool = false) {
    self.rect = rect
    self.bundleId = bundleId
    self.isEstimated = isEstimated
  }

  /// Clients that have nothing to report answer with an empty rectangle at the origin, which
  /// would put the popup in the screen corner.
  public var isUsable: Bool {
    rect.height > 0 && !(rect.x == 0 && rect.y == 0 && rect.width <= 0)
  }
}

/// Something that can tell where the text cursor of the focused terminal is. v1 has only the
/// input method; an Accessibility-based source can be added beside it later.
@MainActor
public protocol CaretSource: AnyObject {
  /// The caret right now, or nil if it is unknown or the answer took longer than `timeout`.
  func currentCaret(timeout: Duration) async -> CaretReading?
}

/// A caret that never moves, taken from `FIGO_DEBUG_CARET` ("x,y,width,height" in Cocoa screen
/// coordinates). Lets automated tests exercise the popup without a terminal window to measure.
@MainActor
public final class FixedCaretSource: CaretSource {
  private let reading: CaretReading

  public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
    guard let value = environment["FIGO_DEBUG_CARET"] else { return nil }
    let numbers = value.split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4 else { return nil }
    reading = CaretReading(
      rect: ScreenRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), bundleId: nil)
  }

  public func currentCaret(timeout: Duration) async -> CaretReading? {
    reading
  }
}
