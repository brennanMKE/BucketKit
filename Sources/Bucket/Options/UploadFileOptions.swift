import Foundation

/// Options for ``BucketClient/uploadFile(bucket:path:local:options:)``.
///
/// Mirrors ``UploadDataOptions`` field for field rather than wrapping
/// it: file uploads need to carry the same metadata, content type,
/// ACL, etc. as in-memory uploads, and duplicating the field list
/// keeps both sides documented next to their own types.
///
/// All fields default to nil/empty; callers can pass `.init()` and
/// rely on provider defaults plus `application/octet-stream`.
public struct UploadFileOptions: Sendable {
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
    /// callers can write `UploadFileOptions()`.
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
