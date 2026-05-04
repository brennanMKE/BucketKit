import Foundation

/// Options for ``BucketClient/downloadData(bucket:path:options:)``.
///
/// All fields default to nil so callers can pass `.init()` and pull
/// the entire object with no preconditions. Each option maps to a
/// single HTTP request header on the underlying `GET`:
///
/// - ``range`` — `Range` header. Swift `Range` is half-open (lower
///   inclusive, upper exclusive) while HTTP byte ranges are inclusive
///   on both ends, so `0..<1024` becomes `bytes=0-1023` on the wire.
/// - ``ifNoneMatch`` — `If-None-Match`. The download fails (placeholder
///   error today; `BucketServiceError` after #0015) if the object's
///   current ETag matches, allowing callers to skip transferring bytes
///   they already have.
/// - ``ifMatch`` — `If-Match`. The download fails if the object's
///   current ETag does **not** match, useful for guarding against
///   concurrent overwrites.
public struct DownloadDataOptions: Sendable {
    /// Half-open byte range to request. Translated to an inclusive
    /// `Range: bytes={lower}-{upper - 1}` header on the wire.
    public var range: Range<Int64>?

    /// `If-None-Match` precondition. S3 returns `304 Not Modified`
    /// when the object's current ETag matches.
    public var ifNoneMatch: String?

    /// `If-Match` precondition. S3 returns `412 Precondition Failed`
    /// when the object's current ETag does not match.
    public var ifMatch: String?

    /// Memberwise initializer. All parameters default to nil so
    /// callers can write `DownloadDataOptions()`.
    public init(
        range: Range<Int64>? = nil,
        ifNoneMatch: String? = nil,
        ifMatch: String? = nil
    ) {
        self.range = range
        self.ifNoneMatch = ifNoneMatch
        self.ifMatch = ifMatch
    }
}
