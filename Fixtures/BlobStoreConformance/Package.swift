// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AkashicBlobStoreConformanceFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "AkashicBlobStoreConformanceFixture",
            targets: ["AkashicBlobStoreConformanceFixture"]
        )
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "AkashicBlobStoreConformanceFixture",
            dependencies: [
                .product(name: "AkashicCore", package: "Akashic"),
                .product(name: "AkashicDisk", package: "Akashic"),
            ]
        )
    ]
)
