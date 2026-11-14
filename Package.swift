// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "supervox",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SupervoxCore", targets: ["SupervoxCore"]),
        .library(name: "SupervoxEngines", targets: ["SupervoxEngines"]),
        .library(name: "SupervoxApp", targets: ["SupervoxApp"]),
        .executable(name: "Supervox", targets: ["Supervox"]),
        .executable(name: "supervox-bench", targets: ["SupervoxBench"]),
        .executable(name: "supervox-snapshots", targets: ["SupervoxSnapshots"]),
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
        .target(
            name: "SupervoxApp",
            dependencies: ["SupervoxCore"]
        ),
        .executableTarget(name: "Supervox", dependencies: ["SupervoxApp"]),
        .executableTarget(name: "SupervoxSnapshots", dependencies: ["SupervoxApp"]),
        .executableTarget(
            name: "SupervoxBench",
            dependencies: [
                "SupervoxCore",
                "SupervoxEngines",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SupervoxCoreTests",
            dependencies: ["SupervoxCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SupervoxAppTests", dependencies: ["SupervoxApp"]),
        .testTarget(name: "SupervoxBenchTests", dependencies: ["SupervoxBench", "SupervoxEngines"]),
    ]
)
