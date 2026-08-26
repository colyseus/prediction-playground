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
        // The SDK lives in the sibling native-sdk checkout. Build its
        // xcframework first: cd native-sdk/platforms/swift && ./build.sh
        //
        // This directory is `swift-app`, not `swift`, because SwiftPM takes a
        // local package's identity from its directory name — and a package in
        // a folder called `swift` cannot depend on one in `platforms/swift`.
        .package(path: "../../../../native-sdk/platforms/swift"),
    ],
    targets: [
        // The simulation, the schemas and the labs, with no rendering in them:
        // what lets the acceptance tests drive the real labs headlessly.
        .target(
            name: "PlaygroundKit",
            dependencies: [.product(name: "Colyseus", package: "swift")],
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
