import Foundation

/// Server-side encryption mode for an upload.
///
/// Mirrors the three SSE flavors S3 supports:
///
/// - ``aes256`` — SSE-S3, server-managed key.
/// - ``awsKMS(keyID:)`` — SSE-KMS, optionally pinning a specific KMS
///   key. AWS only; R2/Spaces/B2 do not implement KMS.
/// - ``customer(key:keyMD5:)`` — SSE-C, caller supplies the encryption
///   key on every request. The key is never stored server-side; lose
///   it and the object is unrecoverable.
///
/// Header translation into `x-amz-server-side-encryption*` headers is
/// handled by the upload pipeline.
// TODO: full implementation in #0017/#0019/#0020.
public enum ServerSideEncryption: Sendable {
    /// SSE-S3 with `AES256`.
    case aes256
    /// SSE-KMS, optionally pinned to a specific KMS key.
    case awsKMS(keyID: String?)
    /// SSE-C: caller-provided key plus its MD5 digest.
    case customer(key: Data, keyMD5: Data)
}
