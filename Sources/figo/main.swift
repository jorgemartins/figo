import Darwin

do {
  try Commands.run(Array(CommandLine.arguments.dropFirst()))
} catch let failure as CommandFailure {
  if !failure.message.isEmpty { Output.error(failure.message) }
  exit(1)
} catch {
  Output.error(String(describing: error))
  exit(1)
}
