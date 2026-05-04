// Examples/PresignedURL.swift
//
// Presigned URLs let a third party (browser, CDN, another service) run
// a single S3 operation without holding credentials. The URL is
// computed locally — no network round-trip — and is bound to one HTTP
// method.
//
// Expiry note: the maximum lifetime allowed by S3 is **7 days**
// (`Duration.seconds(604_800)`). Asking for longer raises
// `BucketClientError.invalidConfiguration` at signing time.

import Foundation
import Bucket

/// Mints a presigned `GET` URL valid for one hour, then fetches the
/// object body via `URLSession`. Useful for handing a download URL to
/// a browser or CDN.
public func samplePresignedDownload(
    client: BucketClient,
    bucket: String
) async throws -> Data {
    let url = try await client.getURL(
        bucket: bucket,
        path: .fromString("examples/hello.txt"),
        options: GetURLOptions(method: .get, expiresIn: .seconds(3600))
    )

    let (data, _) = try await URLSession.shared.data(from: url)
    return data
}

/// Mints a presigned `PUT` URL valid for fifteen minutes, then uploads
/// bytes to it via `URLSession`. The caller of the URL doesn't need
/// any AWS credentials.
public func samplePresignedUpload(
    client: BucketClient,
    bucket: String,
    payload: Data
) async throws {
    let url = try await client.getURL(
        bucket: bucket,
        path: .fromString("examples/uploaded-via-presigned.bin"),
        options: GetURLOptions(method: .put, expiresIn: .seconds(900))
    )

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    let (_, response) = try await URLSession.shared.upload(for: request, from: payload)
    print("PUT \((response as? HTTPURLResponse)?.statusCode ?? -1)")
}

/// Up to 7 days is allowed by S3. This snippet shows the maximum.
public func sampleMaxExpiryURL(
    client: BucketClient,
    bucket: String
) async throws -> URL {
    return try await client.getURL(
        bucket: bucket,
        path: .fromString("examples/long-lived.txt"),
        options: GetURLOptions(
            method: .get,
            expiresIn: .seconds(7 * 24 * 60 * 60) // 7 days, the cap.
        )
    )
}
