import Foundation

/// One bucket entry returned by
/// ``BucketClient/listBuckets()``.
///
/// Mirrors the `<Bucket>` child of S3's `ListAllMyBucketsResult`
/// document. The two fields S3 always emits — `Name` and
/// `CreationDate` — are surfaced verbatim:
///
/// - ``name`` — the bucket's globally unique name.
/// - ``creationDate`` — the timestamp the bucket was created on the
///   server, parsed from ISO 8601.
///
/// Owner identity is not surfaced here; callers who need the
/// `<Owner>` block should reach for the lower-level XML decoders.
public struct BucketInfo: Sendable, Hashable {
    /// Bucket name as reported by the service.
    public let name: String

    /// Server-reported creation timestamp.
    public let creationDate: Date

    /// Memberwise initializer. Public so tests and callers that build
    /// fixtures can construct values directly.
    public init(name: String, creationDate: Date) {
        self.name = name
        self.creationDate = creationDate
    }
}
