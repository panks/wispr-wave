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
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.0"),
        // Parakeet speech recognition. Pinned exactly because FluidAudio's API moves fast
        // between releases (and its README lags the source); upgrade deliberately after
        // re-checking the AsrManager / AsrModels calls ParakeetEngine relies on.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.4")
    ],
    targets: [
        .executableTarget(
            name: "WisprWave",
            dependencies: [
                // The fork's Package.swift declares `name: "argmax-oss-swift"`, but the
                // library product is still named "WhisperKit" — so our import sites are
                // unchanged; only the `package:` parameter here moves.
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "HotKey",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
