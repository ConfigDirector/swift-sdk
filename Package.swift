// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-client-sdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "ConfigDirector", targets: ["ConfigDirector"]),
    ],
    targets: [
        .target(
            name: "ConfigDirector",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ConfigDirectorTests",
            dependencies: ["ConfigDirector"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
