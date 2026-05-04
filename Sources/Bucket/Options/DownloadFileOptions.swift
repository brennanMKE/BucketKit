import Foundation

/// Options for ``BucketClient/downloadFile(bucket:path:local:options:)``.
///
/// Mirrors ``DownloadDataOptions`` field for field rather than wrapping
/// it: the file path differs only in *where* the bytes land, not in
/// what the wire request looks like. Duplicating the field list keeps
/// both sides documented next to their own types.
///
/// All fields default to nil; callers can pass `.init()` to fetch the
/// entire object with no preconditions.
public struct DownloadFileOptions: Sendable {
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
    /// callers can write `DownloadFileOptions()`.
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
