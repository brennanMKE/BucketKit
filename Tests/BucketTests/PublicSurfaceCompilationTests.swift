// PublicSurfaceCompilationTests.swift
//
// Compile-only verification that the public API surface used by the
// snippets under `Examples/` still type-checks. The bodies of these
// tests are wrapped in `if Bool(false) { ... }` so the compiler walks
// every call shape but no HTTP request is ever issued. This guarantees
// the Examples/ folder (which is documentation, not part of the
// SwiftPM build) cannot drift from the public API without also
// breaking this test.
//
// If you change the public surface, update both:
//   - the relevant snippet in Examples/
//   - the matching call shape below
//
// Per issue #0025 the Examples/ folder is intentionally not compiled
// by SwiftPM. See Examples/README.md for the rationale.

import Foundation
import Testing
@testable import Bucket

@Suite("Public-surface compilation checks for Examples/ snippets")
struct PublicSurfaceCompilationTests {

    /// All `BucketConfiguration` provider factories from
    /// `Examples/Configuration.swift`.
    @Test
    func configurationFactoriesCompile() throws {
        if Bool(false) {
            _ = BucketConfiguration.aws(
                region: "us-east-1",
                accessKeyID: "id",
                secretAccessKey: "secret"
            )
            _ = BucketConfiguration.r2(
                accountID: "account",
                accessKeyID: "id",
                secretAccessKey: "secret"
            )
            _ = BucketConfiguration.r2(
                accountID: "account",
                accessKeyID: "id",
                secretAccessKey: "secret",
                jurisdiction: .eu
            )
            _ = BucketConfiguration.digitalOceanSpaces(
                region: "nyc3",
                accessKeyID: "id",
                secretAccessKey: "secret"
            )
            _ = BucketConfiguration.custom(
                endpoint: URL(string: "http://localhost:9000")!,
                region: "us-east-1",
                accessKeyID: "id",
                secretAccessKey: "secret",
                usePathStyle: true
            )
        }
    }

    /// Upload / download call shapes from
    /// `Examples/UploadDownload.swift`.
    @Test
    func uploadDownloadShapesCompile() async throws {
        if Bool(false) {
            let client = BucketClient(
                configuration: .aws(
                    region: "us-east-1",
                    accessKeyID: "id",
                    secretAccessKey: "secret"
                )
            )

            let upload = await client.uploadData(
                bucket: "b",
                path: .fromString("k"),
                data: Data(),
                options: UploadDataOptions(contentType: "text/plain")
            )
            for await event in upload.progress {
                _ = event.bytesTransferred
                _ = event.totalBytes
            }
            _ = try await upload.value

            let local = URL(fileURLWithPath: "/tmp/example")
            let fileUpload = await client.uploadFile(
                bucket: "b",
                path: .fromString("k"),
                local: local,
                options: UploadFileOptions()
            )
            _ = try await fileUpload.value

            let dataDownload = await client.downloadData(
                bucket: "b",
                path: .fromString("k")
            )
            let _: Data = try await dataDownload.value

            let fileDownload = await client.downloadFile(
                bucket: "b",
                path: .fromString("k"),
                local: local
            )
            let _: URL = try await fileDownload.value
        }
    }

    /// Listing call shapes from `Examples/ListObjects.swift`.
    @Test
    func listShapesCompile() async throws {
        if Bool(false) {
            let client = BucketClient(
                configuration: .aws(
                    region: "us-east-1",
                    accessKeyID: "id",
                    secretAccessKey: "secret"
                )
            )

            // Page-by-page with continuation token.
            var token: String? = nil
            repeat {
                var options = ListOptions(prefix: "p/", maxKeys: 1000)
                options.continuationToken = token
                let page = try await client.list(bucket: "b", options: options)
                token = page.isTruncated ? page.nextContinuationToken : nil
                _ = page.items
                _ = page.commonPrefixes
            } while token != nil

            // Streaming form.
            let stream = await client.listAll(
                bucket: "b",
                options: ListOptions(prefix: "p/")
            )
            for try await object in stream {
                _ = object.key
                _ = object.size
            }

            // Folder-style listing with delimiter.
            let folders = try await client.list(
                bucket: "b",
                options: ListOptions(prefix: "p/", delimiter: "/")
            )
            _ = folders.commonPrefixes
        }
    }

    /// Presigned URL call shapes from `Examples/PresignedURL.swift`.
    @Test
    func presignedURLShapesCompile() async throws {
        if Bool(false) {
            let client = BucketClient(
                configuration: .aws(
                    region: "us-east-1",
                    accessKeyID: "id",
                    secretAccessKey: "secret"
                )
            )

            let getURL = try await client.getURL(
                bucket: "b",
                path: .fromString("k"),
                options: GetURLOptions(method: .get, expiresIn: .seconds(3600))
            )
            _ = getURL

            let putURL = try await client.getURL(
                bucket: "b",
                path: .fromString("k"),
                options: GetURLOptions(method: .put, expiresIn: .seconds(900))
            )
            _ = putURL

            // 7-day cap.
            _ = try await client.getURL(
                bucket: "b",
                path: .fromString("k"),
                options: GetURLOptions(
                    method: .get,
                    expiresIn: .seconds(7 * 24 * 60 * 60)
                )
            )
        }
    }

    /// Explicit multipart shapes from `Examples/Multipart.swift`.
    @Test
    func multipartShapesCompile() async throws {
        if Bool(false) {
            let client = BucketClient(
                configuration: .aws(
                    region: "us-east-1",
                    accessKeyID: "id",
                    secretAccessKey: "secret"
                )
            )

            let upload = try await client.multipartUpload(
                bucket: "b",
                path: .fromString("k"),
                options: UploadDataOptions(contentType: "application/octet-stream")
            )

            do {
                _ = try await upload.uploadPart(Data(), partNumber: 1)
                _ = try await upload.complete()
            } catch {
                try? await upload.abort()
            }
        }
    }
}
