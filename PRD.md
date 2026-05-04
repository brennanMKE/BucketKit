# BucketKit — Product Requirements

**Status:** Draft v2 · **Last updated:** 2026-05-03

BucketKit is a Swift package for working with S3-compatible object storage services through a single, modern Swift API. It targets AWS S3, Cloudflare R2, and DigitalOcean Spaces as first-class providers from day one, plus MinIO / arbitrary endpoints for local development and testing. The same client and call sites work across providers — only the configuration changes.

The public API is modeled after AWS Amplify's `StorageCategoryBehavior` protocol so callers familiar with Amplify Storage have a near-zero learning curve, but BucketKit is a single-purpose S3 library — no Amplify category system, no plugins, no Cognito coupling.

## 1. Goals

- One Swift API across AWS S3, Cloudflare R2, and DigitalOcean Spaces.
- Idiomatic on modern Apple platforms: `async`/`await`, `actor`, `Sendable`, structured concurrency, typed errors, `AsyncSequence` for progress and listings.
- Familiar shape for Amplify users — same verbs (`uploadData`, `uploadFile`, `downloadData`, `downloadFile`, `getURL`, `remove`, `list`) and a path-based addressing model.
- Safe by construction: credentials never appear in URLs or logs, payloads stream for large files, request signing is correct against the official AWS SigV4 test vectors.
- Small enough to vendor and audit. Foundation + CryptoKit only; zero third-party dependencies.

## 2. Non-goals

- **No DispatchQueue, no Combine, no completion-handler API.** Swift Concurrency only.
- **Not a port of the AWS SDK.** BucketKit is S3 only.
- **Not Amplify.** No category system, no plugin loader, no Cognito or auth-rule coupling. We borrow the *shape* of Amplify's Storage API, not its architecture.
- **No GUI, no credential UI, no keychain integration.** Callers supply credentials.
- **Not a CLI tool.** A companion macOS test app (issue #0003) is separate.
- **No Linux support.** Apple platforms only — `os.Logger` and Apple SDKs are assumed.

## 3. Target users

Swift developers building iOS, iPadOS, macOS, tvOS, watchOS, or visionOS apps that need to upload, download, list, or manage objects in S3-compatible storage. Typical use cases: user-generated content uploads, asset distribution from R2, backups to Spaces, integration tests against a local MinIO.

## 4. Supported platforms and toolchain

- **Swift tools:** `swift-tools-version: 6.3`, language mode `.v6`.
- **Strict concurrency:** complete checking. All public types `Sendable`.
- **Platforms (current minus one — current is .v26 family):**

```swift
platforms: [
    .macOS(.v15),
    .iOS(.v18),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2),
]
```

## 5. Providers (all first-class on day one)

| Provider | Endpoint pattern | SigV4 region | URL style |
|---|---|---|---|
| AWS S3 | `https://s3.{region}.amazonaws.com` | real region | virtual-hosted |
| Cloudflare R2 | `https://{accountID}.r2.cloudflarestorage.com` | `auto` | virtual-hosted |
| Cloudflare R2 (jurisdiction) | `https://{accountID}.eu.r2.cloudflarestorage.com`, `…fedramp…` | `auto` | virtual-hosted |
| DigitalOcean Spaces | `https://{region}.digitaloceanspaces.com` | `us-east-1` | virtual-hosted |
| MinIO / custom | user-supplied URL | user-supplied | path-style by default |

### Configuration

`BucketConfiguration` is a `Sendable` struct. Static factories cover the four shapes; the underlying initializer is also public for unusual setups.

```swift
public struct BucketConfiguration: Sendable {
    public var endpoint: URL
    public var region: String
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var usePathStyle: Bool

    public static func aws(region: String, accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) -> Self
    public static func r2(accountID: String, accessKeyID: String, secretAccessKey: String, jurisdiction: R2Jurisdiction = .default) -> Self
    public static func digitalOceanSpaces(region: String, accessKeyID: String, secretAccessKey: String) -> Self
    public static func custom(endpoint: URL, region: String, accessKeyID: String, secretAccessKey: String, usePathStyle: Bool = true) -> Self
}
```

## 6. Authentication

- **AWS Signature Version 4** for every request. No bearer tokens, no auth endpoint, no token refresh.
- Credentials are an `(accessKeyID, secretAccessKey, sessionToken?)` triple supplied by the caller.
- The signer is implemented in-package using `CryptoKit` (`SHA256`, `HMAC<SHA256>`, `SymmetricKey`).
- Presigned URLs (GET, PUT, HEAD, DELETE) computed locally with no network round-trip; `expiresIn` capped at 7 days per S3 spec.
- `X-Amz-Security-Token` added automatically when a session token is present.
- The signer is validated against the official AWS SigV4 test suite as part of the package's tests.

## 7. Public API surface

The hub is `BucketClient`, an `actor` modeled after Amplify's `StorageCategoryBehavior`. Methods are named after their Amplify equivalents but use BucketKit-native option types (no Amplify dependency).

### 7.1 Path addressing

Like Amplify, BucketKit uses a `BucketPath` value to identify objects. A path resolves to a literal S3 object key when the operation runs:

```swift
public protocol BucketPath: Sendable {
    func resolve() -> String
}

public struct StringBucketPath: BucketPath {
    public let value: String
    public func resolve() -> String { value }
}

public extension BucketPath where Self == StringBucketPath {
    static func fromString(_ s: String) -> Self { StringBucketPath(value: s) }
}
```

This keeps the door open for future resolvers (e.g. an identity-prefixed path) without changing call sites. For v1, `StringBucketPath` is the only built-in conformance.

### 7.2 Client surface (Amplify-shaped verbs)

```swift
public actor BucketClient {
    public init(configuration: BucketConfiguration, transport: HTTPTransport = URLSessionTransport.shared)

    // Presigned URL
    public func getURL(
        bucket: String,
        path: any BucketPath,
        options: GetURLOptions = .init()
    ) async throws -> URL

    // Downloads — return a task with progress + cancellation
    public func downloadData(
        bucket: String,
        path: any BucketPath,
        options: DownloadDataOptions = .init()
    ) -> BucketDownloadDataTask

    public func downloadFile(
        bucket: String,
        path: any BucketPath,
        local: URL,
        options: DownloadFileOptions = .init()
    ) -> BucketDownloadFileTask

    // Uploads — return a task with progress + cancellation
    public func uploadData(
        bucket: String,
        path: any BucketPath,
        data: Data,
        options: UploadDataOptions = .init()
    ) -> BucketUploadDataTask

    public func uploadFile(
        bucket: String,
        path: any BucketPath,
        local: URL,
        options: UploadFileOptions = .init()
    ) -> BucketUploadFileTask

    // Simple async operations
    public func remove(
        bucket: String,
        path: any BucketPath,
        options: RemoveOptions = .init()
    ) async throws -> String

    public func list(
        bucket: String,
        path: any BucketPath? = nil,
        options: ListOptions = .init()
    ) async throws -> BucketListResult

    // Bucket-level convenience (BucketKit additions over Amplify)
    public func listBuckets() async throws -> [BucketInfo]
    public func createBucket(_ name: String, locationConstraint: String? = nil) async throws
    public func deleteBucket(_ name: String) async throws
    public func headBucket(_ name: String) async throws -> BucketMetadata
}
```

`bucket:` is an explicit per-call argument rather than a configuration field. This matches Amplify's optional `bucket` override and lets one client talk to many buckets without re-configuring.

### 7.3 Tasks (progress + cancellation)

Upload and download return task types that vend an `AsyncStream` of progress events and a `value` for the final result. They are `Sendable` and forward `Task` cancellation through to the in-flight HTTP request and, for multipart, abort the upload as a best-effort.

```swift
public protocol BucketTransferTask<Output>: Sendable {
    associatedtype Output: Sendable
    var progress: AsyncStream<TransferProgress> { get }
    var value: Output { get async throws }
    func cancel()
    func pause()
    func resume()
}

public struct TransferProgress: Sendable, Hashable {
    public let totalBytes: Int64?      // nil if unknown
    public let bytesTransferred: Int64
    public let fractionCompleted: Double?
}

public struct BucketDownloadDataTask: BucketTransferTask {
    public typealias Output = Data
    // …
}

public struct BucketDownloadFileTask: BucketTransferTask {
    public typealias Output = URL
}

public struct BucketUploadDataTask: BucketTransferTask {
    public typealias Output = UploadResult
}

public struct BucketUploadFileTask: BucketTransferTask {
    public typealias Output = UploadResult
}

public struct UploadResult: Sendable, Hashable {
    public let key: String
    public let eTag: String
    public let versionID: String?
}
```

**Why tasks instead of plain `async throws`?** Uploads and downloads have three things callers care about beyond the final value: progress, pause/resume, and cancellation independent of structured task cancellation. Amplify's API splits this out for the same reason, and we match it.

For simple cases callers just `await task.value` and ignore progress.

### 7.4 Options

Each operation has a small `Options` struct. Examples (full set in `Sources/BucketKit/Options/`):

```swift
public struct UploadDataOptions: Sendable {
    public var contentType: String?
    public var cacheControl: String?
    public var metadata: [String: String]
    public var acl: ObjectACL?
    public var storageClass: StorageClass?
    public var serverSideEncryption: ServerSideEncryption?
    public var ifNoneMatch: String?         // for create-only writes
    public var partSize: Int?               // hint for multipart threshold/size
    public var concurrency: Int?            // multipart parallelism
}

public struct DownloadDataOptions: Sendable {
    public var range: Range<Int64>?
    public var ifNoneMatch: String?
    public var ifMatch: String?
}

public struct GetURLOptions: Sendable {
    public var method: HTTPMethod = .get    // GET, PUT, HEAD, DELETE
    public var expiresIn: Duration = .seconds(3600)
    public var headersToSign: [String: String] = [:]
}

public struct ListOptions: Sendable {
    public var prefix: String?
    public var delimiter: String?
    public var maxKeys: Int?
    public var continuationToken: String?
    public var listAll: Bool = false        // auto-paginate
}
```

### 7.5 List results and pagination

```swift
public struct BucketListResult: Sendable {
    public let items: [BucketObject]
    public let commonPrefixes: [String]
    public let isTruncated: Bool
    public let nextContinuationToken: String?
}

public struct BucketObject: Sendable, Hashable {
    public let key: String
    public let size: Int64
    public let lastModified: Date
    public let eTag: String
    public let storageClass: StorageClass?
}

extension BucketClient {
    /// Convenience: AsyncSequence over paginated results, automatically following continuation tokens.
    public func listAll(
        bucket: String,
        path: (any BucketPath)? = nil,
        options: ListOptions = .init()
    ) -> AsyncThrowingStream<BucketObject, Error>
}
```

### 7.6 Server-side encryption

We follow Amplify-AWSS3's approach: SSE is exposed both as a typed convenience and as header pass-through for callers who need full control.

```swift
public enum ServerSideEncryption: Sendable {
    case aes256                                          // SSE-S3
    case awsKMS(keyID: String?)                          // SSE-KMS
    case customer(key: Data, keyMD5: Data)               // SSE-C
}
```

`UploadDataOptions.serverSideEncryption` translates into the appropriate `x-amz-server-side-encryption*` headers on PUT. Plain header pass-through is also available via an escape hatch on `BucketConfiguration.extraHeaders` for advanced cases (e.g. `x-amz-bucket-key-enabled`).

### 7.7 Multipart upload

For uploads larger than a configurable threshold (default 100 MiB, hard floor 5 MiB), `uploadFile` automatically uses S3 multipart with parallel parts. For callers who want explicit control, the actor is exposed:

```swift
public actor MultipartUpload {
    public func uploadPart(_ data: Data, partNumber: Int) async throws -> UploadedPart
    public func uploadPart(fileURL: URL, partNumber: Int) async throws -> UploadedPart
    public func complete() async throws -> UploadResult
    public func abort() async throws
}

extension BucketClient {
    public func multipartUpload(
        bucket: String,
        path: any BucketPath,
        options: UploadDataOptions = .init()
    ) async throws -> MultipartUpload
}
```

Cancellation aborts the upload as a best effort.

## 8. Errors

Two error types are sufficient: a typed S3 protocol error and a small client-side error.

```swift
public struct BucketServiceError: Error, Sendable {
    public let code: String          // e.g. "NoSuchBucket", "AccessDenied"
    public let message: String
    public let requestID: String?
    public let httpStatus: Int
    public let resource: String?
}

public enum BucketClientError: Error, Sendable {
    case invalidConfiguration(String)
    case signingFailed(String)
    case transport(URLError)
    case decodingFailed(String)
    case multipartPartTooSmall(partNumber: Int, size: Int)
    case cancelled
}
```

## 9. Networking

- Default transport is `URLSession` (`.shared` by default; configurable).
- Retry on HTTP 5xx and `RequestTimeout`/`SlowDown` with exponential backoff plus full jitter; max 5 attempts, configurable on `BucketClient`.
- `HTTPTransport` is a small `Sendable` protocol so callers (and tests) can swap implementations:

```swift
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, body: TransportBody?) async throws -> (Data, HTTPURLResponse)
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse
}
```

No `URLSessionDataTask` callbacks, no Combine publishers, no Dispatch queues.

## 10. XML decoding (custom SAX parser)

S3 responses are XML. BucketKit ships a small SAX-style parser built on `XMLParser`, exposed only internally:

```
Sources/BucketKit/XML/
├── SAXReader.swift           // event-driven Foundation XMLParser wrapper
├── XMLDecoder.swift          // Codable bridge for fixed schemas
└── ResponseModels.swift      // ListBucketResult, Error, Initiate/Complete multipart, …
```

This avoids a third-party dependency and keeps decoding zero-copy where possible. The SAX layer is reused for streaming list pagination so we never load a 10 MB listing fully into memory before yielding the first result.

## 11. Logging

- `os.Logger` from `OSLog` only.
- Subsystem: `dev.brennanmke.bucket` (rename if/when the package is published under a different bundle ID).
- Categories: `signing`, `client`, `multipart`, `transport`, `xml`.
- Default level `.info`; `.debug` enabled per-category in `DEBUG` builds.
- **Never** emit credentials, full `Authorization` headers, or full presigned URLs in logs. Only opaque request IDs and S3 error codes.

## 12. Concurrency model

- `BucketClient` is an `actor` — one instance per app is fine.
- All public types are `Sendable`.
- Tasks (`BucketUploadDataTask`, etc.) are `Sendable` value types backed by an internal actor.
- Long-running operations honour structured task cancellation: cancellation aborts in-flight HTTP and, for multipart, calls `abort()` on the upload as a best effort.
- No `@MainActor` annotations on the public API; UI bridging is the caller's responsibility.

## 13. Dependencies

- **Apple platforms only.** Foundation, CryptoKit, OSLog. No third-party packages.

## 14. Testing

- **SigV4 conformance:** AWS official test vectors run as unit tests; canonical request, string-to-sign, and final signature each asserted.
- **Unit tests:** model decoding, query-string canonicalisation, SAX parser correctness, retry/backoff logic, presigned URL shape.
- **Integration tests against MinIO:** spun up via Docker in CI; covers create-bucket, put/get/head/delete, list pagination, multipart, presigned URLs.
- **Real-provider smoke tests:** gated behind env vars (`BUCKETKIT_AWS_TEST=1`, `BUCKETKIT_R2_TEST=1`, `BUCKETKIT_DO_TEST=1`); throwaway bucket per run with UUID suffix.
- **Manual exploratory testing:** macOS test app (issue #0003) drives the full surface against real services without rebuilding.

## 15. Out of scope (for v1)

- Bucket policies, lifecycle, replication, inventory, analytics, S3 Select, Object Lambda, Access Points.
- Object tagging (`?tagging`) — gated on R2 parity.
- POST form uploads (browser-style direct uploads).
- Credential providers (env, `~/.aws/credentials`, IMDS, AssumeRole). Callers construct `BucketConfiguration` directly.
- Background `URLSession` for app-suspended uploads — desirable but deferred; Amplify's plugin handles this, we'd need to design our own session-tag scheme.

## 16. Package layout

```
BucketKit/
├── Package.swift
├── Sources/
│   └── BucketKit/
│       ├── Configuration/
│       │   ├── BucketConfiguration.swift
│       │   └── R2Jurisdiction.swift
│       ├── Signing/
│       │   ├── SigV4Signer.swift
│       │   ├── CanonicalRequest.swift
│       │   └── PresignedURL.swift
│       ├── Client/
│       │   ├── BucketClient.swift
│       │   ├── HTTPTransport.swift
│       │   ├── URLSessionTransport.swift
│       │   └── RetryPolicy.swift
│       ├── Operations/
│       │   ├── Buckets.swift
│       │   ├── GetURL.swift
│       │   ├── Upload.swift
│       │   ├── Download.swift
│       │   ├── Remove.swift
│       │   ├── List.swift
│       │   └── Multipart.swift
│       ├── Tasks/
│       │   ├── BucketTransferTask.swift
│       │   ├── BucketUploadDataTask.swift
│       │   ├── BucketUploadFileTask.swift
│       │   ├── BucketDownloadDataTask.swift
│       │   └── BucketDownloadFileTask.swift
│       ├── Models/
│       │   ├── BucketInfo.swift
│       │   ├── BucketObject.swift
│       │   ├── BucketListResult.swift
│       │   ├── ObjectACL.swift
│       │   ├── StorageClass.swift
│       │   ├── ServerSideEncryption.swift
│       │   └── UploadResult.swift
│       ├── Options/
│       │   ├── UploadDataOptions.swift
│       │   ├── UploadFileOptions.swift
│       │   ├── DownloadDataOptions.swift
│       │   ├── DownloadFileOptions.swift
│       │   ├── GetURLOptions.swift
│       │   ├── ListOptions.swift
│       │   └── RemoveOptions.swift
│       ├── Path/
│       │   ├── BucketPath.swift
│       │   └── StringBucketPath.swift
│       ├── Errors/
│       │   ├── BucketServiceError.swift
│       │   └── BucketClientError.swift
│       ├── XML/
│       │   ├── SAXReader.swift
│       │   ├── XMLDecoder.swift
│       │   └── ResponseModels.swift
│       └── Logging/
│           └── Loggers.swift
└── Tests/
    └── BucketKitTests/
        ├── SigV4SignerTests.swift          // AWS test vectors
        ├── CanonicalRequestTests.swift
        ├── SAXReaderTests.swift
        ├── PresignedURLTests.swift
        └── IntegrationTests.swift          // env-var gated
```

## 17. Milestones

1. **M1 — Signer & configuration.** SigV4 implementation, configuration factories, AWS test-vector pass.
2. **M2 — Core object ops.** uploadData, uploadFile, downloadData, downloadFile, remove, headObject; tasks with progress + cancellation.
3. **M3 — Bucket ops, list, errors.** listBuckets, createBucket, deleteBucket, headBucket, list (with pagination), SAX-based XML error decoding.
4. **M4 — Multipart & presigned.** Automatic multipart on `uploadFile`, explicit `MultipartUpload` actor, `getURL` for all four methods.
5. **M5 — Cross-provider validation.** MinIO integration tests; smoke tests on AWS, R2, Spaces; macOS test app (issue #0003) exercises every operation.
6. **M6 — Polish.** Retries, structured cancellation, logging, README, sample code, source stability review.
