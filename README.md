# BucketKit — A Swift package for S3-compatible object storage.

A single, modern Swift API for AWS S3, Cloudflare R2, DigitalOcean Spaces, and
MinIO. Drop in for any of them — only the configuration changes. Apple platforms
only; Foundation + CryptoKit + OSLog with zero third-party dependencies. The
public surface is shaped after AWS Amplify's `StorageCategoryBehavior` so
Amplify users have a near-zero learning curve, but BucketKit is a
single-purpose S3 library — no Amplify category system, no plugins, no Cognito
coupling.

> **Status — pre-1.0.** Public surface is being stabilised toward a v1.0 tag.
> Symbol-by-symbol stability tiers (frozen, additive, evolving) are tracked in
> [STABILITY.md](STABILITY.md). Expect minor breaking changes on `0.x` until
> v1.0 lands.

## Supported platforms

- macOS 15+
- iOS 18+
- iPadOS 18+
- tvOS 18+
- watchOS 11+
- visionOS 2+

Toolchain: `swift-tools-version: 6.3`, language mode `.v6`, complete strict
concurrency. All public types are `Sendable`.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/brennanMKE/BucketKit.git", from: "0.1.0"),
]
```

And the `Bucket` library to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "Bucket", package: "BucketKit"),
    ]
)
```

## Quick start

```swift
import Foundation
import Bucket

let env = ProcessInfo.processInfo.environment
let client = BucketClient(
    configuration: .aws(
        region: env["AWS_REGION"] ?? "us-east-1",
        accessKeyID: env["AWS_ACCESS_KEY_ID"] ?? "",
        secretAccessKey: env["AWS_SECRET_ACCESS_KEY"] ?? ""
    )
)

let bucket = "my-bucket"

// Upload a small Data payload.
let upload = await client.uploadData(
    bucket: bucket,
    path: .fromString("hello.txt"),
    data: Data("hello, bucket".utf8),
    options: UploadDataOptions(contentType: "text/plain")
)
let result = try await upload.value
print("uploaded eTag=\(result.eTag)")

// Download it back.
let download = await client.downloadData(
    bucket: bucket,
    path: .fromString("hello.txt")
)
let bytes = try await download.value

// List objects under a prefix.
let page = try await client.list(
    bucket: bucket,
    options: ListOptions(prefix: "")
)
for object in page.items {
    print("\(object.key)\t\(object.size) bytes")
}

// Mint a presigned GET URL valid for one hour.
let url = try await client.getURL(
    bucket: bucket,
    path: .fromString("hello.txt"),
    options: GetURLOptions(method: .get, expiresIn: .seconds(3600))
)
```

## Provider configuration

`BucketConfiguration` is a `Sendable` struct with one factory per first-class
provider. The same `BucketClient` and call sites work across providers — only
the configuration changes.

| Provider | Factory | Endpoint | SigV4 region | URL style |
|---|---|---|---|---|
| AWS S3 | `BucketConfiguration.aws` | `https://s3.{region}.amazonaws.com` | real region | virtual-hosted |
| Cloudflare R2 | `BucketConfiguration.r2` | `https://{accountID}.r2.cloudflarestorage.com` | literal `auto` | virtual-hosted |
| Cloudflare R2 (jurisdiction) | `BucketConfiguration.r2(jurisdiction:)` | `…{accountID}.eu.r2.cloudflarestorage.com`, `…fedramp…` | literal `auto` | virtual-hosted |
| DigitalOcean Spaces | `BucketConfiguration.digitalOceanSpaces` | `https://{region}.digitaloceanspaces.com` | literal `us-east-1` | virtual-hosted |
| MinIO / custom | `BucketConfiguration.custom` | user-supplied | user-supplied | path-style by default |

`bucket:` is a per-call argument, not a configuration field — one client serves
many buckets. Worked examples for every provider are in
[Examples/Configuration.swift](Examples/Configuration.swift).

## Concurrency model

`BucketClient` is an `actor`; one instance per app is fine. Uploads and
downloads return `Sendable` task value types — `BucketUploadDataTask`,
`BucketUploadFileTask`, `BucketDownloadDataTask`, `BucketDownloadFileTask` —
that conform to `BucketTransferTask`. Each vends an
`AsyncStream<TransferProgress>` for byte-count snapshots and a `value` for the
final result. Simple cases just `await task.value`. Cancellation is
honoured through structured task cancellation and a `cancel()` method on the
task itself. No Combine, no DispatchQueue, no completion handlers anywhere in
the public API.

## Multipart uploads

`uploadFile` automatically switches to S3 multipart with parallel parts above a
configurable threshold (default 100 MiB, hard floor 5 MiB per non-final part,
maximum 10,000 parts). Cancellation triggers a best-effort
`AbortMultipartUpload`. For fine-grained control — streaming from a non-file
source, custom part scheduling — the explicit `MultipartUpload` actor is
exposed on the client. See
[Examples/Multipart.swift](Examples/Multipart.swift) and PRD §7.7.

## Presigned URLs

`getURL(bucket:path:options:)` mints presigned URLs for `GET`, `PUT`, `HEAD`,
and `DELETE`. The signature is computed locally with no network round-trip.
Default lifetime is one hour; the maximum lifetime allowed by S3 is **7 days**
and the signer enforces that cap. See
[Examples/PresignedURL.swift](Examples/PresignedURL.swift) and Concepts.md
("Presigned URLs").

## Retries

Transient failures (HTTP 5xx, `RequestTimeout`, `SlowDown`) are retried
automatically with exponential backoff plus full jitter, up to 5 attempts by
default and configurable on `BucketClient`. Non-retriable service errors
surface as `BucketServiceError`; transport-level failures surface as
`BucketClientError.transport(URLError)`. See PRD §9.

## Logging

BucketKit logs through `os.Logger` only, under the subsystem
`dev.brennanmke.bucket` (categories: `signing`, `client`, `multipart`,
`transport`, `xml`). Default level is `.info`; `.debug` is enabled per-category
in `DEBUG` builds. Credentials, full `Authorization` headers, and full
presigned URLs are **never** emitted — only opaque request IDs and S3 error
codes. See PRD §11.

## Testing

Unit tests (signer test vectors, XML decoding, presigning shape, retry logic):

```sh
swift test
```

Integration tests against a local MinIO (Docker required):

```sh
bash scripts/minio-up.sh
swift test --filter BucketIntegrationTests
bash scripts/minio-down.sh
```

The integration target self-skips with a `[skip]` log line when MinIO is
unreachable, so `swift test` stays green on any developer machine.

Real-provider smoke tests against AWS, R2, and Spaces are gated behind env
vars (`BUCKETKIT_AWS_TEST=1`, `BUCKETKIT_R2_TEST=1`, `BUCKETKIT_DO_TEST=1`) and
provision throwaway buckets per run with a UUID suffix. Full env-var matrix
and per-provider examples in [scripts/README.md](scripts/README.md).

## Pointers

- Product requirements, public API, milestones: [PRD.md](PRD.md)
- S3 vocabulary the API assumes: [Concepts.md](Concepts.md)
- Source-stability tiers ahead of v1.0: [STABILITY.md](STABILITY.md)
- Copy-pasteable snippets per concept: [Examples/](Examples/)

## License

BucketKit is released under the terms in [LICENSE](LICENSE).
