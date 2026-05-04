# Building an S3-Compatible Swift Package

A reference for implementing a Swift package that talks to AWS S3, Cloudflare R2, and DigitalOcean Spaces using the standard S3 REST API.

---

## 1. Authentication: there is no "access token"

A common misconception worth clearing up first: S3-compatible services **do not use bearer tokens** the way OAuth APIs do. There is no `/auth` endpoint, no token-refresh flow, no `Authorization: Bearer xxx` header.

Instead, every request is **individually signed** using:

- **Access Key ID** — public-ish identifier (think: username)
- **Secret Access Key** — private (think: password, never sent over the wire)

The signing algorithm is **AWS Signature Version 4** (SigV4). The signature goes into the `Authorization` header on each request and is derived from the request itself plus the secret key, so the secret never leaves the client. This is the same scheme AWS, Cloudflare R2, and DigitalOcean Spaces all use.

Temporary credentials exist (AWS STS, R2 scoped tokens, etc.) — they produce the same Access Key ID + Secret Access Key pair, sometimes with an additional `X-Amz-Security-Token` header. Your package should accept that optional third value to support them.

---

## 2. Service endpoint configuration

Every provider exposes the same S3 REST surface but at a different hostname. Your package should accept a configurable endpoint and a region.

### AWS S3

| Field | Value |
|---|---|
| Endpoint | `https://s3.{region}.amazonaws.com` |
| Region | Real region, e.g. `us-east-1`, `eu-west-2` |
| URL style | Virtual-hosted preferred: `https://{bucket}.s3.{region}.amazonaws.com` |

### Cloudflare R2

| Field | Value |
|---|---|
| Endpoint | `https://{ACCOUNT_ID}.r2.cloudflarestorage.com` |
| Region | `auto` (also accepts `us-east-1` for SDK compatibility) |
| URL style | Both work; virtual-hosted: `https://{bucket}.{ACCOUNT_ID}.r2.cloudflarestorage.com` |
| Jurisdiction variants | `https://{ACCOUNT_ID}.eu.r2.cloudflarestorage.com`, `https://{ACCOUNT_ID}.fedramp.r2.cloudflarestorage.com` |

`ACCOUNT_ID` is your Cloudflare account ID (visible in the dashboard). API tokens are generated under R2 → Manage API Tokens, which yields an Access Key ID and Secret Access Key usable with the standard S3 API.

### DigitalOcean Spaces

| Field | Value |
|---|---|
| Endpoint | `https://{region}.digitaloceanspaces.com` |
| Endpoint region | DO datacenter, e.g. `nyc3`, `sfo3`, `fra1`, `sgp1`, `ams3`, `syd1`, `tor1`, `blr1` |
| SigV4 region | `us-east-1` (for SDK compatibility — counterintuitive but required) |
| URL style | Virtual-hosted: `https://{bucket}.{region}.digitaloceanspaces.com` |

Spaces credentials are created in the DO Control Panel → Spaces Object Storage → Access Keys. They cannot currently be created via the DO API.

### Suggested Swift configuration type

```swift
public struct S3Configuration: Sendable {
    public let endpoint: URL              // e.g. https://s3.us-east-1.amazonaws.com
    public let region: String             // SigV4 region used in signing
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?      // optional, for temporary creds
    public let usePathStyle: Bool         // false = virtual-hosted (default)

    public static func aws(region: String, accessKeyID: String, secretAccessKey: String) -> S3Configuration { ... }
    public static func r2(accountID: String, accessKeyID: String, secretAccessKey: String, jurisdiction: R2Jurisdiction = .default) -> S3Configuration { ... }
    public static func digitalOceanSpaces(region: String, accessKeyID: String, secretAccessKey: String) -> S3Configuration { ... }
}
```

---

## 3. URL style: virtual-hosted vs. path-style

Two ways to address a bucket:

```
Virtual-hosted:  https://my-bucket.s3.us-east-1.amazonaws.com/path/to/key
Path-style:      https://s3.us-east-1.amazonaws.com/my-bucket/path/to/key
```

**Default to virtual-hosted.** AWS deprecated path-style for new buckets; R2 and Spaces both prefer it. Keep path-style as a fallback toggle for edge cases like buckets with dots in their name (which break TLS cert wildcards) or local testing against MinIO.

---

## 4. AWS Signature V4 — the algorithm

This is the core of the package. Every request goes through the same five-step ritual.

### 4.1 Required headers before signing

Add these to your request first, since their values feed into the signature:

| Header | Value |
|---|---|
| `Host` | The endpoint host, no scheme |
| `X-Amz-Date` | Current time, ISO8601 basic format: `YYYYMMDD'T'HHMMSS'Z'` |
| `X-Amz-Content-Sha256` | Hex SHA256 of the request body (or `UNSIGNED-PAYLOAD`) |
| `X-Amz-Security-Token` | Only if using temporary credentials |

### 4.2 Build the canonical request

```
CanonicalRequest =
  HTTPMethod + '\n' +
  CanonicalURI + '\n' +
  CanonicalQueryString + '\n' +
  CanonicalHeaders + '\n' +
  SignedHeaders + '\n' +
  HashedPayload
```

Where:

- **HTTPMethod** — uppercase, e.g. `GET`, `PUT`
- **CanonicalURI** — URI path, percent-encoded per RFC 3986 *except* the path separator `/` is preserved. Encode each segment individually. For S3, **do not double-encode** (this is one of the most common bugs).
- **CanonicalQueryString** — sorted by key (byte order), each key and value URI-encoded, joined by `=` and `&`. Keys with no value get an empty string after `=`.
- **CanonicalHeaders** — lowercased header name + `:` + trimmed value + `\n`, sorted by header name.
- **SignedHeaders** — lowercased header names, sorted, joined by `;`. Must include `host`, `x-amz-date`, `x-amz-content-sha256` at minimum.
- **HashedPayload** — hex-encoded lowercase SHA256 of the request body. For empty bodies use `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

### 4.3 Build the string to sign

```
StringToSign =
  "AWS4-HMAC-SHA256" + '\n' +
  X-Amz-Date + '\n' +
  CredentialScope + '\n' +
  HexSha256(CanonicalRequest)

CredentialScope = YYYYMMDD + "/" + region + "/s3/aws4_request"
```

### 4.4 Derive the signing key

Four chained HMAC-SHA256 operations:

```
kDate    = HMAC("AWS4" + secretAccessKey, YYYYMMDD)
kRegion  = HMAC(kDate, region)
kService = HMAC(kRegion, "s3")
kSigning = HMAC(kService, "aws4_request")
```

### 4.5 Calculate the signature and build the Authorization header

```
signature = HexLowercase(HMAC(kSigning, StringToSign))

Authorization: AWS4-HMAC-SHA256
  Credential={accessKeyID}/{credentialScope},
  SignedHeaders={signedHeaders},
  Signature={signature}
```

(That goes on a single line; commas separate the three components.)

### 4.6 Swift implementation skeleton

Use Apple's `CryptoKit` — it's built in, fast, and Sendable-friendly.

```swift
import CryptoKit
import Foundation

struct SigV4Signer {
    let config: S3Configuration

    func sign(_ request: inout URLRequest, payload: Data) throws {
        let now = Date()
        let amzDate = Self.amzDateFormatter.string(from: now)         // 20260503T180512Z
        let dateStamp = String(amzDate.prefix(8))                     // 20260503
        let payloadHash = SHA256.hash(data: payload).hexLower()

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        if let token = config.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let canonicalRequest = try buildCanonicalRequest(request, payloadHash: payloadHash)
        let credentialScope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = """
        AWS4-HMAC-SHA256
        \(amzDate)
        \(credentialScope)
        \(SHA256.hash(data: Data(canonicalRequest.utf8)).hexLower())
        """

        let kDate = hmac(key: Data("AWS4\(config.secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(config.region.utf8))
        let kService = hmac(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmac(key: kService, data: Data("aws4_request".utf8))
        let signature = hmac(key: kSigning, data: Data(stringToSign.utf8)).hexLower()

        let signedHeaders = canonicalSignedHeaders(request)
        let auth = "AWS4-HMAC-SHA256 Credential=\(config.accessKeyID)/\(credentialScope), " +
                   "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
    }

    private func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}

extension Data {
    func hexLower() -> String { map { String(format: "%02x", $0) }.joined() }
}
extension SHA256.Digest {
    func hexLower() -> String { Data(self).hexLower() }
}
```

### 4.7 Common SigV4 mistakes

- Double-percent-encoding the path. Encode once, preserving `/`.
- Forgetting to sort query parameters before joining.
- Using lowercase ISO date format with dashes (must be `YYYYMMDDTHHMMSSZ`).
- Including the port in `Host` header when it's the default for the scheme.
- Using `UNSIGNED-PAYLOAD` and forgetting to put that exact string (not a hash of it) in the `X-Amz-Content-Sha256` header.
- AWS SDK Java v2 quirk that affects R2: chunked transfer encoding causes signature mismatches against R2. If you implement chunked uploads, make it opt-in and default off.

---

## 5. Core REST operations

All responses are XML. Plan for an XML decoder (Foundation's `XMLParser`, or a Codable-friendly third-party like `XMLCoder`).

### 5.1 Bucket operations

| Operation | Method | Path |
|---|---|---|
| ListBuckets | `GET` | `/` (on the service endpoint, no bucket) |
| CreateBucket | `PUT` | `/` (on the bucket endpoint) |
| DeleteBucket | `DELETE` | `/` (on the bucket endpoint) |
| HeadBucket | `HEAD` | `/` (on the bucket endpoint) |
| GetBucketLocation | `GET` | `/?location` |
| PutBucketCors | `PUT` | `/?cors` |
| GetBucketCors | `GET` | `/?cors` |

**CreateBucket** for non-`us-east-1` regions requires a body specifying the location:

```xml
<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <LocationConstraint>eu-west-2</LocationConstraint>
</CreateBucketConfiguration>
```

For R2, `LocationConstraint` is ignored unless you're using location hints; for Spaces, the bucket region is determined by the endpoint.

### 5.2 Object operations

| Operation | Method | Path | Notes |
|---|---|---|---|
| PutObject | `PUT` | `/{key}` | Body is the file contents |
| GetObject | `GET` | `/{key}` | Supports `Range:` header |
| HeadObject | `HEAD` | `/{key}` | Metadata only |
| DeleteObject | `DELETE` | `/{key}` | |
| DeleteObjects | `POST` | `/?delete` | Batch delete, body is XML |
| CopyObject | `PUT` | `/{key}` | With `x-amz-copy-source: /sourceBucket/sourceKey` |
| ListObjectsV2 | `GET` | `/?list-type=2` | With optional `prefix`, `delimiter`, `continuation-token`, `max-keys` |

**ListObjectsV2** is the modern listing endpoint and is supported by all three providers. Pagination is via the `NextContinuationToken` element; pass it back as the `continuation-token` query parameter on the next request.

### 5.3 Useful object headers

| Header | Direction | Purpose |
|---|---|---|
| `Content-Type` | request | MIME type stored with the object |
| `Content-Length` | request | Required for `PUT` |
| `Content-MD5` | request | Optional integrity check |
| `Cache-Control` | request | Stored, returned on `GET` |
| `x-amz-meta-{name}` | request | Arbitrary user metadata |
| `x-amz-acl` | request | `private`, `public-read`, etc. |
| `x-amz-storage-class` | request | `STANDARD`, `INFREQUENT_ACCESS`, etc. |
| `If-Match` / `If-None-Match` | request | Conditional GET/PUT |
| `Range` | request | Partial GET, e.g. `bytes=0-1023` |
| `ETag` | response | Object hash (MD5 for single uploads, opaque for multipart) |
| `Last-Modified` | response | RFC 7231 date |

---

## 6. Multipart uploads

Required for objects larger than 5 GB (AWS, R2). Recommended for anything over ~100 MB so a network blip doesn't lose a 30-minute upload. Three steps plus completion:

```
1.  POST /{key}?uploads             → returns UploadId
2.  PUT  /{key}?partNumber=N&uploadId=...  (per part, 5 MiB minimum except last)
                                    → returns ETag per part
3.  POST /{key}?uploadId=...        → body lists parts and ETags, finalizes object
```

Abandoned uploads should be cleaned up via `DELETE /{key}?uploadId=...` — they otherwise sit billable indefinitely on AWS and Spaces. (R2 has automatic lifecycle cleanup but you should still abort explicitly.)

Suggested API surface in Swift:

```swift
public actor MultipartUpload {
    public func uploadPart(_ data: Data, partNumber: Int) async throws -> UploadedPart
    public func complete() async throws -> CompletedObject
    public func abort() async throws
}
```

Make `uploadPart` callable concurrently — parts can be uploaded in parallel and assembled in order at `complete()`.

---

## 7. Presigned URLs

Lets a client (or browser, or another service) GET or PUT an object with no S3 credentials, using a time-limited URL. The signature lives in the query string instead of the `Authorization` header.

Algorithm is the same SigV4 with two changes:

1. Add these query parameters before signing: `X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires` (seconds, max 604800), `X-Amz-SignedHeaders`.
2. Use `UNSIGNED-PAYLOAD` as the payload hash.
3. Append `X-Amz-Signature` to the resulting URL.

This is a pure local computation — no network call required. All three providers support presigned GET, PUT, HEAD, DELETE. R2 specifically does not support presigned POST form uploads.

---

## 8. Suggested Swift package architecture

```
S3Kit/
├── Package.swift
├── Sources/
│   └── S3Kit/
│       ├── Configuration/
│       │   ├── S3Configuration.swift
│       │   └── Provider.swift            // factories for AWS / R2 / Spaces
│       ├── Signing/
│       │   ├── SigV4Signer.swift
│       │   ├── CanonicalRequest.swift
│       │   └── PresignedURL.swift
│       ├── Client/
│       │   ├── S3Client.swift            // public API surface (actor)
│       │   ├── HTTPTransport.swift       // URLSession wrapper, swappable for tests
│       │   └── RetryPolicy.swift
│       ├── Operations/
│       │   ├── Buckets.swift             // list/create/delete/head
│       │   ├── Objects.swift             // get/put/delete/head/copy/list
│       │   └── Multipart.swift
│       ├── Models/
│       │   ├── Bucket.swift
│       │   ├── ObjectMetadata.swift
│       │   └── ListObjectsResult.swift
│       └── XML/
│           ├── XMLDecoder.swift
│           └── ErrorResponse.swift
└── Tests/
    └── S3KitTests/
        ├── SigV4SignerTests.swift        // use AWS test vectors
        ├── CanonicalRequestTests.swift
        └── IntegrationTests.swift        // gated on env vars
```

### Key design points

**Make `S3Client` an `actor`.** It wraps a `URLSession` and a configuration; multiple concurrent calls are fine, but the signer's date/time generation should be serialized.

**Separate transport from operations.** A `protocol HTTPTransport` lets you swap in a mock for tests. Default implementation is `URLSession.shared` with `data(for:)` async.

**Stream large bodies.** Don't load a 4 GB file into `Data`. Use `URLSession.upload(for:fromFile:)` for `PutObject` with a file URL. For SigV4 you can use `UNSIGNED-PAYLOAD` to avoid hashing huge files (acceptable when the connection is HTTPS).

**Retry on 5xx and `RequestTimeout`.** S3 documents these as transient. Use exponential backoff with full jitter, capped at maybe 5 retries.

**Errors are XML.** S3 returns errors as an `<Error>` document with `<Code>`, `<Message>`, `<RequestId>`. Decode and surface as a typed Swift error:

```swift
public struct S3Error: Error, Sendable {
    public let code: String           // e.g. "NoSuchBucket", "AccessDenied"
    public let message: String
    public let requestID: String?
    public let httpStatus: Int
}
```

---

## 9. Provider-specific quirks to handle

### AWS S3

- `us-east-1` does not require `LocationConstraint` on bucket creation; all other regions do.
- New buckets default to "Block All Public Access" — your package can't override that with the API alone.
- ETags for multipart objects are not MD5 hashes; they're an opaque `{md5-of-md5s}-{partCount}` string. Don't validate them as MD5.

### Cloudflare R2

- Region is `auto`. SDKs that hard-require a real AWS region accept `us-east-1` as an alias.
- No egress fees, but the S3 API does have request-class billing (Class A = mutating, Class B = read).
- Some S3 features are not implemented: object tagging (`?tagging`) was historically unsupported; check the S3 API compatibility page for current status before relying on a niche endpoint.
- Bucket ACLs are not supported the same way as AWS — public buckets are configured at the bucket level via custom domains or `pub-xxx.r2.dev` subdomains, not via `x-amz-acl`.

### DigitalOcean Spaces

- The SigV4 region must be `us-east-1` regardless of the actual datacenter. The datacenter is encoded in the hostname.
- Spaces uses XML ACLs (`x-amz-acl: public-read` works) — closer to AWS than R2.
- Built-in CDN can be enabled per Space; once on, public objects are served from `{bucket}.{region}.cdn.digitaloceanspaces.com`.
- Access keys can only be created via the DO Control Panel, not the DO API.

---

## 10. Testing

### Use the official AWS SigV4 test suite

AWS publishes a [signing test suite](https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html) with input requests and expected canonical-requests, string-to-signs, and signatures. Drop these files into your test target as resources and assert each step of the pipeline. This is the only way to be confident your signer is correct before pointing it at real services.

### Use MinIO for local integration tests

[MinIO](https://min.io) speaks the S3 API and runs in Docker:

```
docker run -p 9000:9000 -e MINIO_ROOT_USER=test -e MINIO_ROOT_PASSWORD=testtesttest minio/minio server /data
```

Point your `S3Configuration` at `http://localhost:9000` with `usePathStyle: true`. Run create-bucket, put-object, get-object, list, multipart, delete, etc. without burning real provider credentials.

### Real-provider smoke tests

Gate them behind environment variables (`S3KIT_AWS_TEST=1` etc.) so they don't run by default. Spin up a throwaway bucket per test run with a UUID suffix so parallel CI doesn't collide.

---

## 11. References

- [AWS S3 API reference](https://docs.aws.amazon.com/AmazonS3/latest/API/Type_API_Reference.html)
- [AWS Signature Version 4 signing process](https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html)
- [Cloudflare R2 S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/) (also available as Markdown — append `index.md` to the URL)
- [Cloudflare R2 API tokens](https://developers.cloudflare.com/r2/api/tokens/)
- [DigitalOcean Spaces API reference](https://docs.digitalocean.com/reference/api/spaces/)
- [DigitalOcean Spaces with AWS SDKs](https://docs.digitalocean.com/products/spaces/how-to/use-aws-sdks/)
- [Apple CryptoKit documentation](https://developer.apple.com/documentation/cryptokit) — for `SHA256`, `HMAC<SHA256>`, `SymmetricKey`

---

## 12. Minimal working example

The smallest possible thing that puts then gets an object, end to end:

```swift
import Foundation

let config = S3Configuration.aws(
    region: "us-east-1",
    accessKeyID: ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"]!,
    secretAccessKey: ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"]!
)
let client = S3Client(configuration: config)

// PUT
let body = Data("hello, s3\n".utf8)
try await client.putObject(bucket: "my-bucket", key: "test.txt", body: body, contentType: "text/plain")

// GET
let object = try await client.getObject(bucket: "my-bucket", key: "test.txt")
print(String(data: object.body, encoding: .utf8)!)  // "hello, s3"

// LIST
let listing = try await client.listObjects(bucket: "my-bucket", prefix: "test")
for item in listing.contents { print(item.key, item.size) }

// DELETE
try await client.deleteObject(bucket: "my-bucket", key: "test.txt")
```

To swap providers, change only the configuration:

```swift
let r2 = S3Configuration.r2(accountID: "abc123", accessKeyID: "...", secretAccessKey: "...")
let spaces = S3Configuration.digitalOceanSpaces(region: "sfo3", accessKeyID: "...", secretAccessKey: "...")
```

The rest of the API stays identical — that's the whole point of building against the standard S3 surface.
