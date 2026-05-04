import Foundation

/// Typed S3 protocol error surfaced by BucketKit operations on a
/// non-2xx HTTP response.
///
/// The shape mirrors the fields S3 emits in its XML `<Error>`
/// document — `Code`, `Message`, `RequestId`, `Resource` — plus the
/// HTTP status that carried the document. Per PRD §8 this is one of
/// only two error types BucketKit throws across its public surface.
///
/// Decoded internally via ``decode(httpStatus:body:)``, which always
/// returns a value: a malformed or empty body falls back to a
/// sentinel ``code`` of `"Unknown"` so callers can still inspect
/// ``httpStatus`` without first having to handle a decoding failure.
public struct BucketServiceError: Error, Sendable, Hashable {
    /// S3 error code, e.g. `NoSuchBucket`, `AccessDenied`. Falls back
    /// to `"Unknown"` when the response body is empty or
    /// undecodable.
    public let code: String

    /// Human-readable message accompanying ``code``. When the body
    /// can't be decoded, this carries a short description of the
    /// HTTP status instead.
    public let message: String

    /// Opaque request identifier S3 returns; useful when contacting
    /// support. `nil` when the body is missing or didn't include
    /// `<RequestId>`.
    public let requestID: String?

    /// HTTP status code that carried the error document.
    public let httpStatus: Int

    /// Resource path the error refers to, when present in the body.
    public let resource: String?

    public init(
        code: String,
        message: String,
        requestID: String?,
        httpStatus: Int,
        resource: String?
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.httpStatus = httpStatus
        self.resource = resource
    }
}

extension BucketServiceError {
    /// Constructs a ``BucketServiceError`` from an HTTP status and
    /// response body, attempting to decode S3's XML `<Error>`
    /// document. Never throws: a missing, empty, or malformed body
    /// falls back to a sentinel value (``code`` `"Unknown"`,
    /// ``message`` containing the status code) so callers always get
    /// a populated error.
    ///
    /// HEAD responses in particular have no XML body even on errors,
    /// so the fallback path is the common case for `headObject`
    /// 404s. We deliberately don't try to infer a code (`NoSuchKey`
    /// vs `NoSuchBucket`) from the status alone — the status itself
    /// is preserved and that's enough for callers to disambiguate.
    internal static func decode(httpStatus: Int, body: Data) -> BucketServiceError {
        if body.isEmpty {
            return BucketServiceError(
                code: "Unknown",
                message: "HTTP \(httpStatus)",
                requestID: nil,
                httpStatus: httpStatus,
                resource: nil
            )
        }

        do {
            let decoded = try XMLDecoder.decode(S3ErrorResponse.self, from: body)
            return BucketServiceError(
                code: decoded.code,
                message: decoded.message,
                requestID: decoded.requestID,
                httpStatus: httpStatus,
                resource: decoded.resource
            )
        } catch {
            return BucketServiceError(
                code: "Unknown",
                message: "HTTP \(httpStatus)",
                requestID: nil,
                httpStatus: httpStatus,
                resource: nil
            )
        }
    }
}
