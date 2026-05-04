// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "BucketMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BucketMac", targets: ["BucketMac"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "BucketMac",
            dependencies: [
                .product(name: "Bucket", package: "BucketKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
