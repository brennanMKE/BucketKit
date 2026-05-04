// Examples/Multipart.swift
//
// Explicit `MultipartUpload` actor: initiate, upload parts, complete.
//
// **Auto-multipart is the default for `uploadFile`** above the 100 MiB
// threshold — that path also slices the file, parallelizes parts, and
// issues a best-effort `AbortMultipartUpload` on cancellation. Reach
// for the explicit actor only when you need fine control: streaming
// from a non-file source, custom part scheduling, or interleaving
// multipart with other work.
//
// Constraints S3 enforces:
// - Every part except the last must be at least 5 MiB.
// - At most 10,000 parts per upload.
// - `partNumber` is in `1...10_000` and is ordered server-side at
//   `complete()` regardless of upload order.

import Foundation
import Bucket

/// Drives an explicit multipart upload of `chunks` (already split by
/// the caller). Calls `abort()` on any failure as a safety net.
public func sampleExplicitMultipart(
    client: BucketClient,
    bucket: String,
    chunks: [Data]
) async throws -> UploadResult {
    let upload = try await client.multipartUpload(
        bucket: bucket,
        path: .fromString("examples/manual-multipart.bin"),
        options: UploadDataOptions(contentType: "application/octet-stream")
    )

    do {
        // Parts can be uploaded in any order, in parallel if you wish.
        // Here we drive them sequentially for clarity.
        for (index, chunk) in chunks.enumerated() {
            let partNumber = index + 1 // partNumber is 1-based.
            _ = try await upload.uploadPart(chunk, partNumber: partNumber)
        }
        return try await upload.complete()
    } catch {
        // Best effort cleanup so orphaned parts don't accumulate.
        try? await upload.abort()
        throw error
    }
}

/// Same shape but uploads parts in parallel via a `TaskGroup`. The
/// `MultipartUpload` actor serializes its mutable state, so concurrent
/// `uploadPart` calls are safe.
public func sampleParallelMultipart(
    client: BucketClient,
    bucket: String,
    chunks: [Data],
    concurrency: Int = 4
) async throws -> UploadResult {
    let upload = try await client.multipartUpload(
        bucket: bucket,
        path: .fromString("examples/parallel-multipart.bin")
    )

    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, chunk) in chunks.enumerated() {
                if index >= concurrency {
                    try await group.next() // Cap in-flight parts.
                }
                let partNumber = index + 1
                group.addTask {
                    _ = try await upload.uploadPart(chunk, partNumber: partNumber)
                }
            }
            try await group.waitForAll()
        }
        return try await upload.complete()
    } catch {
        try? await upload.abort()
        throw error
    }
}
