import Foundation
import Testing
@testable import Bucket

/// Real-provider smoke tests against AWS S3.
///
/// **Gate:** these tests run only when `BUCKETKIT_AWS_TEST=1` is set in
/// the environment. With the gate unset every `@Test` short-circuits
/// with a `[skip]` log line, so the suite is safe to include in the
/// default `swift test` run.
///
/// **Credentials:** read from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
/// and optional `AWS_REGION` (default `us-east-1`). When any required
/// credential is missing the suite logs `[skip] AWS: missing
/// credentials` and returns. Credentials are never hard-coded.
///
/// **Side effects:** each test creates a real, throwaway bucket with a
/// UUID-suffixed name and deletes it via `defer`. Running this suite
/// against a real AWS account will incur (small) charges.
@Suite("AWS S3 smoke tests")
struct AWSSmokeTests {

    // MARK: - Helper

    /// Builds a configured ``BucketClient`` for AWS S3, or returns
    /// `nil` and prints a `[skip]` line if the gate or credentials are
    /// not present.
    static func awsClient() -> BucketClient? {
        let env = ProcessInfo.processInfo.environment

        guard env["BUCKETKIT_AWS_TEST"] == "1" else {
            print("[skip] AWS: gate not set")
            return nil
        }

        guard
            let accessKeyID = env["AWS_ACCESS_KEY_ID"], !accessKeyID.isEmpty,
            let secretAccessKey = env["AWS_SECRET_ACCESS_KEY"], !secretAccessKey.isEmpty
        else {
            print("[skip] AWS: missing credentials")
            return nil
        }

        let region = env["AWS_REGION"] ?? "us-east-1"

        let configuration = BucketConfiguration.aws(
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
        return BucketClient(configuration: configuration)
    }

    /// Builds a fresh, UUID-suffixed bucket name. AWS requires names
    /// be DNS-valid (lowercase, no underscores), and the suffix is
    /// short to keep us under the 63-character limit.
    static func uniqueBucketName() -> String {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        return "bucketkit-smoke-\(suffix)"
    }

    // MARK: - Tests

    @Test("creates and deletes a bucket")
    func createsAndDeletesBucket() async throws {
        guard let client = Self.awsClient() else { return }

        let bucket = Self.uniqueBucketName()
        // For AWS, only non-`us-east-1` regions require an explicit
        // location constraint. The factory's default region is
        // `us-east-1`, so we forward whatever region was configured.
        let region = client.configuration.region
        let constraint: String? = (region == "us-east-1") ? nil : region
        try await client.createBucket(bucket, locationConstraint: constraint)

        var bucketExists = true
        defer {
            if bucketExists {
                Task.detached { try? await client.deleteBucket(bucket) }
            }
        }

        _ = try await client.headBucket(bucket)

        let buckets = try await client.listBuckets()
        #expect(buckets.contains(where: { $0.name == bucket }))

        try await client.deleteBucket(bucket)
        bucketExists = false
    }

    @Test("puts and gets an object")
    func putsAndGetsObject() async throws {
        guard let client = Self.awsClient() else { return }

        let bucket = Self.uniqueBucketName()
        let region = client.configuration.region
        let constraint: String? = (region == "us-east-1") ? nil : region
        try await client.createBucket(bucket, locationConstraint: constraint)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let key = "hello.txt"
        let payload = Data("hello, AWS".utf8)
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

    @Test("presigned GET URL is fetchable with URLSession")
    func presignedGetURL() async throws {
        guard let client = Self.awsClient() else { return }

        let bucket = Self.uniqueBucketName()
        let region = client.configuration.region
        let constraint: String? = (region == "us-east-1") ? nil : region
        try await client.createBucket(bucket, locationConstraint: constraint)
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

        let (downloaded, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            #expect(http.statusCode == 200)
        }
        #expect(downloaded == payload)
    }
}
