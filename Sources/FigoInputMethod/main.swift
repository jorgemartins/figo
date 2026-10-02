import AppKit
import FigoCore
import InputMethodKit

// Figo's input method helper: a palette input method, invisible in the system UI, whose only
// job is to tell the app where the focused text field's caret is. macOS starts it once the input
// source is selected; it then lives for the whole login session.

IMLog.configure()
IMLog.info("starting \(Bundle.main.bundleIdentifier ?? "unbundled") \(Figo.version)")

// The server attaches to the application's run loop, so the application comes first.
let app = NSApplication.shared

// Make sure the controller class is registered before the server looks it up by name.
_ = FigoInputController.self

let connectionName =
  Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
  ?? "dev.figo.inputmethod.Figo_Connection"
guard let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier) else {
  IMLog.info("could not create the input method server \(connectionName)")
  exit(1)
}

MainActor.assumeIsolated { InputMethodService.shared.start() }
withExtendedLifetime(server) { app.run() }
