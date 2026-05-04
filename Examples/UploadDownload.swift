// Examples/UploadDownload.swift
//
// Upload and download — both `Data` and file forms — with optional
// progress consumption. Each operation returns a `Sendable` task value
// you can either await for the final result or iterate for byte-count
// snapshots.
//
// `uploadFile` automatically switches to multipart with parallel parts
// for files at or above 100 MiB; see `Multipart.swift` for the
// explicit-control path.

import Foundation
import Bucket

/// Uploads a small `Data` payload to `bucket/key`. Demonstrates progress
/// consumption — for simple cases, `await task.value` is enough.
public func sampleUploadData(client: BucketClient, bucket: String) async throws -> UploadResult {
    let body = Data("hello, bucket".utf8)
    let task = await client.uploadData(
        bucket: bucket,
        path: .fromString("examples/hello.txt"),
        data: body,
        options: UploadDataOptions(contentType: "text/plain")
    )

    // Optional: observe progress. The stream finishes when the
    // operation completes or fails.
    Task {
        for await event in task.progress {
            print("uploadData: \(event.bytesTransferred)/\(event.totalBytes ?? -1)")
        }
    }

    return try await task.value
}

/// Streams a local file to `bucket/key`. For files >= 100 MiB this
/// transparently switches to S3 multipart with parallel parts and a
/// best-effort `AbortMultipartUpload` on cancellation.
public func sampleUploadFile(client: BucketClient, bucket: String, local: URL) async throws -> UploadResult {
    let task = await client.uploadFile(
        bucket: bucket,
        path: .fromString("examples/upload.bin"),
        local: local,
        options: UploadFileOptions(contentType: "application/octet-stream")
    )
    return try await task.value
}

/// Downloads an object's bytes into memory. Returns the response body
/// on success.
public func sampleDownloadData(client: BucketClient, bucket: String) async throws -> Data {
    let task = await client.downloadData(
        bucket: bucket,
        path: .fromString("examples/hello.txt")
    )
    return try await task.value
}

/// Downloads an object to a local file URL, streaming through the
/// transport so large objects don't buffer in memory. On success, the
/// task's `value` resolves to the `local` URL the caller supplied.
public func sampleDownloadFile(client: BucketClient, bucket: String, local: URL) async throws -> URL {
    let task = await client.downloadFile(
        bucket: bucket,
        path: .fromString("examples/upload.bin"),
        local: local
    )
    return try await task.value
}
