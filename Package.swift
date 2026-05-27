// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WisprWave",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WisprWave", targets: ["WisprWave"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.2.0"),
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "WisprWave",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "HotKey"
            ],
            resources: [
                .process("Resources")
            ],
            // The app's concurrency was written against Swift 5 semantics. Newer Swift
            // compilers (6.2+) tighten region-based isolation ("sending") checks and turn
            // previously-accepted patterns into hard errors. Pin the language mode so the
            // app builds consistently across toolchains.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
