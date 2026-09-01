// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PrivateAITools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PrivateAITools", targets: ["PrivateAITools"])
    ],
    dependencies: [
        .package(path: "../LLMCore"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")
    ],
    targets: [
        .target(
            name: "PrivateAITools",
            dependencies: ["LLMCore", "SwiftSoup"]
        ),
        .testTarget(
            name: "PrivateAIToolsTests",
            dependencies: ["PrivateAITools", "LLMCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)