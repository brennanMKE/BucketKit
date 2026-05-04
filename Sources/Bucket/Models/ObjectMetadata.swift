import Foundation

/// Server-reported metadata for a single object, returned from
/// ``BucketClient/headObject(bucket:path:)``.
///
/// Fields map directly to the HTTP response headers S3 emits on
/// `HEAD <key>`:
///
/// - ``size`` — `Content-Length`.
/// - ``eTag`` — `ETag` with surrounding double quotes stripped. For
///   single-part PUTs this is the MD5 of the body; for multipart
///   uploads it has the `-{partCount}` suffix and is **not** the MD5
///   of the whole object.
/// - ``lastModified`` — `Last-Modified`, parsed as RFC 7231 / RFC 1123.
///   Falls back to `Date.distantPast` if the header is missing or
///   unparseable.
/// - ``contentType`` — `Content-Type`, if present.
/// - ``cacheControl`` — `Cache-Control`, if present.
/// - ``metadata`` — user metadata. Every response header whose name
///   begins (case-insensitively) with `x-amz-meta-` is collected with
///   the prefix stripped and the remaining name lowercased; values
///   are kept verbatim.
/// - ``storageClass`` — `x-amz-storage-class`, parsed via
///   ``StorageClass``. Nil if absent or unrecognized; we deliberately
///   do not throw on unknown values so newer storage tiers degrade to
///   "unknown" instead of failing the call.
/// - ``versionID`` — `x-amz-version-id`. Non-nil only on versioned
///   buckets.
public struct ObjectMetadata: Sendable, Hashable {
    /// The key the object lives at. Echoes the path the caller
    /// resolved at the call site — S3 does not return the key in
    /// `HEAD` response headers.
    public let key: String

    /// Object size in bytes, parsed from the `Content-Length` header.
    public let size: Int64

    /// `ETag` with surrounding double quotes stripped.
    public let eTag: String

    /// `Last-Modified` parsed as RFC 7231 / RFC 1123. Falls back to
    /// `Date.distantPast` if the header is missing or unparseable.
    public let lastModified: Date

    /// `Content-Type` header value, if present.
    public let contentType: String?

    /// `Cache-Control` header value, if present.
    public let cacheControl: String?

    /// User metadata: keys are the lowercased remainder of any
    /// `x-amz-meta-*` response header, values are verbatim.
    public let metadata: [String: String]

    /// Parsed `x-amz-storage-class` header. Nil if the header is
    /// absent or its raw value does not match a known
    /// ``StorageClass`` case.
    public let storageClass: StorageClass?

    /// `x-amz-version-id`. Non-nil only on versioned buckets.
    public let versionID: String?

    /// Memberwise initializer.
    public init(
        key: String,
        size: Int64,
        eTag: String,
        lastModified: Date,
        contentType: String? = nil,
        cacheControl: String? = nil,
        metadata: [String: String] = [:],
        storageClass: StorageClass? = nil,
        versionID: String? = nil
    ) {
        self.key = key
        self.size = size
        self.eTag = eTag
        self.lastModified = lastModified
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.metadata = metadata
        self.storageClass = storageClass
        self.versionID = versionID
    }
}
