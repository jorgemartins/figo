import Foundation

/// Measures how fast shell output moves through the wrapper's processing, so regressions in the
/// hot path show up as a number. Run with `figoterm --benchmark <file of terminal output>`.
public enum Benchmark {
  public static func run(path: String) {
    guard let data = FileManager.default.contents(atPath: path) else {
      print("cannot read \(path)")
      return
    }
    let megabytes = Double(data.count) / 1_000_000

    func measure(_ label: String, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
      let start = DispatchTime.now().uptimeNanoseconds
      data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        var offset = 0
        while offset < bytes.count {
          let end = min(offset + 64 * 1024, bytes.count)
          body(UnsafeBufferPointer(rebasing: bytes[offset..<end]))
          offset = end
        }
      }
      let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
      print(String(format: "%-28@ %7.1f MB/s", label as NSString, megabytes / seconds))
    }

    var filter = OutputFilter()
    var output: [UInt8] = []
    measure("output filter") { chunk in
      output.removeAll(keepingCapacity: true)
      filter.filter(chunk, into: &output)
    }

    struct Discard: VTHandler {
      var count = 0
      mutating func print(_ scalar: Unicode.Scalar) { count &+= 1 }
      mutating func execute(_ byte: UInt8) { count &+= 1 }
      mutating func csiDispatch(params: VTParams, prefix: UInt8, intermediates: [UInt8], final: UInt8) { count &+= 1 }
      mutating func escDispatch(intermediates: [UInt8], final: UInt8) { count &+= 1 }
      mutating func oscDispatch(_ payload: [UInt8]) { count &+= 1 }
    }
    var parser = VTParser()
    var discard = Discard()
    measure("escape sequence parser") { chunk in
      parser.feed(chunk, handler: &discard)
    }

    let session = ShellSession(sessionId: "benchmark", columns: 120, rows: 40)
    measure("parser + screen model") { chunk in
      _ = session.feed(chunk)
    }
  }
}
