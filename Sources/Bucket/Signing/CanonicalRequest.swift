import Foundation
import CryptoKit

/// Pure functions for building the SigV4 canonical request, the
/// derived string-to-sign, and the chained signing key.
///
/// This file deliberately has no dependency on `BucketConfiguration` or
/// any networking type — it is a stateless helper layer that
/// `SigV4Signer` (request signing, #0006) and the future presigner
/// (`PresignedURL`, #0018) both reuse.
///
/// The shapes follow the AWS SigV4 specification:
/// <https://docs.aws.amazon.com/IAM/UserGuide/reference_aws-signing.html>
enum CanonicalRequest {
    // MARK: - Constants

    /// SigV4 algorithm identifier carried in the `Authorization` header
    /// and the string-to-sign.
    static let algorithm = "AWS4-HMAC-SHA256"

    /// Sentinel value for `x-amz-content-sha256` when the body is not
    /// hashed in advance (used for streaming uploads).
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// SHA-256 hash of an empty body, hex-encoded. The S3 wire format
    /// uses this value for requests with no body (GET, DELETE, HEAD, …).
    static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Trailing literal in the SigV4 credential scope.
    static let requestType = "aws4_request"

    // MARK: - Inputs

    /// Minimal, transport-agnostic representation of an HTTP request to
    /// be signed. Headers are case-insensitive on the wire; this layer
    /// preserves them as-given and lowercases names only when building
    /// the canonical form.
    struct Input: Sendable {
        var method: String
        /// Path component as it will appear on the wire. The signer
        /// percent-encodes each segment per RFC 3986; `/` is preserved.
        /// An empty path is normalized to `/`.
        var path: String
        /// Pre-parsed query items in their original order. Re-sorted
        /// during canonicalization.
        var queryItems: [URLQueryItem]
        /// Headers to include in the signed request. `host` and any
        /// `x-amz-*` headers are required by S3; the signer ensures
        /// they are present before canonicalizing.
        var headers: [String: String]
        /// Either a hex SHA-256 of the body or `UNSIGNED-PAYLOAD`.
        var payloadHash: String
    }

    // MARK: - Canonical request

    /// Builds the canonical request string per SigV4 step 1.
    ///
    /// Returns the canonical request and the lowercased, semicolon-joined
    /// `signedHeaders` list — both are needed for the string-to-sign and
    /// the `Authorization` header.
    static func canonicalize(_ input: Input) -> (canonical: String, signedHeaders: String) {
        let canonicalURI = canonicalURI(path: input.path)
        let canonicalQuery = canonicalQueryString(input.queryItems)
        let (canonicalHeaders, signedHeaders) = canonicalHeaders(input.headers)

        let canonical = [
            input.method.uppercased(),
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            input.payloadHash,
        ].joined(separator: "\n")

        return (canonical, signedHeaders)
    }

    /// Canonical URI: each path segment percent-encoded per RFC 3986
    /// using the AWS unreserved character set. Empty paths become `/`.
    /// S3 (unlike most services) does **not** double-encode, so the
    /// caller is responsible for handing in an unencoded path.
    static func canonicalURI(path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { sigv4PercentEncode(String($0), encodeSlash: true) }
        return encoded.joined(separator: "/")
    }

    /// Canonical query string: sort by name (then value), percent-encode
    /// names and values per RFC 3986, join `name=value` pairs with `&`.
    /// Items with no value emit `name=`.
    static func canonicalQueryString(_ items: [URLQueryItem]) -> String {
        guard !items.isEmpty else { return "" }
        let encoded: [(String, String)] = items.map { item in
            let n = sigv4PercentEncode(item.name, encodeSlash: true)
            let v = sigv4PercentEncode(item.value ?? "", encodeSlash: true)
            return (n, v)
        }
        let sorted = encoded.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// Canonical headers block plus the lowercased semicolon-joined
    /// `signedHeaders` list. Header names are lowercased; values are
    /// trimmed of leading/trailing ASCII whitespace and have runs of
    /// internal whitespace collapsed to a single space (outside
    /// double-quoted sections — but S3 in practice does not send
    /// quoted header values, so we apply the simple form).
    static func canonicalHeaders(_ headers: [String: String]) -> (canonical: String, signed: String) {
        let normalized: [(String, String)] = headers.map { name, value in
            (name.lowercased(), trimAndCollapseWhitespace(value))
        }
        let sorted = normalized.sorted { $0.0 < $1.0 }
        let canonical = sorted.map { "\($0.0):\($0.1)\n" }.joined()
        let signed = sorted.map(\.0).joined(separator: ";")
        return (canonical, signed)
    }

    // MARK: - String to sign

    /// Builds the SigV4 string-to-sign (step 2).
    ///
    /// `amzDate` is the full ISO-8601 basic timestamp (`yyyyMMdd'T'HHmmss'Z'`)
    /// and `dateStamp` is the date-only form (`yyyyMMdd`). The signer
    /// produces both from a single `Date` so they always agree.
    static func stringToSign(
        amzDate: String,
        dateStamp: String,
        region: String,
        service: String,
        canonicalRequest: String
    ) -> (stringToSign: String, credentialScope: String) {
        let scope = "\(dateStamp)/\(region)/\(service)/\(requestType)"
        let hashed = sha256Hex(canonicalRequest)
        let sts = [algorithm, amzDate, scope, hashed].joined(separator: "\n")
        return (sts, scope)
    }

    // MARK: - Signing key derivation

    /// Derives the SigV4 signing key by chaining HMAC-SHA256 over the
    /// secret access key (prefixed with the literal `AWS4`), the date
    /// stamp, the region, the service, and the literal `aws4_request`.
    static func deriveSigningKey(
        secretAccessKey: String,
        dateStamp: String,
        region: String,
        service: String
    ) -> SymmetricKey {
        let kSecret = SymmetricKey(data: Data(("AWS4" + secretAccessKey).utf8))
        let kDate = hmac(SymmetricKey(data: dateStamp.data(using: .utf8) ?? Data()), with: kSecret)
        let kRegion = hmac(SymmetricKey(data: region.data(using: .utf8) ?? Data()), with: kDate)
        let kService = hmac(SymmetricKey(data: service.data(using: .utf8) ?? Data()), with: kRegion)
        let kSigning = hmac(SymmetricKey(data: requestType.data(using: .utf8) ?? Data()), with: kService)
        return kSigning
    }

    /// Final signature as lowercase hex.
    static func signature(stringToSign: String, signingKey: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: signingKey
        )
        return Data(mac).hexLowercase
    }

    // MARK: - Hashing helpers

    /// Hex-lowercase SHA-256 of a UTF-8 string.
    static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return Data(digest).hexLowercase
    }

    /// Hex-lowercase SHA-256 of arbitrary bytes.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Data(digest).hexLowercase
    }

    // MARK: - Internals

    /// HMAC-SHA256 of the `data` symmetric key's underlying bytes,
    /// using `key` as the MAC key. We pass the plaintext as a
    /// `SymmetricKey` for callsite clarity — internally we use its raw
    /// representation.
    private static func hmac(_ data: SymmetricKey, with key: SymmetricKey) -> SymmetricKey {
        let bytes = data.withUnsafeBytes { Data($0) }
        let mac = HMAC<SHA256>.authenticationCode(for: bytes, using: key)
        return SymmetricKey(data: Data(mac))
    }

    /// Trim ASCII spaces/tabs at both ends and collapse internal runs
    /// of spaces/tabs to a single space.
    private static func trimAndCollapseWhitespace(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var out = ""
        out.reserveCapacity(trimmed.count)
        var lastWasSpace = false
        for ch in trimmed {
            if ch == " " || ch == "\t" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }
}

// MARK: - Percent encoding

/// SigV4 / RFC 3986 percent-encoding.
///
/// Unreserved characters per RFC 3986 are
/// `A-Z` `a-z` `0-9` `-` `_` `.` `~`. Everything else is percent-encoded
/// as `%XX` with uppercase hex. When `encodeSlash` is `false`, the
/// forward slash is left as-is — this is used in callers that want to
/// preserve path separators.
@usableFromInline
func sigv4PercentEncode(_ s: String, encodeSlash: Bool) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    for byte in s.utf8 {
        if isUnreserved(byte) || (!encodeSlash && byte == 0x2F /* '/' */) {
            out.append(Character(UnicodeScalar(byte)))
        } else {
            out.append("%")
            out.append(hexUppercase[Int(byte >> 4)])
            out.append(hexUppercase[Int(byte & 0x0F)])
        }
    }
    return out
}

@inline(__always)
private func isUnreserved(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x41...0x5A, // A-Z
         0x61...0x7A, // a-z
         0x30...0x39, // 0-9
         0x2D,        // -
         0x2E,        // .
         0x5F,        // _
         0x7E:        // ~
        return true
    default:
        return false
    }
}

private let hexUppercase: [Character] = Array("0123456789ABCDEF")

// MARK: - Hex helpers

extension Data {
    /// Lowercase hex encoding without separators.
    @usableFromInline
    var hexLowercase: String {
        var out = ""
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(hexLowercaseTable[Int(byte >> 4)])
            out.append(hexLowercaseTable[Int(byte & 0x0F)])
        }
        return out
    }
}

private let hexLowercaseTable: [Character] = Array("0123456789abcdef")
