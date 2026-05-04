import Foundation

/// Options for ``BucketClient/uploadData(bucket:path:data:options:)``.
///
/// All fields default to nil/empty so callers can simply pass
/// `.init()` and rely on the provider's defaults. Each option maps to
/// a single S3 header (or family of headers) on the underlying `PUT`:
///
/// - ``contentType`` — `Content-Type`, defaults to
///   `application/octet-stream` when not provided.
/// - ``cacheControl`` — `Cache-Control`.
/// - ``metadata`` — translated into `x-amz-meta-*` headers (keys
///   lowercased on the wire per S3 convention).
/// - ``acl`` — `x-amz-acl`. See ``ObjectACL`` for portability caveats.
/// - ``storageClass`` — `x-amz-storage-class`.
/// - ``serverSideEncryption`` — `x-amz-server-side-encryption*`
///   family. Header translation is wired in #0020.
/// - ``ifNoneMatch`` — `If-None-Match`. Pass `"*"` for create-only
///   writes (the upload fails with `PreconditionFailed` if the key
///   already exists).
/// - ``partSize`` / ``concurrency`` — hints consumed by the multipart
///   path landing in #0019. Ignored by the single-part PUT used here.
public struct UploadDataOptions: Sendable {
    /// Object MIME type. Sent as `Content-Type`. Defaults to
    /// `application/octet-stream` when nil.
    public var contentType: String?

    /// `Cache-Control` header value, if any.
    public var cacheControl: String?

    /// User metadata pairs. Each entry becomes an `x-amz-meta-{key}`
    /// header on the upload; keys are lowercased before being sent.
    public var metadata: [String: String]

    /// Canned object ACL. Best-effort across providers — see
    /// ``ObjectACL``.
    public var acl: ObjectACL?

    /// Storage class to apply to the new object.
    public var storageClass: StorageClass?

    /// Server-side encryption mode. Header translation lands in
    /// #0020.
    public var serverSideEncryption: ServerSideEncryption?

    /// `If-None-Match` precondition. `"*"` enables create-only writes.
    public var ifNoneMatch: String?

    /// Hint for the multipart threshold/part size (#0019). Ignored on
    /// the single-part PUT path used today.
    public var partSize: Int?

    /// Maximum number of parts to upload in parallel during multipart
    /// (#0019). Ignored today.
    public var concurrency: Int?

    /// Memberwise initializer. All parameters default to nil/empty so
    /// callers can write `UploadDataOptions()`.
    public init(
        contentType: String? = nil,
        cacheControl: String? = nil,
        metadata: [String: String] = [:],
        acl: ObjectACL? = nil,
        storageClass: StorageClass? = nil,
        serverSideEncryption: ServerSideEncryption? = nil,
        ifNoneMatch: String? = nil,
        partSize: Int? = nil,
        concurrency: Int? = nil
    ) {
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.metadata = metadata
        self.acl = acl
        self.storageClass = storageClass
        self.serverSideEncryption = serverSideEncryption
        self.ifNoneMatch = ifNoneMatch
        self.partSize = partSize
        self.concurrency = concurrency
    }
}
