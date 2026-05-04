import Foundation

/// HTTP methods supported by BucketKit's S3 surface.
///
/// Currently used by ``GetURLOptions`` to pick the verb a presigned
/// URL is bound to. The raw value is the literal token sent on the
/// wire and embedded in the SigV4 canonical request — case matters,
/// so the values are uppercase.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    case get = "GET"
    case put = "PUT"
    case head = "HEAD"
    case delete = "DELETE"
}
