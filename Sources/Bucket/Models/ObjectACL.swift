import Foundation

/// S3 canned object ACL.
///
/// Maps to the legacy `x-amz-acl` header on object writes. Provider
/// support varies: AWS buckets created with `BucketOwnerEnforced`
/// reject `x-amz-acl` outright, R2 ignores it, Spaces honours a
/// subset. Callers should treat ACLs as best-effort and prefer
/// bucket policies for portable public-read.
///
/// Raw values are the literal strings S3 expects on the wire.
// TODO: full implementation in #0017/#0019/#0020.
public enum ObjectACL: String, Sendable, Hashable {
    case `private`
    case publicRead = "public-read"
    case publicReadWrite = "public-read-write"
    case authenticatedRead = "authenticated-read"
    case bucketOwnerRead = "bucket-owner-read"
    case bucketOwnerFullControl = "bucket-owner-full-control"
}
