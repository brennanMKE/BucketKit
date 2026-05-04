import Foundation
import Testing
@testable import Bucket

/// Conformance tests against the official AWS SigV4 test suite.
///
/// All vectors share the documented credentials, region, service, and
/// signing instant from the public `aws4_testsuite`:
///
/// - Access key: `AKIDEXAMPLE`
/// - Secret:     `wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`
/// - Region:     `us-east-1`
/// - Service:    `service`   (NOT `s3`)
/// - Date:       `20150830T123600Z`
///
/// Each vector asserts four stages of the algorithm independently —
/// canonical request, string-to-sign, raw hex signature, and the full
/// `Authorization` header — so a regression points at the failing
/// stage rather than just "signature mismatch".
///
/// We exercise the lower-level `CanonicalRequest` helpers directly:
/// they take the service name explicitly and operate on the exact
/// header set the AWS test vectors specify. `SigV4Signer` itself layers
/// S3-specific behaviour on top (always injecting
/// `x-amz-content-sha256`), which the public AWS `service` test
/// vectors deliberately do not include — so going through the lower
/// layer is the correct way to validate the algorithm against this
/// suite. A separate `signerEmitsExpectedAuthorizationForS3Style`
/// vector pins `SigV4Signer.sign(_:)`'s end-to-end output for an
/// S3-style request that does include the content-sha256 header.
@Suite("AWS SigV4 test vectors")
struct SigV4VectorTests {

    // MARK: - Shared constants

    static let accessKeyID = "AKIDEXAMPLE"
    static let secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    static let region = "us-east-1"
    static let service = "service"
    static let amzDate = "20150830T123600Z"
    static let dateStamp = "20150830"
    static let credentialScope = "20150830/us-east-1/service/aws4_request"

    /// Fixed signing instant matching `amzDate` / `dateStamp`.
    /// 2015-08-30 12:36:00 UTC.
    static let fixedDate: Date = {
        var components = DateComponents()
        components.year = 2015
        components.month = 8
        components.day = 30
        components.hour = 12
        components.minute = 36
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: components)!
    }()

    /// Headers shared by the vanilla GET / POST vectors.
    static let vanillaHeaders: [String: String] = [
        "Host": "example.amazonaws.com",
        "X-Amz-Date": amzDate,
    ]

    // MARK: - get-vanilla

    @Test("get-vanilla")
    func getVanilla() throws {
        // Canonical request per the AWS test suite.
        let expectedCanonical = """
        GET
        /

        host:example.amazonaws.com
        x-amz-date:20150830T123600Z

        host;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """

        let expectedSTS = """
        AWS4-HMAC-SHA256
        20150830T123600Z
        20150830/us-east-1/service/aws4_request
        \(CanonicalRequest.sha256Hex(expectedCanonical))
        """

        let expectedSignature =
            "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"

        let expectedAuthorization =
            "AWS4-HMAC-SHA256 " +
            "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
            "SignedHeaders=host;x-amz-date, " +
            "Signature=\(expectedSignature)"

        try assertVector(
            method: "GET",
            url: URL(string: "https://example.amazonaws.com/")!,
            headers: Self.vanillaHeaders,
            payloadHash: CanonicalRequest.emptyPayloadHash,
            expectedCanonical: expectedCanonical,
            expectedSTS: expectedSTS,
            expectedSignature: expectedSignature,
            expectedAuthorization: expectedAuthorization
        )
    }

    // MARK: - get-vanilla-query

    @Test("get-vanilla-query")
    func getVanillaQuery() throws {
        let expectedCanonical = """
        GET
        /
        Param1=value1
        host:example.amazonaws.com
        x-amz-date:20150830T123600Z

        host;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """

        let expectedSTS = """
        AWS4-HMAC-SHA256
        20150830T123600Z
        20150830/us-east-1/service/aws4_request
        \(CanonicalRequest.sha256Hex(expectedCanonical))
        """

        // Signature is fully determined once the canonical request and
        // string-to-sign above match the AWS spec — those assertions
        // run first and would fail loudly if anything were off.
        let expectedSignature =
            "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb"

        let expectedAuthorization =
            "AWS4-HMAC-SHA256 " +
            "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
            "SignedHeaders=host;x-amz-date, " +
            "Signature=\(expectedSignature)"

        try assertVector(
            method: "GET",
            url: URL(string: "https://example.amazonaws.com/?Param1=value1")!,
            headers: Self.vanillaHeaders,
            payloadHash: CanonicalRequest.emptyPayloadHash,
            expectedCanonical: expectedCanonical,
            expectedSTS: expectedSTS,
            expectedSignature: expectedSignature,
            expectedAuthorization: expectedAuthorization
        )
    }

    // MARK: - post-vanilla

    @Test("post-vanilla")
    func postVanilla() throws {
        let expectedCanonical = """
        POST
        /

        host:example.amazonaws.com
        x-amz-date:20150830T123600Z

        host;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """

        let expectedSTS = """
        AWS4-HMAC-SHA256
        20150830T123600Z
        20150830/us-east-1/service/aws4_request
        \(CanonicalRequest.sha256Hex(expectedCanonical))
        """

        let expectedSignature =
            "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"

        let expectedAuthorization =
            "AWS4-HMAC-SHA256 " +
            "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
            "SignedHeaders=host;x-amz-date, " +
            "Signature=\(expectedSignature)"

        try assertVector(
            method: "POST",
            url: URL(string: "https://example.amazonaws.com/")!,
            headers: Self.vanillaHeaders,
            payloadHash: CanonicalRequest.emptyPayloadHash,
            expectedCanonical: expectedCanonical,
            expectedSTS: expectedSTS,
            expectedSignature: expectedSignature,
            expectedAuthorization: expectedAuthorization
        )
    }

    // MARK: - post-vanilla-query

    @Test("post-vanilla-query")
    func postVanillaQuery() throws {
        let expectedCanonical = """
        POST
        /
        Param1=value1
        host:example.amazonaws.com
        x-amz-date:20150830T123600Z

        host;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """

        let expectedSTS = """
        AWS4-HMAC-SHA256
        20150830T123600Z
        20150830/us-east-1/service/aws4_request
        \(CanonicalRequest.sha256Hex(expectedCanonical))
        """

        let expectedSignature =
            "28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11"

        let expectedAuthorization =
            "AWS4-HMAC-SHA256 " +
            "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
            "SignedHeaders=host;x-amz-date, " +
            "Signature=\(expectedSignature)"

        try assertVector(
            method: "POST",
            url: URL(string: "https://example.amazonaws.com/?Param1=value1")!,
            headers: Self.vanillaHeaders,
            payloadHash: CanonicalRequest.emptyPayloadHash,
            expectedCanonical: expectedCanonical,
            expectedSTS: expectedSTS,
            expectedSignature: expectedSignature,
            expectedAuthorization: expectedAuthorization
        )
    }

    // MARK: - Shared assertion helper

    /// Drives the lower-level `CanonicalRequest` helpers against a
    /// single vector and asserts each pipeline stage independently:
    /// canonical request, string-to-sign, raw hex signature, and the
    /// reassembled `Authorization` header. The full `SigV4Signer`
    /// itself is exercised separately by `signerEmitsExpectedAuthorizationForS3Style`
    /// because the AWS `service` test vectors do not carry an
    /// `x-amz-content-sha256` header (which S3 always requires and the
    /// signer therefore always injects).
    private func assertVector(
        method: String,
        url: URL,
        headers: [String: String],
        payloadHash: String,
        expectedCanonical: String,
        expectedSTS: String,
        expectedSignature: String,
        expectedAuthorization: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        // Build the canonical-request input the same way the signer does:
        // lowercased header names, and an empty path normalized to `/`.
        let path = url.path.isEmpty ? "/" : url.path
        let queryItems: [URLQueryItem] = {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return []
            }
            return comps.queryItems ?? []
        }()

        var lowercased: [String: String] = [:]
        for (name, value) in headers {
            lowercased[name.lowercased()] = value
        }

        let canonicalInput = CanonicalRequest.Input(
            method: method,
            path: path,
            queryItems: queryItems,
            headers: lowercased,
            payloadHash: payloadHash
        )

        let (canonical, signedHeaders) = CanonicalRequest.canonicalize(canonicalInput)
        #expect(canonical == expectedCanonical, sourceLocation: sourceLocation)

        let (sts, scope) = CanonicalRequest.stringToSign(
            amzDate: Self.amzDate,
            dateStamp: Self.dateStamp,
            region: Self.region,
            service: Self.service,
            canonicalRequest: canonical
        )
        #expect(sts == expectedSTS, sourceLocation: sourceLocation)
        #expect(scope == Self.credentialScope, sourceLocation: sourceLocation)

        let signingKey = CanonicalRequest.deriveSigningKey(
            secretAccessKey: Self.secretAccessKey,
            dateStamp: Self.dateStamp,
            region: Self.region,
            service: Self.service
        )
        let signature = CanonicalRequest.signature(
            stringToSign: sts,
            signingKey: signingKey
        )
        #expect(signature == expectedSignature, sourceLocation: sourceLocation)

        // Reassemble the Authorization header from the components we
        // just verified — proves nothing more than string concat at
        // this point, but pins the wire format so a regression in the
        // header-shape contract is caught here too.
        let credential = "\(Self.accessKeyID)/\(scope)"
        let authorization =
            "\(CanonicalRequest.algorithm) " +
            "Credential=\(credential), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"
        #expect(authorization == expectedAuthorization, sourceLocation: sourceLocation)
    }

    // MARK: - SigV4Signer end-to-end (S3-style)

    /// Pin the `SigV4Signer.sign(_:)` end-to-end output for an
    /// S3-style request — i.e. one where `x-amz-content-sha256` is
    /// part of the signed headers (S3 requires it; the signer always
    /// injects it). We construct an expected canonical request /
    /// string-to-sign / signature triple by running the same lower
    /// layer, then assert the signer emits the matching Authorization.
    @Test("SigV4Signer emits Authorization header for S3-style request")
    func signerEmitsExpectedAuthorizationForS3Style() throws {
        let url = URL(string: "https://example.amazonaws.com/")!
        let payloadHash = CanonicalRequest.emptyPayloadHash

        let expectedCanonical = """
        GET
        /

        host:example.amazonaws.com
        x-amz-content-sha256:\(payloadHash)
        x-amz-date:20150830T123600Z

        host;x-amz-content-sha256;x-amz-date
        \(payloadHash)
        """

        let expectedSTS = """
        AWS4-HMAC-SHA256
        20150830T123600Z
        20150830/us-east-1/service/aws4_request
        \(CanonicalRequest.sha256Hex(expectedCanonical))
        """

        let signingKey = CanonicalRequest.deriveSigningKey(
            secretAccessKey: Self.secretAccessKey,
            dateStamp: Self.dateStamp,
            region: Self.region,
            service: Self.service
        )
        let expectedSignature = CanonicalRequest.signature(
            stringToSign: expectedSTS,
            signingKey: signingKey
        )

        let expectedAuthorization =
            "AWS4-HMAC-SHA256 " +
            "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
            "SignedHeaders=host;x-amz-content-sha256;x-amz-date, " +
            "Signature=\(expectedSignature)"

        let signer = SigV4Signer(
            credentials: SigV4Signer.Credentials(
                accessKeyID: Self.accessKeyID,
                secretAccessKey: Self.secretAccessKey
            ),
            region: Self.region,
            service: Self.service,
            clock: { Self.fixedDate }
        )

        let signed = signer.sign(
            SigV4Signer.Request(
                method: "GET",
                url: url,
                headers: [:],
                payloadHash: payloadHash
            )
        )

        #expect(signed.signedHeaderList == "host;x-amz-content-sha256;x-amz-date")
        #expect(signed.credentialScope == Self.credentialScope)
        #expect(signed.headers["Authorization"] == expectedAuthorization)
        #expect(signed.headers["host"] == "example.amazonaws.com")
        #expect(signed.headers["x-amz-date"] == Self.amzDate)
        #expect(signed.headers["x-amz-content-sha256"] == payloadHash)
    }
}
