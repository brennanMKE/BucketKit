import Foundation

/// A single part successfully uploaded as part of a multipart upload.
///
/// Returned by ``MultipartUpload/uploadPart(_:partNumber:)`` (and the
/// `fileURL:` overload) and consumed by
/// ``MultipartUpload/complete()`` when assembling the
/// `CompleteMultipartUpload` request body.
///
/// The ``eTag`` is the per-part ETag returned by S3 in the `ETag`
/// response header on the underlying `UploadPart` request. Surrounding
/// quotes are stripped on this value; the quotes the
/// `CompleteMultipartUpload` body needs are re-added by the actor when
/// it serializes the request.
public struct UploadedPart: Sendable, Hashable {
    /// 1-based part number this entry refers to. S3 allows the range
    /// `1...10_000`.
    public let partNumber: Int

    /// ETag returned by S3 for this part, with surrounding quotes
    /// stripped.
    public let eTag: String

    /// Creates an `UploadedPart`. Callers do not normally build these
    /// directly; ``MultipartUpload/uploadPart(_:partNumber:)`` returns
    /// them.
    public init(partNumber: Int, eTag: String) {
        self.partNumber = partNumber
        self.eTag = eTag
    }
}
