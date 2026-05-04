import Foundation

extension ServerSideEncryption {
    /// Translates an SSE option into the `x-amz-server-side-encryption*`
    /// headers S3 expects on the request.
    ///
    /// Header bindings, per AWS S3 API:
    ///
    /// - ``aes256`` (SSE-S3): `x-amz-server-side-encryption: AES256`.
    /// - ``awsKMS(keyID:)`` (SSE-KMS):
    ///   `x-amz-server-side-encryption: aws:kms` plus optional
    ///   `x-amz-server-side-encryption-aws-kms-key-id` when a key
    ///   identifier is supplied (ARN, `alias/...`, or bare key id).
    /// - ``customer(key:keyMD5:)`` (SSE-C): three customer-key headers
    ///   carrying the base64-encoded key, the base64-encoded MD5
    ///   digest, and the fixed `AES256` algorithm.
    ///
    /// SSE-C requires the same headers on every subsequent
    /// `UploadPart` for a multipart upload — see ``MultipartUpload`` for
    /// how that re-send is handled.
    internal var headers: [String: String] {
        switch self {
        case .aes256:
            return ["x-amz-server-side-encryption": "AES256"]
        case .awsKMS(let keyID):
            var headers = ["x-amz-server-side-encryption": "aws:kms"]
            if let keyID, !keyID.isEmpty {
                headers["x-amz-server-side-encryption-aws-kms-key-id"] = keyID
            }
            return headers
        case .customer(let key, let keyMD5):
            return [
                "x-amz-server-side-encryption-customer-algorithm": "AES256",
                "x-amz-server-side-encryption-customer-key": key.base64EncodedString(),
                "x-amz-server-side-encryption-customer-key-md5": keyMD5.base64EncodedString(),
            ]
        }
    }

    /// Subset of ``headers`` that must be re-sent on each `UploadPart`
    /// of a multipart upload. Only SSE-C requires this — KMS and AES256
    /// are tied to the upload at `CreateMultipartUpload` time and
    /// inherited by every part.
    internal var uploadPartHeaders: [String: String] {
        switch self {
        case .customer:
            return headers
        case .aes256, .awsKMS:
            return [:]
        }
    }
}
