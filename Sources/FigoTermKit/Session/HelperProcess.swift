import Darwin
import FigoCore
import Foundation

/// Runs programs on behalf of completion generators (`git branch`, `npm run`, …).
///
/// They run here, in the wrapper, rather than in the app for two reasons: they get the shell's
/// own environment and working directory, and macOS attributes their file access to the terminal
/// the user already trusts instead of prompting on behalf of Figo.
enum HelperProcess {
  static let defaultTimeoutMilliseconds = 60_000
  static let maximumTimeoutMilliseconds = 600_000
  /// Output beyond this is cut off; a generator has no use for more.
  private static let maxOutputBytes = 8 * 1024 * 1024

  /// Variables that make programs colourise or page their output, which generators cannot parse.
  private static let removedVariables = ["LS_COLORS", "CLICOLOR_FORCE", "CLICOLOR", "COLORTERM"]

  static func environment(shell: [String: String], overrides: [String: String?]) -> [String: String] {
    var environment = shell
    for name in removedVariables { environment[name] = nil }
    // Shell integration scripts check this and stay out of the way in helper shells.
    environment["FIGO_HELPER"] = "1"
    environment["HISTFILE"] = ""
    environment["HISTCONTROL"] = "ignoreboth"
    environment["TERM"] = "xterm-256color"
    environment["NO_COLOR"] = "1"
    for (name, value) in overrides { environment[name] = value }
    return environment
  }

  static func resolveDirectory(_ requested: String?, shellDirectory: String?, home: String?) -> String {
    for candidate in [requested.map { expandTilde($0, home: home) }, shellDirectory] {
      guard let candidate else { continue }
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
        return candidate
      }
    }
    return FileManager.default.currentDirectoryPath
  }

  static func expandTilde(_ path: String, home: String?) -> String {
    guard let home, path == "~" || path.hasPrefix("~/") else { return path }
    return home + path.dropFirst()
  }

  /// Finds `name` the way a shell would: as given when it contains a slash, otherwise in `PATH`.
  static func resolveExecutable(_ name: String, path: String?, directory: String) -> String {
    if name.contains("/") {
      return name.hasPrefix("/") ? name : directory + "/" + name
    }
    for entry in (path ?? "/usr/bin:/bin").split(separator: ":") {
      let candidate = (entry.hasPrefix("/") ? String(entry) : directory + "/" + entry) + "/" + name
      var info = stat()
      if stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(candidate, X_OK) == 0 {
        return candidate
      }
    }
    return name
  }

  /// Runs the request to completion. Blocks; call from a background thread.
  static func run(_ request: ProcessRequest, shellEnvironment: [String: String], shellDirectory: String?) -> TerminalReply {
    let environment = environment(shell: shellEnvironment, overrides: request.environment)
    let directory = resolveDirectory(request.workingDirectory, shellDirectory: shellDirectory, home: environment["HOME"])
    let executable = resolveExecutable(request.executable, path: environment["PATH"], directory: directory)

    var outputPipe: [Int32] = [0, 0]
    var errorPipe: [Int32] = [0, 0]
    guard pipe(&outputPipe) == 0 else { return .failure("pipe: \(String(cString: strerror(errno)))") }
    guard pipe(&errorPipe) == 0 else {
      close(outputPipe[0])
      close(outputPipe[1])
      return .failure("pipe: \(String(cString: strerror(errno)))")
    }
    for descriptor in outputPipe + errorPipe {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addchdir_np(&actions, directory)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Its own session: no controlling terminal to scribble on, and one group to kill on timeout.
    // Only the three descriptors set up above survive into the child.
    var defaultSignals = sigset_t()
    sigfillset(&defaultSignals)
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let arguments = [request.executable] + request.arguments
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv + envp { free(pointer) }
    }

    var pid: pid_t = 0
    let spawnResult = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
    close(outputPipe[1])
    close(errorPipe[1])
    guard spawnResult == 0 else {
      close(outputPipe[0])
      close(errorPipe[0])
      return .failure("\(request.executable): \(String(cString: strerror(spawnResult)))")
    }

    // The number comes from a completion spec. Unbounded, the arithmetic below overflows.
    let timeout = min(max(request.timeoutMilliseconds ?? defaultTimeoutMilliseconds, 0), maximumTimeoutMilliseconds)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000
    var output: [UInt8] = []
    var errorOutput: [UInt8] = []
    var timedOut = false
    var open: [(descriptor: Int32, isError: Bool)] = [(outputPipe[0], false), (errorPipe[0], true)]
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)

    while !open.isEmpty {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else {
        timedOut = true
        break
      }
      var descriptors = open.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
      let remaining = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
      let ready = poll(&descriptors, nfds_t(descriptors.count), remaining)
      if ready < 0 && errno != EINTR { break }
      if ready <= 0 { continue }

      for (index, descriptor) in descriptors.enumerated().reversed() where descriptor.revents != 0 {
        let count = buffer.withUnsafeMutableBytes { read(descriptor.fd, $0.baseAddress, $0.count) }
        if count > 0 {
          if open[index].isError {
            if errorOutput.count < maxOutputBytes { errorOutput.append(contentsOf: buffer[..<count]) }
          } else {
            if output.count < maxOutputBytes { output.append(contentsOf: buffer[..<count]) }
          }
        } else if count == 0 || errno != EINTR {
          close(descriptor.fd)
          open.remove(at: index)
        }
      }
    }
    for entry in open { close(entry.descriptor) }

    if timedOut {
      kill(-pid, SIGKILL)
      kill(pid, SIGKILL)
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    if timedOut {
      return .failure("\(request.executable) timed out after \(timeout) ms")
    }

    let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return .process(
      ProcessResult(
        stdout: String(decoding: output, as: UTF8.self), stderr: String(decoding: errorOutput, as: UTF8.self),
        exitCode: exitCode))
  }

  /// Lists a directory. Blocks; call from a background thread.
  static func list(_ path: String, shellDirectory: String?, home: String?) -> TerminalReply {
    var resolved = expandTilde(path, home: home)
    if !resolved.hasPrefix("/") {
      resolved = (shellDirectory ?? FileManager.default.currentDirectoryPath) + "/" + resolved
    }
    guard let directory = opendir(resolved) else {
      return .failure("\(path): \(String(cString: strerror(errno)))")
    }
    defer { closedir(directory) }

    var entries: [DirectoryEntry] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }

      var kind = DirectoryEntry.Kind.other
      var isSymlink = false
      switch Int32(entry.pointee.d_type) {
      case DT_DIR: kind = .directory
      case DT_REG: kind = .file
      default:
        // Symbolic links and file systems that do not report a type: ask about the target.
        var info = stat()
        if lstat(resolved + "/" + name, &info) == 0 {
          isSymlink = info.st_mode & S_IFMT == S_IFLNK
        }
        if stat(resolved + "/" + name, &info) == 0 {
          switch info.st_mode & S_IFMT {
          case S_IFDIR: kind = .directory
          case S_IFREG: kind = .file
          default: kind = .other
          }
        }
      }
      entries.append(DirectoryEntry(name: name, kind: kind, isSymlink: isSymlink))
    }
    return .directory(entries)
  }
}
