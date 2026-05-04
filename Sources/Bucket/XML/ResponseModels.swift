import Foundation

// Internal `Codable, Sendable` value types modeling the S3 XML
// responses BucketKit needs to decode. Field names use Swift
// conventions; `CodingKeys` map to the PascalCase element names S3
// emits.
//
// These are deliberately kept internal — they are plumbing for the
// public client surface (#0015 / #0016 / #0017 / #0019), not part
// of the public API.

// MARK: - Error

/// Decoded `<Error>` document returned by S3 on non-2xx responses.
///
/// Translated to ``BucketServiceError`` at the public boundary
/// (#0015).
struct S3ErrorResponse: Codable, Sendable, Hashable {
    /// S3 error code, e.g. `NoSuchBucket`, `AccessDenied`.
    let code: String

    /// Human-readable message accompanying ``code``.
    let message: String

    /// Opaque request identifier S3 returns; useful for support.
    let requestID: String?

    /// Resource path the error refers to, when present.
    let resource: String?

    /// Additional host identifier S3/AWS includes for traceability.
    let hostID: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case message = "Message"
        case requestID = "RequestId"
        case resource = "Resource"
        case hostID = "HostId"
    }
}

// MARK: - List Objects v2

/// One object entry inside a `ListObjectsV2` response.
struct S3Object: Codable, Sendable, Hashable {
    /// Object key (full path within the bucket).
    let key: String

    /// Last modification timestamp.
    let lastModified: Date

    /// ETag exactly as S3 emitted it (still wrapped in quotes).
    /// Quote stripping is the responsibility of the caller layer
    /// that maps this to ``UploadResult`` / ``BucketObject``.
    let eTag: String

    /// Object size in bytes.
    let size: Int64

    /// Storage class identifier (`STANDARD`, `GLACIER`, …) when the
    /// server emits one; `nil` for providers that omit it.
    let storageClass: String?

    enum CodingKeys: String, CodingKey {
        case key = "Key"
        case lastModified = "LastModified"
        case eTag = "ETag"
        case size = "Size"
        case storageClass = "StorageClass"
    }
}

/// One `<CommonPrefixes>` entry — represents a "directory" rollup
/// when a delimiter is used in the listing request.
struct S3CommonPrefix: Codable, Sendable, Hashable {
    let prefix: String

    enum CodingKeys: String, CodingKey {
        case prefix = "Prefix"
    }
}

/// `ListBucketResult` document returned by `GET /?list-type=2`.
struct ListBucketResultV2: Codable, Sendable, Hashable {
    /// Bucket name the listing was performed against.
    let name: String

    /// Effective prefix filter, if the request supplied one.
    let prefix: String?

    /// Effective delimiter, if any.
    let delimiter: String?

    /// Page size requested.
    let maxKeys: Int

    /// `true` when more results exist beyond this page.
    let isTruncated: Bool

    /// Number of `<Contents>` entries actually returned.
    let keyCount: Int

    /// Token to feed back as `continuation-token` to fetch the next
    /// page. Only present when ``isTruncated`` is `true`.
    let nextContinuationToken: String?

    /// Object entries on this page.
    let contents: [S3Object]

    /// Common prefixes (directory rollups) on this page.
    let commonPrefixes: [S3CommonPrefix]

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case prefix = "Prefix"
        case delimiter = "Delimiter"
        case maxKeys = "MaxKeys"
        case isTruncated = "IsTruncated"
        case keyCount = "KeyCount"
        case nextContinuationToken = "NextContinuationToken"
        case contents = "Contents"
        case commonPrefixes = "CommonPrefixes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        delimiter = try c.decodeIfPresent(String.self, forKey: .delimiter)
        maxKeys = try c.decode(Int.self, forKey: .maxKeys)
        isTruncated = try c.decode(Bool.self, forKey: .isTruncated)
        keyCount = try c.decode(Int.self, forKey: .keyCount)
        nextContinuationToken = try c.decodeIfPresent(String.self, forKey: .nextContinuationToken)
        // Repeated `<Contents>` / `<CommonPrefixes>` siblings — the
        // decoder collects them into arrays automatically. Default
        // to empty when the elements are absent on small responses.
        contents = (try? c.decode([S3Object].self, forKey: .contents)) ?? []
        commonPrefixes = (try? c.decode([S3CommonPrefix].self, forKey: .commonPrefixes)) ?? []
    }
}

// MARK: - List Buckets

/// `<Owner>` block shared by listings that report ownership.
struct S3Owner: Codable, Sendable, Hashable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case displayName = "DisplayName"
    }
}

/// One bucket entry in `ListAllMyBucketsResult`.
struct S3BucketEntry: Codable, Sendable, Hashable {
    let name: String
    let creationDate: Date

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case creationDate = "CreationDate"
    }
}

/// `ListAllMyBucketsResult` document returned by `GET /` (service
/// endpoint).
struct ListAllMyBucketsResult: Codable, Sendable, Hashable {
    let owner: S3Owner
    let buckets: [S3BucketEntry]

    enum CodingKeys: String, CodingKey {
        case owner = "Owner"
        case buckets = "Buckets"
    }

    enum BucketsCodingKeys: String, CodingKey {
        case bucket = "Bucket"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(S3Owner.self, forKey: .owner)
        // S3 wraps bucket entries in a `<Buckets>` element that
        // contains repeated `<Bucket>` children, so we have to step
        // through the wrapper.
        let bucketsContainer = try c.nestedContainer(keyedBy: BucketsCodingKeys.self, forKey: .buckets)
        buckets = (try? bucketsContainer.decode([S3BucketEntry].self, forKey: .bucket)) ?? []
    }
}

// MARK: - Multipart

/// Response body of `POST /<key>?uploads` (`InitiateMultipartUpload`).
struct InitiateMultipartUploadResult: Codable, Sendable, Hashable {
    let bucket: String
    let key: String
    let uploadID: String

    enum CodingKeys: String, CodingKey {
        case bucket = "Bucket"
        case key = "Key"
        case uploadID = "UploadId"
    }
}

/// Response body of `POST /<key>?uploadId=…` (`CompleteMultipartUpload`).
struct CompleteMultipartUploadResult: Codable, Sendable, Hashable {
    let location: String
    let bucket: String
    let key: String
    let eTag: String
    let versionID: String?

    enum CodingKeys: String, CodingKey {
        case location = "Location"
        case bucket = "Bucket"
        case key = "Key"
        case eTag = "ETag"
        case versionID = "VersionId"
    }
}

// MARK: - Copy

/// Response body of `PUT /<key>` with `x-amz-copy-source`
/// (`CopyObject`).
struct CopyObjectResult: Codable, Sendable, Hashable {
    let eTag: String
    let lastModified: Date

    enum CodingKeys: String, CodingKey {
        case eTag = "ETag"
        case lastModified = "LastModified"
    }
}
