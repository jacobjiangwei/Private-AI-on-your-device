// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LLMCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LLMCore", targets: ["LLMCore"])
    ],
    targets: [
        .target(name: "LLMCore"),
        .testTarget(name: "LLMCoreTests", dependencies: ["LLMCore"])
    ]
)