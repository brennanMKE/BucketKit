import Foundation

/// Identifier for an object in an S3-compatible bucket.
///
/// A `BucketPath` resolves to a literal S3 object key at the moment an
/// operation runs. Modeled after Amplify's `StoragePath` so callers can
/// supply either a plain string today or, in the future, a richer
/// resolver (e.g. an identity-prefixed path) without changing call
/// sites.
///
/// For v1 the only built-in conformance is ``StringBucketPath``,
/// constructed via ``BucketPath/fromString(_:)``.
///
/// All conformances must be `Sendable` because paths are passed across
/// the `BucketClient` actor boundary.
public protocol BucketPath: Sendable {
    /// Returns the literal S3 object key this path resolves to.
    func resolve() -> String
}
