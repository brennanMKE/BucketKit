import Foundation

/// Successful outcome of an upload operation.
///
/// Returned as the ``BucketTransferTask/value`` of
/// ``BucketUploadDataTask`` and ``BucketUploadFileTask``. The
/// information here is everything S3 reports on a successful PUT or
/// `CompleteMultipartUpload`:
///
/// - ``key`` — the resolved object key (the literal value the
///   request was addressed to, after path resolution).
/// - ``eTag`` — S3's content identifier for the stored object. For
///   single-PUT uploads this is the MD5 of the payload; for
///   multipart it is a digest-of-digests with a `-N` part-count
///   suffix. Quotes from the wire response are stripped.
/// - ``versionID`` — present only when the bucket has versioning
///   enabled; `nil` otherwise.
public struct UploadResult: Sendable, Hashable {
    /// Object key the upload was written to.
    public let key: String

    /// ETag returned by S3 for the stored object, with surrounding
    /// quotes stripped.
    public let eTag: String

    /// Version ID if the bucket has versioning enabled, otherwise
    /// `nil`.
    public let versionID: String?

    /// Creates an upload result. Used by the upload operation code
    /// (#0011, #0012); callers do not construct these directly.
    public init(key: String, eTag: String, versionID: String? = nil) {
        self.key = key
        self.eTag = eTag
        self.versionID = versionID
    }
}
