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
        .executableTarget(
            name: "ContainerDashboardApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "App",
            exclude: ["Info.plist"]
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
    ]
)
