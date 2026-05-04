import Foundation

/// Metadata returned by ``BucketClient/headBucket(_:)``.
///
/// `HEAD /` against a bucket returns no body — every interesting
/// signal is in the response headers. The only field S3 (and
/// providers that mimic it) consistently surface is
/// `x-amz-bucket-region`, which reports the region the bucket
/// physically lives in. Additional fields can be added here without
/// breaking source compatibility.
public struct BucketMetadata: Sendable, Hashable {
    /// Region the bucket lives in, as reported by the
    /// `x-amz-bucket-region` response header. `nil` when the server
    /// omits the header (some non-AWS providers do not emit it).
    public let region: String?

    /// Memberwise initializer.
    public init(region: String?) {
        self.region = region
    }
}
