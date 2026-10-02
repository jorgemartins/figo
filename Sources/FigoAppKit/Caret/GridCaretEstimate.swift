import CoreGraphics
import FigoCore
import Foundation

/// Estimates where the text cursor is from the terminal window's frame and the cursor's cell.
///
/// The input method gives the exact caret, but it is not always there: it may not be installed
/// yet, a terminal that was already open has to be restarted before it talks to it, and secure
/// keyboard entry shuts it out. Rather than show no popup at all, the caret is then worked out
/// from what is known anyway: the window's bounds, the size of the character grid, and the
/// cell the cursor is in. It assumes one terminal filling the window, so it is off when the
/// window is split into panes, and it is only attempted for stand-alone terminal apps.
public enum GridCaretEstimate {
  /// The parts of a terminal window that are not character cells, in points.
  struct Chrome: Equatable {
    var top: CGFloat
    var left: CGFloat
    var right: CGFloat
    var bottom: CGFloat
  }

  /// Title bar height plus each terminal's default padding around the text.
  static func chrome(for bundleId: String) -> Chrome? {
    switch bundleId {
    case "com.apple.Terminal": return Chrome(top: 28, left: 5, right: 5, bottom: 0)
    case "com.googlecode.iterm2": return Chrome(top: 30, left: 5, right: 5, bottom: 2)
    case "com.mitchellh.ghostty": return Chrome(top: 30, left: 2, right: 2, bottom: 2)
    case "net.kovidgoyal.kitty": return Chrome(top: 28, left: 0, right: 0, bottom: 0)
    case "com.github.wez.wezterm": return Chrome(top: 28, left: 8, right: 8, bottom: 8)
    case "org.alacritty", "io.alacritty": return Chrome(top: 28, left: 0, right: 0, bottom: 0)
    default: return nil
    }
  }

  /// - Parameters:
  ///   - window: The terminal window, Quartz coordinates.
  /// - Returns: The cursor's cell as a rectangle in Cocoa coordinates, or nil when the terminal
  ///   is not one this can be estimated for.
  public static func caret(
    window: CGRect, cell: GridPosition, grid: GridSize, bundleId: String?, flip: CoordinateFlip
  ) -> CGRect? {
    guard let bundleId, let chrome = chrome(for: bundleId), grid.rows > 0, grid.columns > 0 else { return nil }

    let origin: CGPoint
    let cellSize: CGSize
    if let measured = measuredLayout(window: window, grid: grid) {
      (origin, cellSize) = measured
    } else {
      // Plain numbers rather than a CGRect: a rectangle silently turns a negative size positive.
      let contentWidth = window.width - chrome.left - chrome.right
      let contentHeight = window.height - chrome.top - chrome.bottom
      guard contentWidth > 0, contentHeight > 0 else { return nil }
      origin = CGPoint(x: chrome.left, y: chrome.top)
      cellSize = CGSize(width: contentWidth / CGFloat(grid.columns), height: contentHeight / CGFloat(grid.rows))
    }

    let quartz = CGRect(
      x: window.minX + origin.x + CGFloat(cell.column) * cellSize.width,
      y: window.minY + origin.y + CGFloat(cell.row) * cellSize.height, width: 1, height: cellSize.height)
    return flip.flip(quartz)
  }

  /// Where the grid starts inside the window and how big a cell is, when the terminal reports
  /// the pixel size of its text area. That gives the exact cell size, and the grid's position
  /// follows from it: terminals pad the text evenly at the sides, and everything that is not
  /// text (title bar, tab bar) sits above it.
  static func measuredLayout(window: CGRect, grid: GridSize) -> (origin: CGPoint, cellSize: CGSize)? {
    guard let pixelWidth = grid.pixelWidth, let pixelHeight = grid.pixelHeight else { return nil }
    // Terminals report either points or device pixels; take the first reading that fits the window.
    for scale in [1, 2, 3] as [CGFloat] {
      let width = CGFloat(pixelWidth) / scale
      let height = CGFloat(pixelHeight) / scale
      guard width <= window.width + 1, height <= window.height + 1 else { continue }
      let side = max((window.width - width) / 2, 0)
      // More unexplained width than any padding or scroll bar means this is one pane of several.
      guard side <= 40 else { return nil }
      let top = max(window.height - height - side, 0)
      return (CGPoint(x: side, y: top), CGSize(width: width / CGFloat(grid.columns), height: height / CGFloat(grid.rows)))
    }
    return nil
  }
}
