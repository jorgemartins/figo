import CoreGraphics
import FigoCore
import Testing

@testable import FigoAppKit

@MainActor
@Suite struct PresenterTests {
  let window = FakeWindow()
  let desktop = FakeDesktop()
  let caret = FakeCaretSource()
  let presenter: PopupPresenter
  var transitions: [(Bool, HideReason?)] { recorder.transitions }
  private let recorder = TransitionRecorder()

  @MainActor
  final class TransitionRecorder {
    var transitions: [(Bool, HideReason?)] = []
  }

  init() {
    presenter = PopupPresenter(window: window, caretSource: caret, desktop: desktop)
    presenter.pollInterval = 0
    let recorder = self.recorder
    presenter.onVisibilityChange = { visible, reason in recorder.transitions.append((visible, reason)) }
    // Ghostty's caret, as the input method reports it: Cocoa coordinates.
    caret.reading = CaretReading(rect: ScreenRect(x: 200, y: 586, width: 1, height: 14), bundleId: "com.mitchellh.ghostty")
  }

  private func type(_ text: String = "git ") async {
    presenter.target = PopupTarget(hasText: !text.trimmingCharacters(in: .whitespaces).isEmpty, terminalBundleId: "com.mitchellh.ghostty")
    presenter.commandLineChanged()
    await presenter.settle()
  }

  private func requestSize(_ width: Double = 320, _ height: Double = 140) -> PositionResult {
    presenter.position(PositionRequest(width: width, height: height, anchorX: 0, offsetFromBaseline: -3))
  }

  @Test func showsOnceTheBufferTheSizeAndTheCaretAreKnown() async {
    await type()
    #expect(!window.isVisible, "no size requested yet")
    let result = requestSize()
    #expect(window.isVisible)
    #expect(result == PositionResult(isAbove: false, isClipped: false))
    // Caret top in Quartz: 900 - 586 - 14 = 300; 2 pt below its bottom; converted back to Cocoa.
    #expect(window.frame == CGRect(x: 200, y: 900 - 316 - 140, width: 320, height: 140))
    #expect(window.level == PopupPresenter.floatingLevel)
    #expect(transitions.map(\.0) == [true])
  }

  @Test func estimatesTheCaretWhenTheTerminalDoesNotReportIt() async {
    caret.reading = nil
    desktop.window = AppWindowInfo(bounds: CGRect(x: 100, y: 100, width: 804, height: 432))
    presenter.target = PopupTarget(
      hasText: true, terminalBundleId: "com.mitchellh.ghostty", cursorCell: GridPosition(row: 3, column: 10),
      grid: GridSize(rows: 20, columns: 80))
    presenter.commandLineChanged()
    await presenter.settle()
    _ = requestSize()
    #expect(window.isVisible)
    #expect(presenter.caret?.isEstimated == true)
    #expect(abs((presenter.caret?.rect.x ?? 0) - 202) < 0.001)

    // As soon as the terminal reports a caret, that is used instead.
    caret.reading = CaretReading(rect: ScreenRect(x: 300, y: 586, width: 1, height: 14), bundleId: "com.mitchellh.ghostty")
    presenter.commandLineChanged()
    await presenter.settle()
    #expect(presenter.caret?.isEstimated == false)
    #expect(presenter.caret?.rect.x == 300)

    // And one missed answer right afterwards does not fall back to the estimate.
    caret.reading = nil
    presenter.commandLineChanged()
    await presenter.settle()
    #expect(presenter.caret?.rect.x == 300)
  }

  @Test func staysHiddenWithoutAnyCaretForUnknownTerminals() async {
    caret.reading = nil
    desktop.frontmostApplication = RunningApp(bundleId: "com.example.editor", pid: 42)
    presenter.target = PopupTarget(
      hasText: true, terminalBundleId: "com.example.editor", cursorCell: GridPosition(row: 0, column: 0),
      grid: GridSize(rows: 20, columns: 80))
    presenter.commandLineChanged()
    await presenter.settle()
    _ = requestSize()
    #expect(!window.isVisible)
  }

  @Test func sizeOfOneOrLessHides() async {
    await type()
    _ = requestSize()
    _ = requestSize(1, 1)
    #expect(!window.isVisible)
    #expect(transitions.last?.1 == .pageRequested)
    // A later edit buffer does not bring it back until the page asks for a real size.
    await type("git c")
    #expect(!window.isVisible)
    _ = requestSize(0, 80)
    #expect(!window.isVisible)
  }

  @Test func hidesOnABlankBuffer() async {
    await type()
    _ = requestSize()
    await type("   ")
    #expect(!window.isVisible)
    #expect(transitions.last?.1 == .emptyBuffer)
  }

  @Test func staysHiddenWhileAnotherAppIsFrontmost() async {
    desktop.frontmostApplication = RunningApp(bundleId: "com.apple.Safari", pid: 9)
    await type()
    _ = requestSize()
    #expect(!window.isVisible)
    desktop.frontmostApplication = RunningApp(bundleId: "com.mitchellh.ghostty", pid: 42)
    await type("git s")
    #expect(window.isVisible)
  }

  @Test func skipsTheFrontmostCheckWhenTheTerminalIsUnknown() async {
    desktop.frontmostApplication = RunningApp(bundleId: "com.example.unknown", pid: 9)
    caret.reading?.bundleId = nil
    presenter.target = PopupTarget(hasText: true, terminalBundleId: nil)
    presenter.commandLineChanged()
    await presenter.settle()
    _ = requestSize()
    #expect(window.isVisible)
  }

  @Test func aSessionInAnUnknownTerminalOnlyShowsOverATerminal() async {
    // Inside tmux: the terminal is one of the ones sessions were started from, never a browser.
    var target = PopupTarget(hasText: true, terminalBundleId: nil)
    target.possibleTerminalBundleIds = ["com.mitchellh.ghostty", "com.apple.Terminal"]
    desktop.frontmostApplication = RunningApp(bundleId: "com.apple.Safari", pid: 9)
    caret.reading?.bundleId = nil
    presenter.target = target
    presenter.commandLineChanged()
    await presenter.settle()
    _ = requestSize()
    #expect(!window.isVisible)

    desktop.frontmostApplication = RunningApp(bundleId: "com.apple.Terminal", pid: 10)
    presenter.commandLineChanged()
    await presenter.settle()
    #expect(window.isVisible)
  }

  @Test func respectsTheDisableSetting() async {
    var disabled = true
    presenter.isDisabled = { disabled }
    await type()
    _ = requestSize()
    #expect(!window.isVisible)
    disabled = false
    presenter.update()
    #expect(window.isVisible)
    disabled = true
    presenter.update()
    #expect(!window.isVisible)
    #expect(transitions.last?.1 == .disabled)
  }

  @Test func needsACaretBeforeShowing() async {
    caret.reading = nil
    await type()
    _ = requestSize()
    #expect(!window.isVisible)
    #expect(presenter.caret == nil)
  }

  @Test func ignoresCaretsFromOtherAppsAndUnusableRects() async {
    await type()
    _ = requestSize()
    let before = window.frame
    caret.reading = CaretReading(rect: ScreenRect(x: 900, y: 100, width: 1, height: 14), bundleId: "com.apple.Safari")
    await type("git l")
    #expect(window.frame == before)
    caret.reading = CaretReading(rect: ScreenRect(x: 0, y: 0, width: 0, height: 0), bundleId: "com.mitchellh.ghostty")
    await type("git lo")
    #expect(window.frame == before)
  }

  @Test func keepsTheCaretForSizeChangesAndTheSizeForCaretChanges() async {
    await type()
    _ = requestSize(320, 140)
    _ = requestSize(400, 60)
    #expect(window.frame?.origin.x == CGFloat(200))
    #expect(window.frame?.size == CGSize(width: 400, height: 60))

    caret.reading = CaretReading(rect: ScreenRect(x: 260, y: 586, width: 1, height: 14), bundleId: "com.mitchellh.ghostty")
    await type("git log")
    #expect(window.frame == CGRect(x: 260, y: 900 - 316 - 60, width: 400, height: 60))
  }

  @Test func dryRunsDoNotMoveTheWindow() async {
    await type()
    _ = requestSize()
    let frame = window.frame
    let result = presenter.position(PositionRequest(width: 1500, height: 140, dryRun: true))
    #expect(result.isClipped)
    #expect(window.frame == frame)
    #expect(presenter.requestedSize == CGSize(width: 320, height: 140))
  }

  @Test func aPageThatWentAwayHidesAndStaysHiddenUntilTheNextOneAsks() async {
    await type()
    _ = requestSize()
    #expect(window.isVisible)

    presenter.pageUnloaded()
    #expect(!window.isVisible)
    #expect(transitions.last?.1 == .pageUnloaded)
    // Typing on does not bring back what the old page had asked for.
    await type("git c")
    #expect(!window.isVisible)
    _ = requestSize()
    #expect(window.isVisible)
  }

  @Test func appInitiatedHidesReportTheReason() async {
    await type()
    _ = requestSize()
    presenter.hide(.appSwitched)
    presenter.hide(.appSwitched)
    #expect(!window.isVisible)
    #expect(window.hideCount == 1)
    #expect(transitions.map(\.1) == [nil, .appSwitched])
  }

  @Test func floatsAboveHigherLevelTerminalWindows() async {
    desktop.window = AppWindowInfo(bounds: CGRect(x: 0, y: 0, width: 1440, height: 400), frontLayer: 8)
    await type()
    _ = requestSize()
    #expect(window.level == 8)
  }
}
