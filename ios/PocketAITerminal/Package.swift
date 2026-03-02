// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PocketAITerminal",
    platforms: [
        .iOS(.v17)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "PocketAITerminal",
            dependencies: ["SwiftTerm"],
            path: "."
        )
    ]
)
