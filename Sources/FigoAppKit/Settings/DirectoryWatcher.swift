import CoreServices
import Foundation

/// Calls `onChange` on the main actor whenever anything inside `directory` changes (FSEvents,
/// coalesced over a short latency). Stops when released.
public final class DirectoryWatcher: @unchecked Sendable {
  private final class Callback {
    let onChange: @MainActor () -> Void
    init(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
  }

  private let stream: FSEventStreamRef
  private let queue = DispatchQueue(label: "dev.figo.fsevents")

  public init?(directory: URL, latency: TimeInterval = 0.1, onChange: @escaping @MainActor () -> Void) {
    // The stream owns a reference to the callback, so an event delivered while the watcher is
    // being torn down still finds it alive.
    let callback = Callback(onChange)
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
      retain: { info in
        guard let info else { return nil }
        _ = Unmanaged<Callback>.fromOpaque(info).retain()
        return info
      },
      release: { info in
        guard let info else { return }
        Unmanaged<Callback>.fromOpaque(info).release()
      },
      copyDescription: nil)
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    let handler: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
      let onChange = callback.onChange
      DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
    }
    guard
      let stream = withExtendedLifetime(callback, {
        FSEventStreamCreate(
          nil, handler, &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
          latency, flags)
      })
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
  }

  deinit {
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
