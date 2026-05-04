import Foundation
import Testing
@testable import Bucket

/// Real-provider smoke tests against DigitalOcean Spaces.
///
/// **Gate:** these tests run only when `BUCKETKIT_DO_TEST=1` is set in
/// the environment. With the gate unset every `@Test` short-circuits
/// with a `[skip]` log line, so the suite is safe to include in the
/// default `swift test` run.
///
/// **Credentials:** read from `BUCKETKIT_DO_REGION` (e.g. `nyc3`,
/// `sfo3`), `BUCKETKIT_DO_ACCESS_KEY_ID`, and
/// `BUCKETKIT_DO_SECRET_ACCESS_KEY`. When any required value is
/// missing the suite logs `[skip] Spaces: missing credentials` and
/// returns. Credentials are never hard-coded.
///
/// **Side effects:** each test creates a real, throwaway Space with a
/// UUID-suffixed name and deletes it via `defer`. Running this suite
/// against a real DigitalOcean account will incur (small) charges.
@Suite("DigitalOcean Spaces smoke tests")
struct DOSpacesSmokeTests {

    // MARK: - Helper

    /// Builds a configured ``BucketClient`` for DigitalOcean Spaces,
    /// or returns `nil` and prints a `[skip]` line if the gate or
    /// credentials are not present.
    static func spacesClient() -> BucketClient? {
        let env = ProcessInfo.processInfo.environment

        guard env["BUCKETKIT_DO_TEST"] == "1" else {
            print("[skip] Spaces: gate not set")
            return nil
        }

        guard
            let region = env["BUCKETKIT_DO_REGION"], !region.isEmpty,
            let accessKeyID = env["BUCKETKIT_DO_ACCESS_KEY_ID"], !accessKeyID.isEmpty,
            let secretAccessKey = env["BUCKETKIT_DO_SECRET_ACCESS_KEY"], !secretAccessKey.isEmpty
        else {
            print("[skip] Spaces: missing credentials")
            return nil
        }

        let configuration = BucketConfiguration.digitalOceanSpaces(
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey
        )
        return BucketClient(configuration: configuration)
    }

    /// Builds a fresh, UUID-suffixed Space name. Spaces follow the
    /// same DNS-style naming rules AWS uses, so we keep the prefix
    /// lowercase and use a short lowercased UUID slice.
    static func uniqueBucketName() -> String {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        return "bucketkit-smoke-\(suffix)"
    }

    // MARK: - Tests

    @Test("creates and deletes a bucket")
    func createsAndDeletesBucket() async throws {
        guard let client = Self.spacesClient() else { return }

        let bucket = Self.uniqueBucketName()
        // DigitalOcean Spaces ignores `LocationConstraint`; the
        // geographic region is encoded in the endpoint hostname.
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
        guard let client = Self.spacesClient() else { return }

        let bucket = Self.uniqueBucketName()
        try await client.createBucket(bucket)
        defer {
            Task.detached { try? await client.deleteBucket(bucket) }
        }

        let key = "hello.txt"
        let payload = Data("hello, Spaces".utf8)
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
        guard let client = Self.spacesClient() else { return }

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
