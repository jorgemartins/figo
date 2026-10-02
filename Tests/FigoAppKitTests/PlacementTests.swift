import CoreGraphics
import Testing

@testable import FigoAppKit

@Suite struct PlacementTests {
  /// A 1440×900 display with a 25 pt menu bar and a 70 pt Dock at the bottom.
  static let laptop = ScreenLayout(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))

  static func input(
    caretTopLeft: CGPoint, caretHeight: CGFloat = 14, size: CGSize = CGSize(width: 320, height: 140),
    screens: [ScreenLayout] = [laptop], window: CGRect? = nil
  ) -> PopupPlacement.Input {
    // Written in top-down terms (like a terminal) and converted, so the tests read naturally.
    let flip = CoordinateFlip(screens: screens)
    let caret = flip.flip(CGRect(x: caretTopLeft.x, y: caretTopLeft.y, width: 1, height: caretHeight))
    return PopupPlacement.Input(
      caret: caret, size: size, anchor: CGPoint(x: 0, y: 2), decisionHeight: 140, screens: screens,
      terminalWindow: window)
  }

  static func topLeft(_ result: PopupPlacement.Result, screens: [ScreenLayout] = [laptop]) -> CGPoint {
    CoordinateFlip(screens: screens).flip(result.frame).origin
  }

  @Test func flipsBetweenCocoaAndQuartz() {
    let flip = CoordinateFlip(primaryHeight: 900)
    let quartz = CGRect(x: 10, y: 100, width: 50, height: 20)
    let cocoa = flip.flip(quartz)
    #expect(cocoa == CGRect(x: 10, y: 780, width: 50, height: 20))
    #expect(flip.flip(cocoa) == quartz)
  }

  @Test func placesBelowTheCaretWithTheGap() {
    let result = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 200, y: 300)))
    #expect(!result.isAbove)
    #expect(!result.isClipped)
    #expect(Self.topLeft(result) == CGPoint(x: 200, y: 316))  // 300 + 14 + 2
    #expect(result.frame.size == CGSize(width: 320, height: 140))
  }

  @Test func placesAboveWhenTheVisibleFrameHasNoRoomBelow() {
    // The Dock starts at y = 830 (top-down); 700 + 14 + 140 crosses it.
    let result = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 200, y: 700)))
    #expect(result.isAbove)
    #expect(Self.topLeft(result) == CGPoint(x: 200, y: 700 - 140 - 2))
  }

  @Test func decidesWithTheHeightSettingNotTheActualHeight() {
    // A 40 pt list would fit below, but the decision uses autocomplete.height (140).
    let result = PopupPlacement.place(
      Self.input(caretTopLeft: CGPoint(x: 200, y: 700), size: CGSize(width: 320, height: 40)))
    #expect(result.isAbove)
    #expect(Self.topLeft(result).y == CGFloat(700 - 40 - 2))
  }

  @Test func placesAboveNearTheBottomOfTheTerminalWindow() {
    let window = CGRect(x: 100, y: 100, width: 800, height: 450)  // bottom at 550
    let result = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 200, y: 500), window: window))
    #expect(result.isAbove)
  }

  @Test func staysBelowWhenThereIsNoRoomAboveEither() {
    let screen = ScreenLayout(
      frame: CGRect(x: 0, y: 0, width: 1440, height: 200), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 175))
    let result = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 10, y: 60), screens: [screen]))
    #expect(!result.isAbove)
    // Clamped so the bottom edge stays on the visible frame.
    #expect(Self.topLeft(result, screens: [screen]).y == CGFloat(200 - 140))
  }

  @Test func clampsToTheRightEdgeAndReportsClipping() {
    let result = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 1300, y: 300)))
    #expect(result.isClipped)
    #expect(Self.topLeft(result).x == CGFloat(1440 - 320))
  }

  @Test func clampsBelowTheMenuBar() {
    // Caret in the menu bar band (y 0…25): placed below, never above the visible frame's top.
    let result = PopupPlacement.place(
      Self.input(caretTopLeft: CGPoint(x: 10, y: 0), size: CGSize(width: 320, height: 140)))
    #expect(!result.isAbove)
    #expect(Self.topLeft(result).y >= CGFloat(25))
  }

  @Test func leftEdgeWinsWhenTheWindowIsWiderThanTheScreen() {
    let result = PopupPlacement.place(
      Self.input(caretTopLeft: CGPoint(x: 100, y: 100), size: CGSize(width: 2000, height: 140)))
    #expect(Self.topLeft(result).x == CGFloat(0))
  }

  @Test func anchorShiftsHorizontally() {
    var input = Self.input(caretTopLeft: CGPoint(x: 600, y: 300))
    input.anchor.x = -200
    #expect(Self.topLeft(PopupPlacement.place(input)).x == CGFloat(400))
  }

  @Test func usesTheScreenUnderTheCaretOnASecondDisplay() {
    // A 1920×1080 display to the right of the laptop, top-aligned (Cocoa y = 900 - 1080 = -180).
    let external = ScreenLayout(
      frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1055))
    let screens = [Self.laptop, external]
    // Near the bottom of the external display (top-down y 1000): no room below there.
    let below = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 2000, y: 1000), screens: screens))
    #expect(below.isAbove)
    // Near its right edge: clipped against the external display, not the laptop.
    let right = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 3300, y: 200), screens: screens))
    #expect(right.isClipped)
    #expect(Self.topLeft(right, screens: screens).x == CGFloat(1440 + 1920 - 320))
  }

  @Test func handlesADisplayAboveThePrimary() {
    // Cocoa y grows upwards, so a display above the laptop has origin y = 900.
    let above = ScreenLayout(
      frame: CGRect(x: 0, y: 900, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 900))
    let screens = [Self.laptop, above]
    let result = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 100, y: -500), screens: screens))
    #expect(!result.isAbove)
    #expect(Self.topLeft(result, screens: screens) == CGPoint(x: 100, y: -500 + 14 + 2))
    #expect(result.frame.minY > CGFloat(900))  // on the upper display in Cocoa terms
  }

  @Test func leavesOffscreenCaretsUnclamped() {
    let result = PopupPlacement.place(Self.input(caretTopLeft: CGPoint(x: 5000, y: 300)))
    #expect(!result.isClipped)
    #expect(Self.topLeft(result).x == CGFloat(5000))
  }
}
