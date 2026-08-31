// swift-tools-version: 6.4
import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Akashic",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "AkashicCore", targets: ["AkashicCore"]),
        .library(name: "AkashicMemory", targets: ["AkashicMemory"]),
        .library(name: "AkashicDisk", targets: ["AkashicDisk"]),
        .executable(name: "AkashicCrashProbe", targets: ["AkashicCrashProbe"]),
        .executable(name: "AkashicResourceProbe", targets: ["AkashicResourceProbe"]),
    ],
    targets: [
        .target(
            name: "AkashicCore",
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "CAkashicAtomics",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AkashicMemory",
            dependencies: ["CAkashicAtomics"],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "AkashicDisk",
            dependencies: ["AkashicCore"],
            resources: [.process("PrivacyInfo.xcprivacy")],
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "AkashicCrashProbe",
            dependencies: ["AkashicCore", "AkashicDisk"],
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "AkashicResourceProbe",
            dependencies: ["AkashicCore", "AkashicDisk", "AkashicMemory"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "AkashicCoreTests",
            dependencies: ["AkashicCore"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "AkashicDiskTests",
            dependencies: ["AkashicCore", "AkashicDisk"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "AkashicMemoryTests",
            dependencies: ["AkashicMemory"],
            swiftSettings: concurrencySettings
        ),
    ]
)
