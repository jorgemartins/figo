import Foundation
import Testing

@testable import FigoCore

@Suite struct FrameTests {
  @Test func roundTripsAcrossArbitrarySplits() throws {
    let first = Data(#"{"a":1}"#.utf8)
    let second = Data(repeating: 0x78, count: 70_000)
    let stream = Frame.encode(first) + Frame.encode(second) + Frame.encode(Data())

    for chunkSize in [1, 3, 4, 5, 4096, stream.count] {
      var decoder = FrameDecoder()
      var received: [Data] = []
      var offset = 0
      while offset < stream.count {
        let end = min(offset + chunkSize, stream.count)
        decoder.append(stream.subdata(in: offset..<end))
        while let payload = try decoder.next() { received.append(payload) }
        offset = end
      }
      #expect(received == [first, second, Data()], "chunk size \(chunkSize)")
    }
  }

  @Test func rejectsOversizedFrames() {
    var decoder = FrameDecoder()
    decoder.append(Data([0x7f, 0xff, 0xff, 0xff]))
    #expect(throws: FrameDecoder.Failure.payloadTooLarge(0x7fff_ffff)) { try decoder.next() }
  }

  @Test func runtimeDirectoryIgnoresTMPDIR() {
    #expect(FigoPaths.runtime.lastPathComponent == "figo")
    #expect(FigoPaths.appSocket.path.utf8.count < 104, "must fit in sockaddr_un.sun_path")
  }
}

@Suite struct ProtocolTests {
  private func roundTrip<Message: Codable & Equatable>(_ message: Message) throws -> Message {
    var decoder = FrameDecoder()
    decoder.append(try Frame.encode(message))
    let payload = try #require(try decoder.next())
    return try JSONDecoder().decode(Message.self, from: payload)
  }

  @Test func terminalMessagesRoundTrip() throws {
    let buffer = EditBuffer(
      text: "git ch", cursor: 6, cursorCell: GridPosition(row: 3, column: 9), grid: GridSize(rows: 24, columns: 80))
    let messages: [TerminalMessage] = [
      .shell(ShellInfo(shell: "zsh", pid: 42, cwd: "/tmp")),
      .environment(variables: ["PATH": "/bin"], aliases: "ll='ls -l'"),
      .prompt, .preExec, .postExec(command: "ls", exitCode: 1),
      .editBuffer(buffer), .editBuffer(nil), .key(action: "insertSelected"),
      .reply(id: 7, result: .process(ProcessResult(stdout: "a", stderr: "", exitCode: 0))),
      .reply(id: 8, result: .directory([DirectoryEntry(name: "src", kind: .directory, isSymlink: false)])),
      .reply(id: 9, result: .failure("nope")),
    ]
    for message in messages {
      #expect(try roundTrip(message) == message)
    }
  }

  @Test func commandsRoundTripIncludingRemovedVariables() throws {
    let request = ProcessRequest(executable: "git", arguments: ["status"], environment: ["A": "1", "B": nil])
    let commands: [TerminalCommand] = [
      .intercept(InterceptConfiguration(interceptBound: true, bindings: ["enter": "insertSelected"])),
      .insert(text: "\u{08}\u{08}Sites/", insertionBuffer: "cd si"),
      .runProcess(id: 1, request: request), .listDirectory(id: 2, path: "~/"), .simulateInput(text: "cd "),
    ]
    for command in commands {
      #expect(try roundTrip(command) == command)
    }
    let decoded = try roundTrip(TerminalCommand.runProcess(id: 1, request: request))
    guard case .runProcess(_, let back) = decoded else { Issue.record("wrong case"); return }
    #expect(back.environment.keys.sorted() == ["A", "B"])
    #expect(back.environment["B"] == .some(nil))
  }

  @Test func helloRoundTrips() throws {
    let hello = ClientHello(
      role: .terminal, terminal: TerminalHello(sessionId: "abc", pid: 1, tty: "/dev/ttys001", insideTmux: true))
    #expect(try roundTrip(hello) == hello)
  }
}
