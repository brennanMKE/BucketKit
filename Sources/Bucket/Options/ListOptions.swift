import Foundation

/// Options for ``BucketClient/list(bucket:path:options:)`` and
/// ``BucketClient/listAll(bucket:path:options:)``.
///
/// All fields default to nil/false so callers can pass `.init()` to
/// list the entire bucket using the server's default page size.
///
/// - ``prefix`` — restricts the listing to keys starting with this
///   string. Translates to a `?prefix=…` query parameter. When the
///   caller passes a ``BucketPath`` to `list` and ``prefix`` is `nil`,
///   the path's resolved key is used as the prefix.
/// - ``delimiter`` — when set, S3 rolls keys that share a prefix up to
///   the next delimiter into ``BucketListResult/commonPrefixes``
///   instead of returning each individual key. Typically `"/"` for
///   directory-style listings.
/// - ``maxKeys`` — page size hint. S3 caps this at 1000 even if a
///   larger value is supplied.
/// - ``continuationToken`` — token from a previous page's
///   ``BucketListResult/nextContinuationToken``. Lets a caller resume
///   listing where they left off without using ``listAll``.
/// - ``listAll`` — when `true`, ``BucketClient/list(bucket:path:options:)``
///   transparently follows continuation tokens and returns every
///   matching object in a single ``BucketListResult``. This is a
///   convenience for callers who want one aggregated result rather
///   than the page-at-a-time API or the streaming
///   ``BucketClient/listAll(bucket:path:options:)``. Be aware the
///   aggregated result is held entirely in memory; for very large
///   buckets prefer the streaming form.
public struct ListOptions: Sendable {
    /// Restrict the listing to keys starting with this string.
    public var prefix: String?

    /// Delimiter that rolls shared-prefix keys up into
    /// ``BucketListResult/commonPrefixes``. Typically `"/"`.
    public var delimiter: String?

    /// Page size hint. The server caps this (1000 on AWS S3).
    public var maxKeys: Int?

    /// Continuation token returned by a previous truncated page.
    public var continuationToken: String?

    /// When `true`, ``BucketClient/list(bucket:path:options:)``
    /// auto-paginates and returns all matching objects in one
    /// aggregated ``BucketListResult``.
    public var listAll: Bool

    /// Memberwise initializer. All parameters default to nil/false so
    /// callers can write `ListOptions()`.
    public init(
        prefix: String? = nil,
        delimiter: String? = nil,
        maxKeys: Int? = nil,
        continuationToken: String? = nil,
        listAll: Bool = false
    ) {
        self.prefix = prefix
        self.delimiter = delimiter
        self.maxKeys = maxKeys
        self.continuationToken = continuationToken
        self.listAll = listAll
    }
}
