import Darwin
import FigoCore
import FigoTermKit

if CommandLine.arguments.dropFirst().first == "--version" {
  print("figoterm \(Figo.version)")
  exit(0)
}

// Hidden diagnostic: how fast shell output is processed, without a terminal in the way.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--benchmark" {
  Benchmark.run(path: CommandLine.arguments[2])
  exit(0)
}

do {
  let wrapper = try Wrapper(configuration: Launch.configuration())
  wrapper.run()
} catch {
  Launch.execShell()
}
