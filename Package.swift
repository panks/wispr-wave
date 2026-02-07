// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSpeechToText",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacSpeechToText", targets: ["MacSpeechToText"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.2.0"),
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MacSpeechToText",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "HotKey"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
