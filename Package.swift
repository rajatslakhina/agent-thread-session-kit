// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ThreadSessionKit",
    // Only the platforms CI actually builds: Linux (core module), macOS and the iOS Simulator.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ThreadSession", targets: ["ThreadSession"]),
        .library(name: "ThreadSessionUI", targets: ["ThreadSessionUI"]),
    ],
    targets: [
        .target(name: "ThreadSession"),
        // SwiftUI console. Compiles to an empty module where SwiftUI is unavailable (Linux).
        .target(name: "ThreadSessionUI", dependencies: ["ThreadSession"]),
        .testTarget(name: "ThreadSessionTests", dependencies: ["ThreadSession"]),
        // Runs the demo's scenario scripts through the console model (Apple platforms; empty on Linux).
        .testTarget(name: "ThreadSessionUITests", dependencies: ["ThreadSessionUI", "ThreadSession"]),
    ]
)
