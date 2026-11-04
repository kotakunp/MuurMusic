// swift-tools-version:5.10
// The package intentionally uses the Swift 5 language mode (tools version 5.10) so that
// strict Swift 6 concurrency diagnostics stay warnings while dependencies migrate.

import PackageDescription

let package = Package(
    name: "MuurKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MuurCore", targets: ["MuurCore"]),
        .library(name: "MuurAudio", targets: ["MuurAudio"]),
        .library(name: "MuurWidgetKitSupport", targets: ["MuurWidgetKitSupport"]),
    ],
    dependencies: [
        // 0.x packages are pinned to the next minor release because minor bumps may break API.
        .package(url: "https://github.com/sbooth/SFBAudioEngine.git", .upToNextMinor(from: "0.14.0")),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/amosavian/AMSMB2.git", from: "4.0.3"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.20")),
        // Citadel already depends on these; they are listed so MuurCore can import NIOCore/Crypto directly.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "MuurWidgetKitSupport",
            path: "Sources/MuurWidgetKitSupport"
        ),
        .target(
            name: "MuurCore",
            dependencies: [
                "MuurWidgetKitSupport",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AMSMB2", package: "AMSMB2"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/MuurCore",
            resources: [
                .copy("Resources/eq-presets.json"),
            ]
        ),
        .target(
            name: "MuurAudio",
            dependencies: [
                "MuurCore",
                "MuurWidgetKitSupport",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            path: "Sources/MuurAudio"
        ),
        .testTarget(
            name: "MuurCoreTests",
            dependencies: ["MuurCore"],
            path: "Tests/MuurCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
