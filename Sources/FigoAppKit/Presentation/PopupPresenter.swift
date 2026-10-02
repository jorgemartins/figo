import CoreGraphics
import FigoCore
import Foundation

private let log = Log("popup")

/// Why the popup is not on screen.
public enum HideReason: String, Sendable {
  case pageRequested
  case noSession
  case emptyBuffer
  case commandStarted
  case disabled
  case terminalNotFrontmost
  case noCaret
  case appSwitched
  case focusMoved
  case spaceChanged
  case sessionEnded
}

/// What the presenter needs to know about the session the popup belongs to.
public struct PopupTarget: Equatable, Sendable {
  /// The command line is non-blank.
  public var hasText: Bool
  /// The popup only shows while this app is frontmost; nil skips the check.
  public var terminalBundleId: String?
  /// The terminal's process, when known: a more exact form of the same check, and the process
  /// whose window the caret is estimated from.
  public var terminalPid: Int32?
  /// Where the terminal cursor is on the character grid, for estimating the caret when the
  /// terminal does not report it.
  public var cursorCell: GridPosition?
  public var grid: GridSize?

  public init(
    hasText: Bool, terminalBundleId: String?, terminalPid: Int32? = nil, cursorCell: GridPosition? = nil,
    grid: GridSize? = nil
  ) {
    self.hasText = hasText
    self.terminalBundleId = terminalBundleId
    self.terminalPid = terminalPid
    self.cursorCell = cursorCell
    self.grid = grid
  }
}

/// A `window.position` request from the page.
public struct PositionRequest: Codable, Equatable, Sendable {
  public var width: Double
  public var height: Double
  public var anchorX: Double
  public var offsetFromBaseline: Double
  public var dryRun: Bool?

  public init(width: Double, height: Double, anchorX: Double = 0, offsetFromBaseline: Double = 0, dryRun: Bool? = nil) {
    self.width = width
    self.height = height
    self.anchorX = anchorX
    self.offsetFromBaseline = offsetFromBaseline
    self.dryRun = dryRun
  }
}

public struct PositionResult: Codable, Equatable, Sendable {
  public var isAbove: Bool
  public var isClipped: Bool

  public init(isAbove: Bool, isClipped: Bool) {
    self.isAbove = isAbove
    self.isClipped = isClipped
  }
}

/// Decides when the popup is on screen and where. It combines the page's size requests, the
/// caret, the focused terminal window and the screens, and never moves the window itself except
/// through `PopupWindowing`.
@MainActor
public final class PopupPresenter {
  /// Added to the page's `offsetFromBaseline` (the page sends -3, for a 2 pt gap).
  public static let baselinePadding: CGFloat = 5
  public static let floatingLevel = Int(CGWindowLevelForKey(.floatingWindow))

  public var target: PopupTarget?
  public var isDisabled: () -> Bool = { false }
  /// Show the popup even when the terminal is not the frontmost app. For automated tests that
  /// must not take keyboard focus away from whoever is using the machine.
  public var allowsBackgroundTerminal = false
  /// `autocomplete.height`.
  public var decisionHeight: () -> CGFloat = { 140 }
  /// Called on every transition, with the reason when hiding.
  public var onVisibilityChange: ((Bool, HideReason?) -> Void)?
  public var caretTimeout: Duration = .milliseconds(100)
  public var pollInterval: TimeInterval = 0.25
  /// How long a caret reported by the terminal is trusted when later queries go unanswered.
  static let measurementLifetime: TimeInterval = 1.5

  public private(set) var isVisible = false
  /// The window frame while visible, Cocoa coordinates.
  public private(set) var frame: CGRect?
  public private(set) var caret: CaretReading?
  public private(set) var requestedSize: CGSize?

  private let window: PopupWindowing
  private let caretSource: CaretSource
  private let desktop: DesktopEnvironment
  private var anchor = CGPoint(x: 0, y: PopupPresenter.baselinePadding)
  /// The level the next placement wants and the one the window has.
  private var level = PopupPresenter.floatingLevel
  private var currentLevel = PopupPresenter.floatingLevel
  private var measuredAt: Date?
  private var caretTask: Task<Void, Never>?
  private var caretQueryAgain = false
  /// A caret query for the latest command line is in flight; a hidden popup waits for it rather
  /// than flashing at the previous position.
  private var awaitingCaret = false
  private var pollTimer: Timer?

  public init(window: PopupWindowing, caretSource: CaretSource, desktop: DesktopEnvironment) {
    self.window = window
    self.caretSource = caretSource
    self.desktop = desktop
  }

  /// The current session's command line changed (or another session became current).
  public func commandLineChanged() {
    guard let target, target.hasText else {
      hide(.emptyBuffer)
      return
    }
    awaitingCaret = true
    refreshCaret()
  }

  public func position(_ request: PositionRequest) -> PositionResult {
    let size = CGSize(width: request.width, height: request.height)
    let anchor = CGPoint(x: request.anchorX, y: request.offsetFromBaseline + Self.baselinePadding)
    if request.dryRun == true {
      return flags(for: placement(size: size, anchor: anchor))
    }
    requestedSize = size
    self.anchor = anchor
    if Self.isHidingSize(size) {
      hide(.pageRequested)
    } else {
      update()
    }
    return flags(for: placement(size: size, anchor: anchor))
  }

  public func hide(_ reason: HideReason) {
    guard isVisible else { return }
    isVisible = false
    frame = nil
    stopPolling()
    window.hide()
    log.debug("hidden: \(reason.rawValue)")
    onVisibilityChange?(false, reason)
  }

  /// Shows, moves or hides the popup according to the current state.
  public func update() {
    if let reason = blocker() {
      hide(reason)
      return
    }
    if !isVisible && awaitingCaret { return }
    present()
  }

  /// Asks for a fresh caret; the answer repositions the popup.
  public func refreshCaret() {
    if caretTask != nil {
      caretQueryAgain = true
      return
    }
    caretTask = Task { [weak self] in
      guard let self else { return }
      repeat {
        caretQueryAgain = false
        accept(await caretSource.currentCaret(timeout: caretTimeout))
      } while caretQueryAgain
      caretTask = nil
      awaitingCaret = false
      update()
    }
  }

  /// Waits until no caret query is in flight (for tests and the status command).
  func settle() async {
    while let task = caretTask { await task.value }
  }

  private func accept(_ reading: CaretReading?) {
    guard let reading, reading.isUsable else {
      // No answer. A caret measured a moment ago is still better than a guess (one slow reply
      // must not make the popup jump); otherwise fall back to estimating it.
      if let caret, !caret.isEstimated, let measuredAt, Date().timeIntervalSince(measuredAt) < Self.measurementLifetime {
        return
      }
      if let estimate = estimatedCaret() { caret = estimate }
      return
    }
    // A reply from some other app's text field (focus moved) must not drag the popup there.
    if let answered = reading.bundleId, let front = desktop.frontmostApplication?.bundleId, answered != front {
      return
    }
    caret = reading
    measuredAt = Date()
  }

  private func estimatedCaret() -> CaretReading? {
    guard let target, let cell = target.cursorCell, let grid = target.grid else { return nil }
    let front = desktop.frontmostApplication
    // The terminal's own window when its process is known; otherwise whatever is in front.
    guard let pid = target.terminalPid ?? front?.pid, let window = desktop.windows(of: pid)?.bounds else { return nil }
    let bundleId = target.terminalBundleId ?? front?.bundleId
    guard
      let rect = GridCaretEstimate.caret(
        window: window, cell: cell, grid: grid, bundleId: bundleId, flip: CoordinateFlip(screens: desktop.screens))
    else { return nil }
    return CaretReading(rect: ScreenRect(rect), bundleId: bundleId, isEstimated: true)
  }

  private func terminalIsFrontmost(_ target: PopupTarget) -> Bool {
    let front = desktop.frontmostApplication
    if let pid = target.terminalPid, let bundleId = target.terminalBundleId, front?.bundleId == bundleId {
      // Two copies of the same terminal can be running; only the session's own counts.
      return front?.pid == pid
    }
    guard let bundleId = target.terminalBundleId else { return true }
    return front?.bundleId == bundleId
  }

  private func blocker() -> HideReason? {
    guard let size = requestedSize, !Self.isHidingSize(size) else { return .pageRequested }
    guard let target else { return .noSession }
    guard target.hasText else { return .emptyBuffer }
    guard !isDisabled() else { return .disabled }
    if !allowsBackgroundTerminal, !terminalIsFrontmost(target) {
      return .terminalNotFrontmost
    }
    guard caret != nil else { return .noCaret }
    return nil
  }

  private func present() {
    guard let size = requestedSize, let result = placement(size: size, anchor: anchor) else { return }
    if isVisible {
      if result.frame != frame || level != currentLevel {
        window.move(to: result.frame, level: level)
      }
    } else {
      window.show(frame: result.frame, level: level)
      isVisible = true
      startPolling()
      onVisibilityChange?(true, nil)
    }
    frame = result.frame
    currentLevel = level
  }

  /// Where the popup goes for `size` at the last known caret. Also refreshes the window level.
  private func placement(size: CGSize, anchor: CGPoint) -> PopupPlacement.Result? {
    guard let caret else { return nil }
    let windows = desktop.frontmostApplication.flatMap { desktop.windows(of: $0.pid) }
    level = max(Self.floatingLevel, windows?.frontLayer ?? 0)
    return PopupPlacement.place(
      .init(
        caret: CGRect(caret.rect), size: size, anchor: anchor, decisionHeight: decisionHeight(),
        screens: desktop.screens, terminalWindow: windows?.bounds))
  }

  private func flags(for result: PopupPlacement.Result?) -> PositionResult {
    PositionResult(isAbove: result?.isAbove ?? false, isClipped: result?.isClipped ?? false)
  }

  /// The page asks for a 0 or 1 pixel window when it has nothing to show.
  public static func isHidingSize(_ size: CGSize) -> Bool {
    size.width <= 1 || size.height <= 1
  }

  // MARK: - Following the caret

  /// Terminals do not announce scrolling, font changes or window moves, so while the popup is up
  /// the caret and the window are re-read a few times per second.
  private func startPolling() {
    guard pollTimer == nil, pollInterval > 0 else { return }
    let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshCaret() }
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  private func stopPolling() {
    pollTimer?.invalidate()
    pollTimer = nil
  }
}
