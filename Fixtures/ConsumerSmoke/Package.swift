// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AkashicConsumerSmoke",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AkashicConsumerSmoke",
            dependencies: [
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "AkashicMemory", package: "Akashic"),
                .product(name: "AkashicDisk", package: "Akashic"),
            ]
        )
    ]
)
