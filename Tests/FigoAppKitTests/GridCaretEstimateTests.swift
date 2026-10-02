import CoreGraphics
import FigoCore
import Testing

@testable import FigoAppKit

@Suite struct GridCaretEstimateTests {
  private let flip = CoordinateFlip(primaryHeight: 1000)

  @Test func placesTheCellInsideTheWindowContent() throws {
    // A Ghostty window at (100, 200), 804 x 432: 30 pt of title bar, 2 pt of padding.
    let window = CGRect(x: 100, y: 200, width: 804, height: 432)
    let caret = try #require(
      GridCaretEstimate.caret(
        window: window, cell: GridPosition(row: 3, column: 10), grid: GridSize(rows: 20, columns: 80),
        bundleId: "com.mitchellh.ghostty", flip: flip))
    // Cells are 10 x 20 pt. Column 10 starts 100 pt into the content; row 3 starts 60 pt down.
    #expect(abs(caret.minX - (100 + 2 + 100)) < 0.001)
    #expect(abs(caret.height - 20) < 0.001)
    // Quartz top of the cell is 200 + 30 + 60 = 290, so its Cocoa bottom is 1000 - 290 - 20.
    #expect(abs(caret.minY - 690) < 0.001)
  }

  @Test func usesTheReportedPixelSizeWhenThereIsOne() throws {
    // 110 x 28 cells reported as 1430 x 812 device pixels on a 2x display: cells of 6.5 x 14.5 pt.
    // The window is 723 x 454 pt, so 4 pt of padding each side and 44 pt of title bar above.
    let window = CGRect(x: 700, y: 100, width: 723, height: 454)
    let grid = GridSize(rows: 28, columns: 110, pixelWidth: 1430, pixelHeight: 812)
    let caret = try #require(
      GridCaretEstimate.caret(
        window: window, cell: GridPosition(row: 1, column: 5), grid: grid, bundleId: "com.mitchellh.ghostty", flip: flip))
    #expect(abs(caret.minX - (700 + 4 + 5 * 6.5)) < 0.001)
    #expect(abs(caret.height - 14.5) < 0.001)
    // Quartz top: 100 + (454 - 406 - 4) + 14.5 = 158.5.
    #expect(abs(caret.minY - (1000 - 158.5 - 14.5)) < 0.001)
  }

  @Test func ignoresPixelSizesThatDoNotFitTheWindow() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    // Half the window's width: a split pane. No measured layout; the table is used instead.
    let split = GridSize(rows: 30, columns: 50, pixelWidth: 800, pixelHeight: 1100)
    #expect(GridCaretEstimate.measuredLayout(window: window, grid: split) == nil)
    let points = GridSize(rows: 30, columns: 100, pixelWidth: 790, pixelHeight: 560)
    #expect(GridCaretEstimate.measuredLayout(window: window, grid: points)?.cellSize.width == 7.9)
  }

  @Test func unknownAppsAreNotEstimated() {
    let window = CGRect(x: 0, y: 0, width: 800, height: 600)
    #expect(GridCaretEstimate.caret(
      window: window, cell: GridPosition(row: 0, column: 0), grid: GridSize(rows: 24, columns: 80),
      bundleId: "com.microsoft.VSCode", flip: flip) == nil)
    #expect(GridCaretEstimate.caret(
      window: window, cell: GridPosition(row: 0, column: 0), grid: GridSize(rows: 24, columns: 80),
      bundleId: nil, flip: flip) == nil)
  }

  @Test func degenerateInputsAreRejected() {
    #expect(GridCaretEstimate.caret(
      window: CGRect(x: 0, y: 0, width: 4, height: 10), cell: GridPosition(row: 0, column: 0),
      grid: GridSize(rows: 24, columns: 80), bundleId: "com.apple.Terminal", flip: flip) == nil)
    #expect(GridCaretEstimate.caret(
      window: CGRect(x: 0, y: 0, width: 800, height: 600), cell: GridPosition(row: 0, column: 0),
      grid: GridSize(rows: 0, columns: 0), bundleId: "com.apple.Terminal", flip: flip) == nil)
  }
}
