// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Figo",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "figo", targets: ["figo"]),
    .executable(name: "figoterm", targets: ["figoterm"]),
    .executable(name: "FigoApp", targets: ["FigoApp"]),
    .executable(name: "FigoInputMethod", targets: ["FigoInputMethod"]),
  ],
  targets: [
    // Shared between every native component: IPC protocol, paths, settings.
    .target(name: "FigoCore"),

    // fork/exec on a pty must happen in C: Swift cannot safely run code between fork and exec.
    .target(name: "CFigoPTY"),

    // The pty wrapper's logic, kept in a library so it can be tested without a terminal.
    .target(name: "FigoTermKit", dependencies: ["FigoCore", "CFigoPTY"]),
    .executableTarget(name: "figoterm", dependencies: ["FigoTermKit"]),

    // Installing and checking the pieces that live outside the app bundle: shell integration,
    // the input method registration, launch at login.
    .target(name: "FigoInstallKit", dependencies: ["FigoCore"]),

    // The menu-bar app that owns the popup window. Logic lives in the library so it can be tested.
    .target(name: "FigoAppKit", dependencies: ["FigoCore", "FigoInstallKit"]),
    .executableTarget(name: "FigoApp", dependencies: ["FigoAppKit"]),

    // The invisible input method that reports where the focused terminal's text cursor is.
    .executableTarget(name: "FigoInputMethod", dependencies: ["FigoCore"]),

    // The `figo` command line tool.
    .executableTarget(name: "figo", dependencies: ["FigoCore", "FigoInstallKit"]),

    .testTarget(name: "FigoCoreTests", dependencies: ["FigoCore"]),
    .testTarget(name: "FigoTermKitTests", dependencies: ["FigoTermKit"]),
    .testTarget(name: "FigoInstallKitTests", dependencies: ["FigoInstallKit"]),
    .testTarget(name: "FigoAppKitTests", dependencies: ["FigoAppKit"]),
  ],
  swiftLanguageModes: [.v5]
)
