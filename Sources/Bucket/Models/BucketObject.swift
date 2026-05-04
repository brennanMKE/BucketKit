import Foundation

/// One object reported by ``BucketClient/list(bucket:path:options:)`` or
/// streamed by ``BucketClient/listAll(bucket:path:options:)``.
///
/// Each value corresponds to a `<Contents>` entry in S3's
/// `ListObjectsV2` response. Fields are mapped from S3's wire format:
///
/// - ``key`` — the literal object key within the bucket.
/// - ``size`` — size of the stored payload in bytes.
/// - ``lastModified`` — server-reported modification time, parsed from
///   ISO 8601.
/// - ``eTag`` — the value S3 emits in `<ETag>`. Surrounding quotes
///   carried on the wire are preserved here so callers see the same
///   identifier S3 returns elsewhere.
/// - ``storageClass`` — typed storage class when the server emits one;
///   `nil` for providers that omit `<StorageClass>` or for values
///   outside ``StorageClass``'s known cases.
public struct BucketObject: Sendable, Hashable {
    /// Object key (full path within the bucket).
    public let key: String

    /// Object size in bytes.
    public let size: Int64

    /// Last modification timestamp as reported by the server.
    public let lastModified: Date

    /// ETag exactly as S3 emitted it (still surrounded by quotes on
    /// most providers).
    public let eTag: String

    /// Typed storage class when present and recognized; otherwise
    /// `nil`.
    public let storageClass: StorageClass?

    /// Memberwise initializer. Public so tests and callers that build
    /// fixtures can construct values directly.
    public init(
        key: String,
        size: Int64,
        lastModified: Date,
        eTag: String,
        storageClass: StorageClass?
    ) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.storageClass = storageClass
    }
}
