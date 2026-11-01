// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RallyCut",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [
        .library(name: "MatchCore", targets: ["MatchCore"]),
    ],
    targets: [
        .target(name: "MatchCore", path: "Sources/MatchCore"),
        .testTarget(name: "MatchCoreTests", dependencies: ["MatchCore"], path: "Tests/MatchCoreTests"),
    ]
)
