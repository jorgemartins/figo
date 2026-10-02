import CoreGraphics
import FigoCore
import Foundation

/// One display, in Cocoa coordinates (points, origin at the bottom-left of the primary display).
public struct ScreenLayout: Equatable, Sendable {
  public var frame: CGRect
  /// The frame minus the menu bar and the Dock.
  public var visibleFrame: CGRect

  public init(frame: CGRect, visibleFrame: CGRect) {
    self.frame = frame
    self.visibleFrame = visibleFrame
  }
}

/// Converts between Cocoa coordinates (y up from the primary display's bottom) and Quartz
/// coordinates (y down from the primary display's top), which is what `CGWindowListCopyWindowInfo`
/// and Accessibility use. The flip is the same in both directions.
public struct CoordinateFlip: Equatable, Sendable {
  /// Height of the primary display (the one with the menu bar, origin 0,0 in both spaces).
  public var primaryHeight: CGFloat

  public init(primaryHeight: CGFloat) {
    self.primaryHeight = primaryHeight
  }

  public init(screens: [ScreenLayout]) {
    let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
    self.init(primaryHeight: primary?.frame.height ?? 0)
  }

  public func flip(_ rect: CGRect) -> CGRect {
    CGRect(x: rect.minX, y: primaryHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
  }
}

/// Places the popup next to the text cursor (research doc 02 §4.2, with Figo's changes: clamping
/// to the visible frame, and hiding for sizes of 1 or less handled by the caller).
public enum PopupPlacement {
  public struct Input: Equatable, Sendable {
    /// The caret, Cocoa coordinates.
    public var caret: CGRect
    /// The window size the page asked for.
    public var size: CGSize
    /// Horizontal shift from the caret and vertical gap from the caret line, padding included.
    public var anchor: CGPoint
    /// The above/below decision uses this rather than the real height, so the side stays put
    /// while the list grows and shrinks (`autocomplete.height`).
    public var decisionHeight: CGFloat
    public var screens: [ScreenLayout]
    /// The focused terminal window, Quartz coordinates, when known.
    public var terminalWindow: CGRect?

    public init(
      caret: CGRect, size: CGSize, anchor: CGPoint, decisionHeight: CGFloat, screens: [ScreenLayout],
      terminalWindow: CGRect? = nil
    ) {
      self.caret = caret
      self.size = size
      self.anchor = anchor
      self.decisionHeight = decisionHeight
      self.screens = screens
      self.terminalWindow = terminalWindow
    }
  }

  public struct Result: Equatable, Sendable {
    /// Where the window goes, Cocoa coordinates.
    public var frame: CGRect
    /// The window is above the caret because it does not fit below.
    public var isAbove: Bool
    /// The window would extend past the right edge of the screen at the caret's x position.
    public var isClipped: Bool
  }

  public static func place(_ input: Input) -> Result {
    let flip = CoordinateFlip(screens: input.screens)
    // All the maths happens top-down, like reading a terminal.
    let caret = flip.flip(input.caret)
    let size = input.size
    let maxHeight = input.decisionHeight

    let screen = input.screens.first { contains($0.frame, caret.origin, flip: flip) }
    let visible = screen.map { flip.flip($0.visibleFrame) }

    var noRoomAbove = false
    var noRoomBelow = false
    if let visible {
      noRoomAbove = visible.minY >= caret.minY - maxHeight
      noRoomBelow = visible.maxY < caret.maxY + maxHeight
    }
    let noRoomInWindow = input.terminalWindow.map { $0.maxY < caret.maxY + maxHeight } ?? false
    let isAbove = !noRoomAbove && (noRoomBelow || noRoomInWindow)

    var x = caret.minX + input.anchor.x
    var y = isAbove ? caret.minY - size.height - input.anchor.y : caret.maxY + input.anchor.y
    var isClipped = false
    if let visible {
      isClipped = caret.minX + size.width > visible.maxX
      // When the window is wider or taller than the screen, its left and top edges win.
      x = max(visible.minX, min(x, visible.maxX - size.width))
      y = max(visible.minY, min(y, visible.maxY - size.height))
    }

    let frame = flip.flip(CGRect(x: x, y: y, width: size.width, height: size.height))
    return Result(frame: frame, isAbove: isAbove, isClipped: isClipped)
  }

  /// Edges inclusive, so a caret on the boundary between two displays still finds one.
  private static func contains(_ cocoaFrame: CGRect, _ point: CGPoint, flip: CoordinateFlip) -> Bool {
    let frame = flip.flip(cocoaFrame)
    return point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
  }
}

extension CGRect {
  public init(_ rect: ScreenRect) {
    self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
  }
}

extension ScreenRect {
  public init(_ rect: CGRect) {
    self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
  }
}
