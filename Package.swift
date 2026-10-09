// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RallyCut",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [
        .library(name: "MatchCore", targets: ["MatchCore"]),
        .executable(name: "match-benchmark", targets: ["BenchmarkRunner"]),
    ],
    targets: [
        .target(name: "MatchCore", path: "Sources/MatchCore"),
        .executableTarget(
            name: "BenchmarkRunner", dependencies: ["MatchCore"], path: "Tools/BenchmarkRunner"),
        .testTarget(name: "MatchCoreTests", dependencies: ["MatchCore"], path: "Tests/MatchCoreTests"),
    ]
)
