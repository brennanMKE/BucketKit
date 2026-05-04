import Foundation
import OSLog

/// Centralized `os.Logger` instances for BucketKit.
///
/// PRD §11 is the source of truth for the package's logging policy. The
/// canonical subsystem is `dev.brennanmke.bucket`; the canonical
/// categories are `signing`, `client`, `multipart`, `transport`, and
/// `xml`. Every `Logger` used by the package lives here so we have a
/// single place to enforce both the naming and the privacy rules.
///
/// **Privacy rules (do not violate):**
///
/// - Never log credentials, secret access keys, or session tokens —
///   not even at `.debug` and not even with `privacy: .private`.
/// - Never log full `Authorization` header values.
/// - Never log full presigned URLs (the query string carries the
///   credential, expiry, and signature). Logging method + bucket +
///   `keyLen` is the established privacy-safe fingerprint.
/// - Never log `uploadID` (the multipart `UploadId` is treated as
///   opaque per ``MultipartUpload``).
/// - Object keys, request URLs, and other request metadata that may
///   carry user-identifying paths should be marked
///   `privacy: .private` when interpolated, even at `.debug`. Public
///   diagnostic fields (HTTP status, attempt counters, signed-header
///   lists, S3 error codes, content-length, byte counts) are fine
///   `.public`.
///
/// **Default level:** `.info`. `.debug` is enabled per-category in
/// `DEBUG` builds via `OS_ACTIVITY_MODE` or
/// `defaults write <bundle> OSLogPreferences`. The package itself does
/// **not** gate its log statements behind `#if DEBUG`; gating is the
/// runtime's job.
internal enum BucketLog {
    /// Package-wide logging subsystem. Renamed only if/when the
    /// package is republished under a different bundle ID.
    static let subsystem = "dev.brennanmke.bucket"

    /// SigV4 canonical-request and signature work.
    static let signing = Logger(subsystem: subsystem, category: "signing")

    /// `BucketClient` operations: uploadData, downloadData, list,
    /// remove, headObject, bucket-level CRUD.
    static let client = Logger(subsystem: subsystem, category: "client")

    /// Multipart-upload lifecycle: initiate, upload-part, complete,
    /// abort.
    static let multipart = Logger(subsystem: subsystem, category: "multipart")

    /// HTTP transport — request dispatch, response status, retry
    /// decisions made inside ``RetryRunner``.
    static let transport = Logger(subsystem: subsystem, category: "transport")

    /// XML SAX parser and response decoding.
    static let xml = Logger(subsystem: subsystem, category: "xml")
}
