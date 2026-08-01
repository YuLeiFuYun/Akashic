// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AkashicNegativeConsumer",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AkashicNegativeConsumer",
            dependencies: [
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "AkashicDisk", package: "Akashic"),
            ]
        )
    ]
)
