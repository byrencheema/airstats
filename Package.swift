// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AirStats",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AirStats", targets: ["AirStats"]),
        .library(name: "AirStatKit", targets: ["AirStatKit"]),
        .library(name: "AirStatUI", targets: ["AirStatUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Metric collection. Deliberately Swift 5 language mode: the collectors are
        // queue-confined by construction (see SamplingCore) rather than by the type
        // system, and the low-level Mach/IOKit code they wrap is not Sendable-clean.
        .target(
            name: "AirStatKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Metal"),
            ]
        ),
        .target(
            name: "AirStatUI",
            dependencies: ["AirStatKit", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AirStats",
            dependencies: ["AirStatKit", "AirStatUI", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle ships as a framework, and Scripts/build.sh puts it in
            // Contents/Frameworks. Without this the binary looks only where SwiftPM
            // linked it from and the assembled .app dies at launch with a dyld error.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Named for AirStatKit because that is where almost everything under test
        // lives, but it also links AirStatUI: the pieces of UI logic worth testing
        // are the pure ones (threshold evaluation, render models), and giving them a
        // second test target would split the suite for no gain.
        .testTarget(
            name: "AirStatKitTests",
            dependencies: ["AirStatKit", "AirStatUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
