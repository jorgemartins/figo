import FigoCore
import Foundation
import Testing

@testable import FigoAppKit

/// Messages as the page builds them (`web/src/bridge/native.ts`), turned into the Foundation
/// objects WebKit hands to the message handler.
@Suite struct BridgeTests {
  private func request(_ json: String) throws -> BridgeRequest {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let message = try #require(JSONValue(foundation: object))
    return try BridgeRequest(message: message)
  }

  @Test func decodesEveryContractMethod() throws {
    #expect(try request(#"{"method":"app.ready","params":{}}"#) == .ready)
    #expect(
      try request(#"{"method":"app.log","params":{"level":"warn","message":"slow spec"}}"#)
        == .log(level: .warn, message: "slow spec"))
    #expect(
      try request(#"{"method":"app.reportState","params":{"state":{"visible":true,"rows":3}}}"#)
        == .reportState(.object(["visible": .bool(true), "rows": .number(3)])))
    #expect(
      try request(
        #"{"method":"window.position","params":{"width":320,"height":140.5,"anchorX":-200,"offsetFromBaseline":-3}}"#)
        == .position(PositionRequest(width: 320, height: 140.5, anchorX: -200, offsetFromBaseline: -3)))
    #expect(
      try request(
        #"{"method":"window.position","params":{"width":520,"height":140,"anchorX":0,"offsetFromBaseline":-3,"dryRun":true}}"#
      ) == .position(PositionRequest(width: 520, height: 140, anchorX: 0, offsetFromBaseline: -3, dryRun: true)))
    #expect(
      try request(#"{"method":"shell.insert","params":{"sessionId":"s1","text":"\bcheckout ","insertionBuffer":"git ch"}}"#)
        == .insert(sessionId: "s1", text: "\u{8}checkout ", insertionBuffer: "git ch"))
    #expect(
      try request(#"{"method":"shell.insert","params":{"sessionId":"s1","text":"\n"}}"#)
        == .insert(sessionId: "s1", text: "\n", insertionBuffer: nil))
    #expect(
      try request(
        #"{"method":"shell.setIntercept","params":{"sessionId":"s1","interceptBound":true,"interceptGlobal":false,"bindings":{"enter":"insertSelected","control+k":"ignore"}}}"#
      )
        == .setIntercept(
          sessionId: "s1",
          InterceptConfiguration(
            interceptBound: true, interceptGlobal: false,
            bindings: ["enter": "insertSelected", "control+k": "ignore"])))
    #expect(
      try request(
        #"{"method":"process.run","params":{"sessionId":"s1","executable":"git","args":["branch","--list"],"cwd":"/repo","env":{"GIT_PAGER":"cat","LESS":null},"timeoutMs":5000}}"#
      )
        == .runProcess(
          sessionId: "s1",
          ProcessRequest(
            executable: "git", arguments: ["branch", "--list"], workingDirectory: "/repo",
            environment: ["GIT_PAGER": "cat", "LESS": nil], timeoutMilliseconds: 5000)))
    #expect(
      try request(#"{"method":"process.run","params":{"sessionId":"s1","executable":"ls","args":[]}}"#)
        == .runProcess(sessionId: "s1", ProcessRequest(executable: "ls")))
    #expect(
      try request(#"{"method":"fs.list","params":{"sessionId":"s1","path":"~/Sites"}}"#)
        == .listDirectory(sessionId: "s1", path: "~/Sites"))
    #expect(
      try request(#"{"method":"settings.set","params":{"key":"autocomplete.theme","value":"dusk"}}"#)
        == .setSetting(key: "autocomplete.theme", value: .string("dusk")))
    #expect(
      try request(#"{"method":"settings.set","params":{"key":"autocomplete.theme"}}"#)
        == .setSetting(key: "autocomplete.theme", value: nil))
  }

  @Test func keepsBooleansApartFromNumbers() throws {
    let object = try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":0,"d":false,"e":1.5}"#.utf8))
    #expect(
      JSONValue(foundation: object)
        == .object(["a": .bool(true), "b": .number(1), "c": .number(0), "d": .bool(false), "e": .number(1.5)]))
    let back = JSONValue.object(["flag": .bool(true), "n": .number(1)]).foundationObject as? [String: Any]
    let flag = try #require(back?["flag"] as? NSNumber)
    #expect(CFGetTypeID(flag) == CFBooleanGetTypeID())
    #expect((back?["n"] as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true)
  }

  @Test func rejectsBadMessages() throws {
    #expect(throws: BridgeError("Unknown method app.explode")) { try request(#"{"method":"app.explode","params":{}}"#) }
    #expect(throws: BridgeError("Message has no method")) { try request(#"{"params":{}}"#) }
    #expect(throws: BridgeError("Invalid params for shell.insert: missing text")) {
      try request(#"{"method":"shell.insert","params":{"sessionId":"s1"}}"#)
    }
    #expect(throws: BridgeError.self) {
      try request(#"{"method":"window.position","params":{"width":"wide","height":1,"anchorX":0,"offsetFromBaseline":0}}"#)
    }
  }

  @Test func encodesRepliesInContractShapes() throws {
    #expect(
      BridgeReply.process(ProcessResult(stdout: "a", stderr: "b", exitCode: 3))
        == .object(["stdout": .string("a"), "stderr": .string("b"), "exitCode": .number(3)]))
    #expect(
      BridgeReply.directory([DirectoryEntry(name: "link", kind: .other, isSymlink: true)])
        == .object([
          "entries": .array([.object(["name": .string("link"), "kind": .string("other"), "isSymlink": .bool(true)])])
        ]))
    #expect(
      BridgeReply.position(PositionResult(isAbove: true, isClipped: false))
        == .object(["isAbove": .bool(true), "isClipped": .bool(false)]))
    let info = BridgeReply.appInfo(
      AppInfo(
        version: "0.1.0", home: "/Users/a", user: "a", macosVersion: "26.7.0", settings: ["x": .number(1)],
        themes: ["dusk"]))
    #expect(info["version"] == .string("0.1.0"))
    #expect(info["settings"] == .object(["x": .number(1)]))
    #expect(info["themes"] == .array([.string("dusk")]))
    #expect(info["macosVersion"] == .string("26.7.0"))
  }

  @Test func encodesEventsInContractShapes() throws {
    let context = ShellContext(
      sessionId: "s1", shell: "zsh", cwd: "/tmp", home: "/Users/a", env: ["A": "1"], aliases: "", terminal: nil)
    let session = PageEvent.session(context).payload
    #expect(session["sessionId"] == .string("s1"))
    #expect(session["env"] == .object(["A": .string("1")]))
    #expect(session["terminal"] == nil, "absent optional fields are omitted")

    #expect(
      PageEvent.editBuffer(sessionId: "s1", buffer: nil, cursor: 0).payload
        == .object(["sessionId": .string("s1"), "buffer": .null, "cursor": .number(0)]))
    #expect(PageEvent.windowHidden.payload == .object([:]))
    #expect(PageEvent.settings(["a": .bool(true)]).payload == .object(["settings": .object(["a": .bool(true)])]))
    #expect(
      PageEvent.postExec(sessionId: "s1", command: "ls", exitCode: 1).payload
        == .object(["sessionId": .string("s1"), "command": .string("ls"), "exitCode": .number(1)]))
  }

  @Test func scriptsCallTheReceiverWithValidJSON() throws {
    let script = PageEvent.editBuffer(sessionId: "s\"1", buffer: "echo \"</script>\" \u{2028}", cursor: 4).script
    #expect(script.hasPrefix(#"window.__figoReceive && window.__figoReceive("editBuffer", "#))
    #expect(script.hasSuffix(");"))
    let argument = script.dropFirst(#"window.__figoReceive && window.__figoReceive("editBuffer", "#.count).dropLast(2)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(argument.utf8))
    #expect(decoded["buffer"] == .string("echo \"</script>\" \u{2028}"))
    #expect(decoded["sessionId"] == .string("s\"1"))
  }
}
