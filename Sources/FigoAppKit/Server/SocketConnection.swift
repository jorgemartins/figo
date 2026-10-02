import Darwin
import FigoCore
import Foundation

/// One accepted client. Reads and writes happen on the connection's own serial queue with
/// non-blocking I/O, so a slow or stuck peer never holds up the main thread or other clients.
public final class SocketConnection: @unchecked Sendable {
  public let id: Int

  private let fd: Int32
  private let queue: DispatchQueue
  private let readSource: DispatchSourceRead
  private let writeSource: DispatchSourceWrite
  private let sourcesCancelled = DispatchGroup()

  // Everything below is only touched on `queue`.
  private var decoder = FrameDecoder()
  private var pending = Data()
  private var writeSourceRunning = false
  private var readSourceStarted = false
  private var flushWaiters: [() -> Void] = []
  private var isClosed = false
  private var onFrame: ((Data) -> Void)?
  private var onClose: (() -> Void)?

  init(id: Int, fd: Int32, target: DispatchQueue) {
    self.id = id
    self.fd = fd
    queue = DispatchQueue(label: "dev.figo.connection.\(id)", target: target)
    readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)

    // The descriptor may only be closed once neither source can touch it any more.
    sourcesCancelled.enter()
    sourcesCancelled.enter()
    readSource.setCancelHandler { [sourcesCancelled] in sourcesCancelled.leave() }
    writeSource.setCancelHandler { [sourcesCancelled] in sourcesCancelled.leave() }
    sourcesCancelled.notify(queue: queue) { Darwin.close(fd) }
  }

  /// Starts reading. `onFrame` receives every complete frame payload and `onClose` runs once
  /// when the connection ends for any reason; both are called on the connection's queue.
  public func start(onFrame: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
    queue.async { [self] in
      self.onFrame = onFrame
      self.onClose = onClose
      readSource.setEventHandler { [weak self] in self?.readAvailable() }
      writeSource.setEventHandler { [weak self] in self?.flush() }
      readSourceStarted = true
      readSource.resume()
    }
  }

  /// Frames `payload` and queues it for writing.
  public func send(_ payload: Data) {
    let frame = Frame.encode(payload)
    queue.async { [self] in
      guard !isClosed else { return }
      pending.append(frame)
      flush()
    }
  }

  /// Runs `body` on the connection's queue once everything sent so far has been written (or the
  /// connection has closed).
  public func whenFlushed(_ body: @escaping () -> Void) {
    queue.async { [self] in
      if pending.isEmpty || isClosed {
        body()
      } else {
        flushWaiters.append(body)
      }
    }
  }

  public func close() {
    queue.async { [self] in shutDown() }
  }

  private func readAvailable() {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while !isClosed {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count > 0 {
        buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        continue
      }
      if count < 0 && errno == EINTR { continue }
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
      // End of stream or a hard error.
      deliverFrames()
      shutDown()
      return
    }
    deliverFrames()
  }

  private func deliverFrames() {
    do {
      while !isClosed, let payload = try decoder.next() {
        onFrame?(payload)
      }
    } catch {
      shutDown()
    }
  }

  private func flush() {
    while !pending.isEmpty && !isClosed {
      let written = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if written > 0 {
        pending.removeFirst(written)
        continue
      }
      if written < 0 && errno == EINTR { continue }
      if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        if !writeSourceRunning {
          writeSourceRunning = true
          writeSource.resume()
        }
        return
      }
      shutDown()
      return
    }
    if writeSourceRunning {
      writeSourceRunning = false
      writeSource.suspend()
    }
    let waiters = flushWaiters
    flushWaiters = []
    waiters.forEach { $0() }
  }

  private func shutDown() {
    guard !isClosed else { return }
    isClosed = true
    pending = Data()
    readSource.cancel()
    writeSource.cancel()
    // A suspended or never-activated source never runs its cancel handler, and releasing one
    // crashes.
    if !readSourceStarted {
      readSourceStarted = true
      readSource.resume()
    }
    if !writeSourceRunning {
      writeSourceRunning = true
      writeSource.resume()
    }
    let waiters = flushWaiters
    flushWaiters = []
    waiters.forEach { $0() }
    let onClose = self.onClose
    self.onClose = nil
    onFrame = nil
    onClose?()
  }

  deinit {
    // Cancelling closes the descriptor once both handlers have run. Sources must never be
    // released while suspended or inactive.
    readSource.cancel()
    writeSource.cancel()
    if !readSourceStarted { readSource.resume() }
    if !writeSourceRunning { writeSource.resume() }
  }
}

/// Accepts connections on a unix socket and hands each one to `onAccept`.
public final class SocketServer: @unchecked Sendable {
  public let path: String

  private let queue = DispatchQueue(label: "dev.figo.server")
  private let connectionQueue = DispatchQueue(label: "dev.figo.connections", attributes: .concurrent)
  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var nextID = 0

  public init(path: String) {
    self.path = path
  }

  /// Binds the socket. `onAccept` is called on a background queue; the connection has not
  /// started reading yet.
  public func start(onAccept: @escaping (SocketConnection) -> Void) throws {
    let fd = try UnixSocket.listen(at: path)
    listenFD = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptPending(onAccept) }
    source.setCancelHandler { Darwin.close(fd) }
    acceptSource = source
    source.resume()
  }

  /// Stops accepting and removes the socket file. Existing connections stay open.
  public func stop() {
    queue.sync {
      guard let source = acceptSource else { return }
      acceptSource = nil
      source.cancel()
      unlink(path)
    }
  }

  private func acceptPending(_ onAccept: (SocketConnection) -> Void) {
    while true {
      let client = Darwin.accept(listenFD, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      var one: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      guard (try? UnixSocket.setNonBlocking(client)) != nil else {
        Darwin.close(client)
        continue
      }
      nextID += 1
      onAccept(SocketConnection(id: nextID, fd: client, target: connectionQueue))
    }
  }
}
