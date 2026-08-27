// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Playground",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PlaygroundKit", targets: ["PlaygroundKit"]),
        .executable(name: "playground", targets: ["Playground"]),
    ],
    dependencies: [
        // The published package, so this app builds from a bare checkout with
        // no native-sdk beside it and no xcframework to build first.
        //
        // To try a local SDK change against it:
        //   swift package edit colyseus-swift --path ../../../../native-sdk/platforms/swift
        //   swift package unedit colyseus-swift
        .package(url: "https://github.com/colyseus/colyseus-swift", from: "0.18.1"),
    ],
    targets: [
        // The simulation, the schemas and the labs, with no rendering in them:
        // what lets the acceptance tests drive the real labs headlessly.
        .target(
            name: "PlaygroundKit",
            dependencies: [.product(name: "Colyseus", package: "colyseus-swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Playground",
            dependencies: ["PlaygroundKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PlaygroundKitTests",
            dependencies: ["PlaygroundKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
