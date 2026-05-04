import Foundation

/// A ``BucketPath`` whose resolved key is a literal string.
///
/// This is the default conformance for the v1 surface. Construct one
/// directly with ``init(_:)`` or, more commonly, through the
/// ``BucketPath/fromString(_:)`` static factory so call sites can lean
/// on the `Self == StringBucketPath` constraint:
///
/// ```swift
/// try await client.remove(bucket: "my-bucket", path: .fromString("avatars/me.png"))
/// ```
public struct StringBucketPath: BucketPath {
    /// The literal object key this path resolves to.
    public let value: String

    /// Wraps a literal object key.
    public init(_ value: String) {
        self.value = value
    }

    public func resolve() -> String { value }
}

public extension BucketPath where Self == StringBucketPath {
    /// Builds a ``StringBucketPath`` from a literal object key.
    ///
    /// Lets callers write `path: .fromString("foo/bar")` instead of
    /// constructing the value type explicitly.
    static func fromString(_ s: String) -> Self { StringBucketPath(s) }
}
