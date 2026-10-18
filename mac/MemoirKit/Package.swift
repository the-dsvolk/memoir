// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoirKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MemoirKit", targets: ["MemoirKit"]),
        .executable(name: "memoir", targets: ["memoir"]),
    ],
    targets: [
        // Capture, conversion, wire protocol and transcript model — shared by the CLI and the app (M3).
        .target(name: "MemoirKit"),
        .executableTarget(name: "memoir", dependencies: ["MemoirKit"]),
        .testTarget(name: "MemoirKitTests", dependencies: ["MemoirKit"]),
    ]
)
