import Foundation

/// Options for ``BucketClient/remove(bucket:path:options:)``.
///
/// All fields default to nil so callers can pass `.init()` to delete
/// the current version of an object.
///
/// - ``versionID`` — when set, deletes a specific object version rather
///   than placing a delete marker on the current version. Translates
///   to a `?versionId={value}` query parameter on the wire. Versioning
///   must be enabled on the target bucket; against a non-versioned
///   bucket the parameter is ignored by the server.
public struct RemoveOptions: Sendable {
    /// Target a specific object version. Appended to the request URL
    /// as `?versionId={value}` and included in the SigV4 canonical
    /// query string.
    public var versionID: String?

    /// Memberwise initializer. All parameters default to nil so
    /// callers can write `RemoveOptions()`.
    public init(versionID: String? = nil) {
        self.versionID = versionID
    }
}
