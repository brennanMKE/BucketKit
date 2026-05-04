import Foundation
import Testing
@testable import Bucket

/// Real-provider smoke tests against Cloudflare R2.
///
/// **Gate:** these tests run only when `BUCKETKIT_R2_TEST=1` is set in
/// the environment. With the gate unset every `@Test` short-circuits
/// with a `[skip]` log line, so the suite is safe to include in the
/// default `swift test` run.
///
/// **Credentials:** read from `BUCKETKIT_R2_ACCOUNT_ID`,
/// `BUCKETKIT_R2_ACCESS_KEY_ID`, `BUCKETKIT_R2_SECRET_ACCESS_KEY`, and
/// optional `BUCKETKIT_R2_JURISDICTION` (`default`, `eu`, or
/// `fedramp` — default `default`). When any required credential is
/// missing the suite logs `[skip] R2: missing credentials` and
/// returns. Credentials are never hard-coded.
///
/// **Side effects:** each test creates a real, throwaway bucket with a
/// UUID-suffixed name and deletes it via `defer`. Running this suite
/// against a real Cloudflare account will incur (small) charges.
@Suite("Cloudflare R2 smoke tests")
struct R2SmokeTests {

    // MARK: - Helper

    /// Builds a configured ``BucketClient`` for Cloudflare R2, or
    /// returns `nil` and prints a `[skip]` line if the gate or
    /// credentials are not present.
    static func r2Client() -> BucketClient? {
        let env = ProcessInfo.processInfo.environment

        guard env["BUCKETKIT_R2_TEST"] == "1" else {
            print("[skip] R2: gate not set")
            return nil
        }

        guard
            let accountID = env["BUCKETKIT_R2_ACCOUNT_ID"], !accountID.isEmpty,
            let accessKeyID = env["BUCKETKIT_R2_ACCESS_KEY_ID"], !accessKeyID.isEmpty,
            let secretAccessKey = env["BUCKETKIT_R2_SECRET_ACCESS_KEY"], !secretAccessKey.isEmpty
        else {
            print("[skip] R2: missing credentials")
            return nil
        }

        let jurisdiction: R2Jurisdiction = {
            switch env["BUCKETKIT_R2_JURISDICTION"]?.lowercased() {
            case "eu": return .eu
            case "fedramp": return .fedramp
            default: return .default
            }
        }()

        let configuration = BucketConfiguration.r2(
            accountID: accountID,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            jurisdiction: jurisdiction
        )
        return BucketClient(configuration: configuration)
    }

    /// Builds a fresh, UUID-suffixed bucket name. R2 follows the same
    /// DNS-style naming rules AWS does, so we keep the prefix
    /// lowercase and use a short lowercased UUID slice.
    static func uniqueBucketName() -> String {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        return "bucketkit-smoke-\(suffix)"
    }

    // MARK: - Tests

    @Test("creates and deletes a bucket")
    func createsAndDeletesBucket() async throws {
        guard let client = Self.r2Client() else { return }

        let bucket = Self.uniqueBucketName()
        // R2 ignores `LocationConstraint` for the plain `default`
        // jurisdiction. We omit it to match the documented contract;
        // the jurisdiction is already encoded in the endpoint
        // hostname via ``BucketConfiguration.r2(jurisdiction:)``.
        try await client.createBucket(bucket)

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
        guard let client = Self.r2Client() else { return }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let key = "hello.txt"
        let payload = Data("hello, R2".utf8)
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
        guard let client = Self.r2Client() else { return }

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

        let (downloaded, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            #expect(http.statusCode == 200)
        }
        #expect(downloaded == payload)
    }
}
