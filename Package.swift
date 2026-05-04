// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Bucket",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Bucket",
            targets: ["Bucket"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Bucket"
        ),
        .testTarget(
            name: "BucketTests",
            dependencies: ["Bucket"]
        ),
        // Integration tests against a local MinIO running on
        // http://localhost:9000 (see scripts/minio-up.sh). Each test
        // skips with a `[skip]` log line when MinIO is unreachable, so
        // this target is safe to include in the default `swift test`
        // run. Filter with `swift test --filter BucketIntegrationTests`
        // to run only this target.
        .testTarget(
            name: "BucketIntegrationTests",
            dependencies: ["Bucket"],
            path: "Tests/BucketIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
