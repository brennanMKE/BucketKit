import Foundation

/// One page of results from
/// ``BucketClient/list(bucket:path:options:)``.
///
/// Corresponds to a single `ListObjectsV2` response document. When
/// ``isTruncated`` is `true`, more pages exist on the server and the
/// caller can resume by passing ``nextContinuationToken`` back in
/// through ``ListOptions/continuationToken`` — or by switching to
/// ``BucketClient/listAll(bucket:path:options:)`` which performs the
/// pagination automatically.
public struct BucketListResult: Sendable {
    /// Object entries on this page, in the order S3 returned them.
    public let items: [BucketObject]

    /// Common-prefix rollups produced when the request supplied a
    /// delimiter. Each entry is the literal prefix string the server
    /// emitted in `<CommonPrefixes><Prefix>…</Prefix></CommonPrefixes>`.
    public let commonPrefixes: [String]

    /// `true` when more results exist beyond this page on the server.
    public let isTruncated: Bool

    /// Token to feed back as ``ListOptions/continuationToken`` to fetch
    /// the next page. `nil` when ``isTruncated`` is `false` (or when
    /// the server omitted the token despite truncation, which would
    /// indicate a non-conformant provider).
    public let nextContinuationToken: String?

    /// Memberwise initializer. Public so tests and callers that build
    /// fixtures can construct values directly.
    public init(
        items: [BucketObject],
        commonPrefixes: [String],
        isTruncated: Bool,
        nextContinuationToken: String?
    ) {
        self.items = items
        self.commonPrefixes = commonPrefixes
        self.isTruncated = isTruncated
        self.nextContinuationToken = nextContinuationToken
    }
}
