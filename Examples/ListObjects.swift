// Examples/ListObjects.swift
//
// Two ways to walk a bucket's contents:
//
// - `list(...)` returns one page at a time. Drive pagination yourself
//   by passing the previous response's `nextContinuationToken` back in.
// - `listAll(...)` returns an `AsyncSequence` that follows continuation
//   tokens transparently — each yielded value is a `BucketObject`.

import Foundation
import Bucket

/// Page-by-page listing using the explicit continuation-token loop.
/// Stops when the server reports a non-truncated page.
public func samplePagedList(
    client: BucketClient,
    bucket: String,
    prefix: String?
) async throws -> [BucketObject] {
    var collected: [BucketObject] = []
    var token: String? = nil

    repeat {
        var options = ListOptions(prefix: prefix, maxKeys: 1000)
        options.continuationToken = token

        let page = try await client.list(bucket: bucket, options: options)
        collected.append(contentsOf: page.items)
        token = page.isTruncated ? page.nextContinuationToken : nil
    } while token != nil

    return collected
}

/// Streaming form. Iterates every matching object across every page.
/// Common prefixes (the "folder" rollups produced by `delimiter`) are
/// not surfaced through this stream — use the page-by-page form when
/// you need them alongside the items.
public func sampleStreamingList(
    client: BucketClient,
    bucket: String,
    prefix: String?
) async throws {
    let stream = await client.listAll(
        bucket: bucket,
        options: ListOptions(prefix: prefix)
    )
    for try await object in stream {
        print("\(object.key)\t\(object.size) bytes")
    }
}

/// Folder-style listing using a `/` delimiter. Subfolders surface in
/// `commonPrefixes`; objects directly under the prefix surface in
/// `items`.
public func sampleFolderListing(
    client: BucketClient,
    bucket: String,
    folder: String
) async throws -> (items: [BucketObject], folders: [String]) {
    let result = try await client.list(
        bucket: bucket,
        options: ListOptions(prefix: folder, delimiter: "/")
    )
    return (result.items, result.commonPrefixes)
}
