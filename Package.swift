// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "supervox",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SupervoxCore", targets: ["SupervoxCore"]),
        .library(name: "SupervoxEngines", targets: ["SupervoxEngines"]),
        .executable(name: "supervox-bench", targets: ["SupervoxBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.3"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "SupervoxCore"),
        .target(
            name: "SupervoxEngines",
            dependencies: [
                "SupervoxCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "SupervoxBench",
            dependencies: [
                "SupervoxCore",
                "SupervoxEngines",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "SupervoxCoreTests", dependencies: ["SupervoxCore"]),
        .testTarget(name: "SupervoxBenchTests", dependencies: ["SupervoxBench", "SupervoxEngines"]),
    ]
)
