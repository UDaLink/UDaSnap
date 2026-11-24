// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UDaSnap",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "UDaSnap", targets: ["UDaSnap"])
    ],
    targets: [
        .target(
            name: "UDaSnapCore",
            path: "Sources/UDaSnapCore"
        ),
        .executableTarget(
            name: "UDaSnap",
            dependencies: ["UDaSnapCore"],
            path: "Sources/UDaSnap"
        ),
        .testTarget(
            name: "UDaSnapCoreTests",
            dependencies: ["UDaSnapCore"],
            path: "Tests/UDaSnapCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
