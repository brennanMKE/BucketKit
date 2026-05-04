import Foundation

/// Configuration for a `BucketClient`.
///
/// Carries the endpoint URL, SigV4 region, and credentials required to
/// talk to an S3-compatible service. Use one of the static factory
/// methods (`aws`, `r2`, `digitalOceanSpaces`, `custom`) for the common
/// provider shapes; the memberwise initializer remains public for
/// unusual setups.
public struct BucketConfiguration: Sendable {
    /// Service endpoint, e.g. `https://s3.us-east-1.amazonaws.com`.
    public var endpoint: URL
    /// Region used for SigV4 credential scope. Provider-specific values
    /// like `auto` (R2) and `us-east-1` (Spaces) are literals required
    /// by the signer, not geographic identifiers.
    public var region: String
    /// AWS-style access key ID.
    public var accessKeyID: String
    /// AWS-style secret access key.
    public var secretAccessKey: String
    /// Optional STS-style session token. When present the signer will
    /// add an `X-Amz-Security-Token` header to every request.
    public var sessionToken: String?
    /// Whether to address buckets with path-style URLs
    /// (`https://endpoint/bucket/key`) instead of the default
    /// virtual-hosted style (`https://bucket.endpoint/key`).
    public var usePathStyle: Bool
    /// Headers merged into every signed request the client emits.
    ///
    /// Operation-specific headers (Content-Type, x-amz-acl, the
    /// x-amz-server-side-encryption family, etc.) are layered **on
    /// top** of these — if a name appears in both, the operation's
    /// value wins. The merge happens before SigV4 signing, so the
    /// extra headers participate in the signature like any other
    /// header.
    ///
    /// This is the escape hatch for headers BucketKit does not model
    /// directly — e.g. `x-amz-bucket-key-enabled` to opt into S3
    /// Bucket Keys for SSE-KMS, or vendor-specific `x-amz-` extensions
    /// some S3-compatible services accept.
    public var extraHeaders: [String: String]

    /// Memberwise initializer. Prefer the provider-specific factories.
    public init(
        endpoint: URL,
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        usePathStyle: Bool,
        extraHeaders: [String: String] = [:]
    ) {
        self.endpoint = endpoint
        self.region = region
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.usePathStyle = usePathStyle
        self.extraHeaders = extraHeaders
    }

    // MARK: - Provider factories

    /// AWS S3 configuration.
    ///
    /// Endpoint shape: `https://s3.{region}.amazonaws.com`.
    /// Uses virtual-hosted addressing.
    public static func aws(
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        extraHeaders: [String: String] = [:]
    ) -> Self {
        let endpoint = URL(string: "https://s3.\(region).amazonaws.com")!
        return Self(
            endpoint: endpoint,
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            usePathStyle: false,
            extraHeaders: extraHeaders
        )
    }

    /// Cloudflare R2 configuration.
    ///
    /// Endpoint shape: `https://{accountID}.{infix}r2.cloudflarestorage.com`,
    /// where `infix` is `""`, `"eu."`, or `"fedramp."` depending on
    /// `jurisdiction`. Region is fixed to the literal `auto` per R2's
    /// SigV4 requirements. Uses virtual-hosted addressing.
    public static func r2(
        accountID: String,
        accessKeyID: String,
        secretAccessKey: String,
        jurisdiction: R2Jurisdiction = .default,
        extraHeaders: [String: String] = [:]
    ) -> Self {
        let infix = jurisdiction.hostnameInfix
        let endpoint = URL(string: "https://\(accountID).\(infix)r2.cloudflarestorage.com")!
        return Self(
            endpoint: endpoint,
            region: "auto",
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: nil,
            usePathStyle: false,
            extraHeaders: extraHeaders
        )
    }

    /// DigitalOcean Spaces configuration.
    ///
    /// Endpoint shape: `https://{region}.digitaloceanspaces.com`. The
    /// SigV4 region is fixed to the literal `us-east-1` regardless of
    /// the geographic region. Uses virtual-hosted addressing.
    public static func digitalOceanSpaces(
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        extraHeaders: [String: String] = [:]
    ) -> Self {
        let endpoint = URL(string: "https://\(region).digitaloceanspaces.com")!
        return Self(
            endpoint: endpoint,
            region: "us-east-1",
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: nil,
            usePathStyle: false,
            extraHeaders: extraHeaders
        )
    }

    /// Custom S3-compatible endpoint (e.g. MinIO, self-hosted gateway).
    ///
    /// The caller supplies the full endpoint URL and region. Defaults
    /// to path-style addressing because most self-hosted gateways do
    /// not implement virtual-hosted bucket subdomains.
    public static func custom(
        endpoint: URL,
        region: String,
        accessKeyID: String,
        secretAccessKey: String,
        usePathStyle: Bool = true,
        extraHeaders: [String: String] = [:]
    ) -> Self {
        Self(
            endpoint: endpoint,
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: nil,
            usePathStyle: usePathStyle,
            extraHeaders: extraHeaders
        )
    }
}
