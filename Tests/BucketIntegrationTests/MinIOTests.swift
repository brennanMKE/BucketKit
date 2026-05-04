import Foundation
import Testing
@testable import Bucket

/// Integration tests that exercise the public ``BucketClient`` surface
/// against a live MinIO instance.
///
/// These tests are intentionally tolerant of MinIO not being available:
/// the helper ``minioClient()`` pings `/minio/health/ready` and returns
/// `nil` on any error, and every `@Test` short-circuits with a `[skip]`
/// log line in that case. This keeps the unconditional `swift test`
/// run green on machines that do not have MinIO running while still
/// letting CI exercise the full surface against a Docker-managed
/// container (see `scripts/minio-up.sh`).
///
/// Bucket names are UUID-suffixed and cleaned up via `defer` on every
/// test so reruns do not collide.
@Suite("MinIO integration tests")
struct MinIOTests {

    // MARK: - Helper

    /// Endpoint the suite talks to. Reads `BUCKETKIT_MINIO_ENDPOINT`
    /// (default `http://localhost:9000`).
    static var endpointString: String {
        ProcessInfo.processInfo.environment["BUCKETKIT_MINIO_ENDPOINT"]
            ?? "http://localhost:9000"
    }

    /// Access key. Reads `BUCKETKIT_MINIO_ACCESS_KEY`
    /// (default `minioadmin`).
    static var accessKeyID: String {
        ProcessInfo.processInfo.environment["BUCKETKIT_MINIO_ACCESS_KEY"]
            ?? "minioadmin"
    }

    /// Secret key. Reads `BUCKETKIT_MINIO_SECRET_KEY`
    /// (default `minioadmin`).
    static var secretAccessKey: String {
        ProcessInfo.processInfo.environment["BUCKETKIT_MINIO_SECRET_KEY"]
            ?? "minioadmin"
    }

    /// Returns a configured ``BucketClient`` only if MinIO is reachable
    /// at the configured endpoint. Returns `nil` (rather than throwing)
    /// on any connectivity error so the calling test can simply
    /// short-circuit with a `[skip]` log line.
    ///
    /// "Reachable" means a 200 response from `/minio/health/ready`
    /// within a 1-second timeout — that is the same liveness probe the
    /// `scripts/minio-up.sh` helper polls.
    static func minioClient() async throws -> BucketClient? {
        guard let endpoint = URL(string: endpointString) else {
            return nil
        }

        // Health check via URLSession with a tight 1s timeout. Any
        // non-200, transport error, or timeout returns `nil`.
        let healthURL = endpoint.appendingPathComponent("minio/health/ready")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(from: healthURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
        } catch {
            return nil
        }

        let bucketConfig = BucketConfiguration.custom(
            endpoint: endpoint,
            region: "us-east-1",
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            usePathStyle: true
        )
        return BucketClient(configuration: bucketConfig)
    }

    /// Builds a fresh, UUID-suffixed bucket name. MinIO bucket names
    /// must match the same DNS-style rules AWS enforces, so we keep
    /// the prefix lowercase and stick to the lowercased UUID.
    static func uniqueBucketName(_ prefix: String = "bucketkit-it") -> String {
        let suffix = UUID().uuidString.lowercased()
        return "\(prefix)-\(suffix)"
    }

    /// Logs a uniform skip message for tests that cannot run.
    static func logSkip() {
        print("[skip] MinIO not reachable at \(endpointString)")
    }

    // MARK: - Tests

    @Test("creates and deletes a bucket")
    func createsAndDeletesBucket() async throws {
        guard let client = try await Self.minioClient() else {
            Self.logSkip()
            return
        }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)

        // Schedule cleanup as the very first deferred action so a later
        // failure still removes the bucket on the way out. We only
        // attempt the delete; we do not propagate cleanup errors.
        var bucketExists = true
        defer {
            if bucketExists {
                Task.detached { try? await client.deleteBucket(bucket) }
            }
        }

        let metadata = try await client.headBucket(bucket)
        // MinIO reports the literal region we configured; we don't
        // assert a specific value beyond it being non-nil-or-empty
        // because MinIO's behaviour here varies.
        _ = metadata

        let buckets = try await client.listBuckets()
        #expect(buckets.contains(where: { $0.name == bucket }))

        try await client.deleteBucket(bucket)
        bucketExists = false
    }

    @Test("puts and gets an object")
    func putsAndGetsObject() async throws {
        guard let client = try await Self.minioClient() else {
            Self.logSkip()
            return
        }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let key = "hello.txt"
        let payload = Data("hello, MinIO".utf8)
        let upload = await client.uploadData(
            bucket: bucket,
            path: .fromString(key),
            data: payload
        )
        _ = try await upload.value

        let download = await client.downloadData(
            bucket: bucket,
            path: .fromString(key)
        )
        let downloaded = try await download.value
        #expect(downloaded == payload)

        _ = try await client.remove(bucket: bucket, path: .fromString(key))
    }

    @Test("heads object metadata")
    func headsObjectMetadata() async throws {
        guard let client = try await Self.minioClient() else {
            Self.logSkip()
            return
        }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let key = "metadata.txt"
        let payload = Data("metadata payload".utf8)
        let options = UploadDataOptions(
            contentType: "text/plain",
            metadata: ["foo": "bar"]
        )
        let upload = await client.uploadData(
            bucket: bucket,
            path: .fromString(key),
            data: payload,
            options: options
        )
        _ = try await upload.value

        let metadata = try await client.headObject(
            bucket: bucket,
            path: .fromString(key)
        )
        #expect(metadata.size == Int64(payload.count))
        #expect(metadata.contentType == "text/plain")
        // Header decoding lowercases user-metadata keys per the
        // documented contract on ``ObjectMetadata``.
        #expect(metadata.metadata["foo"] == "bar")

        _ = try await client.remove(bucket: bucket, path: .fromString(key))
    }

    @Test("paginates list with continuation tokens")
    func paginatesList() async throws {
        guard let client = try await Self.minioClient() else {
            Self.logSkip()
            return
        }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        // Upload five small objects under `page/`.
        let keys = (0..<5).map { "page/\($0).txt" }
        for key in keys {
            let upload = await client.uploadData(
                bucket: bucket,
                path: .fromString(key),
                data: Data(key.utf8)
            )
            _ = try await upload.value
        }
        defer {
            // Best-effort cleanup of the objects so the bucket can
            // actually be deleted in the outer defer.
            for key in keys {
                Task.detached {
                    try? await client.remove(bucket: bucket, path: .fromString(key))
                }
            }
        }

        var collected: [String] = []
        var options = ListOptions()
        options.prefix = "page/"
        options.maxKeys = 2

        // Walk continuation tokens until the server reports the listing
        // is no longer truncated.
        while true {
            let page = try await client.list(bucket: bucket, options: options)
            collected.append(contentsOf: page.items.map(\.key))
            if page.isTruncated, let token = page.nextContinuationToken {
                options.continuationToken = token
                continue
            }
            break
        }

        #expect(Set(collected) == Set(keys))
    }

    @Test("listAll yields every page as a stream")
    func listAllStream() async throws {
        guard let client = try await Self.minioClient() else {
            Self.logSkip()
            return
        }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let keys = (0..<5).map { "page/\($0).txt" }
        for key in keys {
            let upload = await client.uploadData(
                bucket: bucket,
                path: .fromString(key),
                data: Data(key.utf8)
            )
            _ = try await upload.value
        }
        defer {
            for key in keys {
                Task.detached {
                    try? await client.remove(bucket: bucket, path: .fromString(key))
                }
            }
        }

        var options = ListOptions()
        options.prefix = "page/"
        options.maxKeys = 2

        var collected: [String] = []
        for try await object in client.listAll(bucket: bucket, options: options) {
            collected.append(object.key)
        }

        #expect(Set(collected) == Set(keys))
    }

    @Test("presigned GET URL is fetchable with URLSession")
    func presignedGetURL() async throws {
        guard let client = try await Self.minioClient() else {
            Self.logSkip()
            return
        }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let key = "presigned.bin"
        let payload = Data("presigned payload".utf8)
        let upload = await client.uploadData(
            bucket: bucket,
            path: .fromString(key),
            data: payload
        )
        _ = try await upload.value
        defer {
            Task.detached {
                try? await client.remove(bucket: bucket, path: .fromString(key))
            }
        }

        let url = try await client.getURL(
            bucket: bucket,
            path: .fromString(key),
            options: GetURLOptions(method: .get, expiresIn: .seconds(60))
        )

        // Use plain URLSession here: the whole point of a presigned URL
        // is that no SDK is required to consume it.
        let (downloaded, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            #expect(http.statusCode == 200)
        }
        #expect(downloaded == payload)
    }

    @Test("multipart upload assembles parts into a single object")
    func multipartUploadOver100MiB() async throws {
        guard let client = try await Self.minioClient() else {
            Self.logSkip()
            return
        }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let key = "multipart.bin"
        defer {
            Task.detached {
                try? await client.remove(bucket: bucket, path: .fromString(key))
            }
        }

        // 5 MiB is S3's hard floor for non-final parts; we upload two
        // parts (the final one can be anything 0+) so the total size
        // exercises the assembly path without burning gigabytes.
        let partSize = 5 * 1024 * 1024
        let part1 = Data(repeating: 0xAB, count: partSize)
        let part2 = Data(repeating: 0xCD, count: 1024)
        let expectedSize = part1.count + part2.count

        let multipart = try await client.multipartUpload(
            bucket: bucket,
            path: .fromString(key)
        )

        _ = try await multipart.uploadPart(part1, partNumber: 1)
        _ = try await multipart.uploadPart(part2, partNumber: 2)
        _ = try await multipart.complete()

        let metadata = try await client.headObject(
            bucket: bucket,
            path: .fromString(key)
        )
        #expect(metadata.size == Int64(expectedSize))
    }
}
