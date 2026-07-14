// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContainerDashboard",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 4.100+ resolves to the newest 4.x; recent enough for the Phase 8 SSE
        // disconnect contract (NIO channel-inactive propagates to StreamWriter).
        .package(url: "https://github.com/vapor/vapor.git", from: "4.100.0"),
        // Native macOS terminal emulator for the container exec pane.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ContainerDashboard",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/ContainerDashboard"
        ),
        // The native SwiftUI shell. Does NOT depend on the server target - it
        // spawns the server binary out-of-process. build-app.sh compiles both.
        // `exclude: ["Core"]` keeps the app target from also compiling the
        // library below (both live under App/); the app imports it instead.
        .executableTarget(
            name: "ContainerDashboardApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .target(name: "ContainerMonitorCore"),
            ],
            path: "App",
            exclude: ["Info.plist", "Core"]
        ),
        // Foundation-only models + format helpers, split out so they are
        // unit-testable (an executable target can't be imported by a test
        // target). No AppKit/SwiftUI here.
        .target(
            name: "ContainerMonitorCore",
            path: "App/Core"
        ),
        .testTarget(
            name: "ContainerDashboardTests",
            dependencies: [
                .target(name: "ContainerDashboard"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "XCTVapor", package: "vapor"),
            ],
            path: "Tests/ContainerDashboardTests",
            resources: [.copy("Fixtures")]
        ),
        // Tests for the app's pure logic: wire-shape encoding (a regression here
        // makes every container create 400) and the containers/stats join.
        .testTarget(
            name: "ContainerMonitorCoreTests",
            dependencies: [.target(name: "ContainerMonitorCore")],
            path: "Tests/ContainerMonitorCoreTests"
        ),
    ]
)
