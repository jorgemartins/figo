import CoreGraphics
import FigoCore
import Foundation

@testable import FigoAppKit

@MainActor
final class FakeWindow: PopupWindowing {
  private(set) var isVisible = false
  private(set) var frame: CGRect?
  private(set) var level = 0
  private(set) var showCount = 0
  private(set) var hideCount = 0

  func show(frame: CGRect, level: Int) {
    isVisible = true
    self.frame = frame
    self.level = level
    showCount += 1
  }

  func move(to frame: CGRect, level: Int) {
    self.frame = frame
    self.level = level
  }

  func hide() {
    isVisible = false
    hideCount += 1
  }
}

@MainActor
final class FakeDesktop: DesktopEnvironment {
  var frontmostApplication: RunningApp? = RunningApp(bundleId: "com.mitchellh.ghostty", pid: 42)
  var window: AppWindowInfo?
  /// One 1440×900 display with a 25 pt menu bar and no Dock.
  var screens = [
    ScreenLayout(
      frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
  ]

  func windows(of pid: Int32) -> AppWindowInfo? { window }
}

@MainActor
final class FakeCaretSource: CaretSource {
  var reading: CaretReading?
  private(set) var queries = 0

  func currentCaret(timeout: Duration) async -> CaretReading? {
    queries += 1
    return reading
  }
}

@MainActor
final class PageRecorder: PageSink {
  private(set) var events: [PageEvent] = []

  func deliver(_ event: PageEvent) {
    events.append(event)
  }

  func clear() {
    events = []
  }

  var names: [String] { events.map(\.name) }
}

/// Records what the app sends through a `Channel`.
@MainActor
final class ChannelRecorder<Message: Codable> {
  private(set) var messages: [Message] = []
  private(set) var isClosed = false
  private var nextId = 1

  func channel(id: Int? = nil) -> Channel<Message> {
    let channelId = id ?? nextId
    nextId += 1
    return Channel(
      id: channelId,
      write: { data, completion in
        if let message = try? JSONDecoder().decode(Message.self, from: data) { self.messages.append(message) }
        completion?()
      },
      close: { self.isClosed = true })
  }

  func clear() {
    messages = []
  }
}

/// A fresh directory under the test process's temporary directory.
func makeTemporaryDirectory(_ name: String = #function) throws -> URL {
  let safe = name.filter { $0.isLetter || $0.isNumber }
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("figo-tests-\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

func editBuffer(_ text: String, cursor: Int? = nil, typed: Bool? = nil) -> EditBuffer {
  EditBuffer(
    text: text, cursor: cursor ?? text.utf16.count, cursorCell: GridPosition(row: 0, column: text.count),
    grid: GridSize(rows: 24, columns: 80), typed: typed)
}
