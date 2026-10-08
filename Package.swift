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
        // Pinned to the upstream v1.0.0 tag, anchored on our own fork so the build keeps
        // working even if upstream argmaxinc/argmax-oss-swift is renamed or deleted. The
        // tag is a first-class ref on the fork (not just an unreachable shared object),
        // which makes resolution independent of GitHub's cross-fork object policy.
        .package(
            url: "https://github.com/panks/argmax-oss-swift",
            exact: "1.0.0"
        ),
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "WisprWave",
            dependencies: [
                // The fork's Package.swift declares `name: "argmax-oss-swift"`, but the
                // library product is still named "WhisperKit" — so our import sites are
                // unchanged; only the `package:` parameter here moves.
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
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
