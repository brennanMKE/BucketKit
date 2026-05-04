# BucketKit — Concepts

A primer on S3 and S3-compatible object storage, written as the shared vocabulary BucketKit uses in its API and design discussions. Conceptual and provider-neutral where possible; provider-specific differences are called out where they affect the BucketKit API surface.

This document is not a tutorial. It defines the terms — buckets, keys, ETags, multipart, presigning, SigV4 — that the rest of the documentation and the public API assume the reader understands.

## Buckets, objects, keys, and prefixes

An **object** is the unit of storage: an immutable blob of bytes plus a small set of HTTP-style metadata. Once written, an object is replaced as a whole — there is no in-place edit, no append, no random write.

A **bucket** is the namespace that holds objects. Bucket names are globally unique on AWS S3 and account-unique on R2, Spaces, and B2. Buckets also pin a region (or a region-equivalent) at creation time.

A **key** is the full string that names an object inside a bucket — for example `users/42/avatar.png`. Keys are opaque strings, not file paths. S3 has **no real directories**: the slash is just a byte in the key. What looks like a directory listing is produced by querying with a `prefix` and a `delimiter` (typically `/`), which causes the server to roll keys sharing a common segment up into **common prefixes**.

This matters for the BucketKit API in two places:

- `BucketPath` resolves to a key, not a path. Leading slashes, `..`, and `.` segments are not normalized away — they become part of the key.
- `list(prefix:delimiter:)` returns both `items` (objects directly under the prefix) and `commonPrefixes` (the next "folder" level). Folder-style UIs are built from these two arrays; nothing on the server enforces folders.

## Regions and endpoints

Every S3-compatible service exposes an HTTPS endpoint and tags requests with a region used by SigV4. The endpoint and region together fully determine where a request goes; BucketKit's `BucketConfiguration` carries both.

| Provider | Endpoint shape | Region used for signing | URL style |
|---|---|---|---|
| AWS S3 | `https://s3.{region}.amazonaws.com` | the real region (`us-east-1`, `eu-west-2`, …) | virtual-hosted |
| Cloudflare R2 | `https://{accountID}.r2.cloudflarestorage.com` | literal `auto` | virtual-hosted |
| Cloudflare R2 (jurisdictional) | `…{accountID}.eu.r2.cloudflarestorage.com`, `…fedramp…` | literal `auto` | virtual-hosted |
| DigitalOcean Spaces | `https://{region}.digitaloceanspaces.com` | literal `us-east-1` regardless of geographic region | virtual-hosted |
| Backblaze B2 (S3 API) | `https://s3.{region}.backblazeb2.com` | the real B2 region (`us-west-004`, …) | virtual-hosted |
| MinIO / custom | user-supplied URL | user-supplied | path-style by default |

**Two URL styles** exist for addressing a bucket:

- **Virtual-hosted style**: `https://{bucket}.s3.{region}.amazonaws.com/{key}`
- **Path style**: `https://{endpoint}/{bucket}/{key}`

AWS, R2, and Spaces use virtual-hosted style; MinIO and most self-hosted gateways use path style. The choice affects how the `Host` header is formed and therefore the SigV4 canonical request — getting it wrong yields `SignatureDoesNotMatch`. BucketKit tracks this with `BucketConfiguration.usePathStyle`.

## Authentication and SigV4

S3 uses **AWS Signature Version 4 (SigV4)** for authentication. A request carries an `Authorization` header (or, for presigned URLs, query parameters) computed from:

1. A **canonical request** — method, canonical URI, canonical query string, canonical headers, signed-headers list, and a SHA-256 of the payload.
2. A **string to sign** — the algorithm, ISO-8601 timestamp, credential scope (`{date}/{region}/{service}/aws4_request`), and the SHA-256 of the canonical request.
3. A **derived signing key** — `HMAC-SHA256` chained over the secret access key, date, region, service (`s3`), and the literal `aws4_request`.
4. A final `HMAC-SHA256(stringToSign, signingKey)` rendered as lowercase hex.

Important details that shape the BucketKit signer:

- **Credential triple**: `(accessKeyID, secretAccessKey, sessionToken?)`. When a session token is present, `X-Amz-Security-Token` is added to the request and included in the signed headers.
- **Payload hashing**: the `x-amz-content-sha256` header carries either the literal SHA-256 of the body or the sentinel `UNSIGNED-PAYLOAD`. Streaming-aware variants exist but are out of scope for v1.
- **Provider quirks**: R2 ignores the geographic region but still requires the literal token `auto` in the credential scope; Spaces requires the literal `us-east-1`. Mismatches surface as `SignatureDoesNotMatch` (HTTP 403).
- **Clock skew**: the timestamp must be within ~15 minutes of the server's clock. Bad device clocks produce `RequestTimeTooSkewed`.

## Object metadata, content type, ETag, and versioning

Every object carries:

- **System metadata** — `Content-Type`, `Content-Length`, `Cache-Control`, `Content-Encoding`, `Content-Disposition`, `Last-Modified`, the storage class, and an `ETag`. These map to the matching HTTP headers and are echoed on `GET`/`HEAD`.
- **User metadata** — arbitrary `x-amz-meta-*` headers set at write time. Keys are case-insensitive and lowercased on retrieval. Total user-metadata size is capped (2 KB on AWS).
- **An `ETag`** — an opaque validator. For single-part PUTs, AWS sets it to the MD5 hex of the body. For multipart uploads, it is `MD5(concat(MD5(part1), MD5(part2), …))-{partCount}` and is **not** the MD5 of the whole object. R2 and other providers compute the multipart ETag differently. Code that relies on the ETag being the body MD5 is wrong on every provider for multipart.

ETags drive **conditional requests**:

- `If-Match` / `If-None-Match` on `GET` for cache validation.
- `If-None-Match: *` on `PUT` for create-only writes (BucketKit exposes this as `UploadDataOptions.ifNoneMatch`).

**Versioning** is opt-in per bucket. When enabled, every write produces a new **version ID** and deletes become tombstones; older versions stay readable until permanently deleted. `UploadResult.versionID` is non-nil only for versioned buckets. R2 supports object versioning with similar semantics; Spaces and B2 (via the S3 API) have limited or no versioning support — design code defensively.

## Multipart uploads and streaming

For large or unknown-length payloads, S3 supports **multipart uploads**:

1. **`CreateMultipartUpload`** returns an `UploadId`.
2. **`UploadPart`** is called per part, in any order, in parallel. Each part except the last must be at least **5 MiB**; the last part has no minimum. Up to **10,000 parts** per upload. The maximum object size is 5 TiB.
3. **`CompleteMultipartUpload`** assembles the final object given the part list and their ETags. The server computes the multipart-style ETag at this point.
4. **`AbortMultipartUpload`** discards an in-progress upload. Forgetting to abort leaves orphan parts that bill against the bucket — lifecycle rules typically clean these up.

BucketKit applies multipart automatically for `uploadFile` above a configurable threshold (default 100 MiB, hard floor 5 MiB) and exposes the explicit `MultipartUpload` actor for callers that need fine control. Cancellation triggers a best-effort `AbortMultipartUpload`.

**Streaming** in BucketKit is HTTP-level: large uploads stream from disk via `URLSession.upload(fromFile:)` rather than buffering in memory; downloads stream to a destination URL. There is no Combine publisher and no callback — progress flows through the task's `AsyncStream<TransferProgress>`.

Provider differences worth noting: **R2** caps a single `PutObject` at 5 GiB and recommends multipart above ~100 MiB; **B2** requires `parts >= 5 MB` like AWS but bills aborted multipart parts until cleaned up; **Spaces** mirrors AWS limits.

## Presigned URLs

A **presigned URL** moves the SigV4 signature into the query string so a third party — a browser, another service, a CDN — can run a single S3 operation without holding credentials. The URL embeds the credential scope, signed headers, an expiry, and the signature itself.

Key properties:

- Computed locally; no network round-trip.
- Default expiry is short (BucketKit defaults to one hour); the **maximum is 7 days**, enforced by the signer.
- Tied to the HTTP method — a GET URL cannot be used for PUT and vice versa.
- If extra headers are signed (e.g. `Content-Type`, `x-amz-acl`), the caller must send those exact headers when using the URL or signing fails.
- Session tokens are encoded as `X-Amz-Security-Token` in the query.

BucketKit exposes presigning via `getURL(bucket:path:options:)` for `GET`, `PUT`, `HEAD`, and `DELETE`.

## Storage classes and lifecycle policies

A **storage class** is a per-object durability/availability/cost tier. AWS classes include `STANDARD`, `STANDARD_IA`, `INTELLIGENT_TIERING`, `ONEZONE_IA`, `GLACIER_IR`, `GLACIER`, and `DEEP_ARCHIVE`. R2 has effectively one tier (`STANDARD`) plus an `INFREQUENT_ACCESS` class on supported plans. Spaces exposes a single class. B2 surfaces its tiers through the native API more than the S3 facade.

BucketKit models this as a `StorageClass` enum on uploads and on listed objects. On non-AWS providers, unsupported values return `InvalidStorageClass` (HTTP 400) — callers should default to `nil` (provider-default) unless they know the target supports the class.

**Lifecycle policies** are bucket-level rules that transition objects between classes or expire them after a delay (e.g. "move to Glacier after 30 days, delete after 365"). They also clean up incomplete multipart uploads. Lifecycle management is **out of scope for BucketKit v1** — callers configure it via the provider's console or other tooling.

## Server-side encryption

S3 supports three SSE modes; BucketKit exposes them as `ServerSideEncryption`:

- **SSE-S3** (`AES256`) — server manages the key. One header: `x-amz-server-side-encryption: AES256`.
- **SSE-KMS** — encrypted with a KMS customer master key. Headers: `x-amz-server-side-encryption: aws:kms` and optional `x-amz-server-side-encryption-aws-kms-key-id`. AWS only — R2/Spaces/B2 do not implement KMS.
- **SSE-C** — caller supplies the key on every request. Headers: `x-amz-server-side-encryption-customer-algorithm/key/key-MD5`. The key is never stored; lose it and the object is unrecoverable.

R2 and B2 encrypt all objects at rest by default; explicit SSE headers are accepted as a no-op or rejected depending on the provider. SSE-KMS requests against R2 fail with `InvalidArgument`. Treat KMS as an AWS-only feature in BucketKit code paths.

Beyond SSE, **TLS in transit** is mandatory: every supported endpoint is HTTPS-only. Plain HTTP is allowed only when pointing `BucketConfiguration.custom` at a local MinIO during development.

## Access control: bucket policies, ACLs, IAM

S3-compatible services layer three overlapping access models:

- **IAM** (or the provider's equivalent) — identity-based policies attached to the access key being used. This is what authorizes the BucketKit caller; everything else assumes the caller's IAM identity has the relevant action permitted.
- **Bucket policies** — JSON resource policies that grant or deny access to principals on a bucket and its keys. AWS, R2, and Spaces support a substantial subset of S3 bucket-policy syntax; semantics differ in the edges (R2 has limited condition-key support).
- **Object ACLs** — the legacy per-object grant model (`private`, `public-read`, `public-read-write`, `authenticated-read`, `bucket-owner-read`, `bucket-owner-full-control`). AWS now discourages ACLs and many new buckets ship with `BucketOwnerEnforced`, which **rejects** `x-amz-acl` headers entirely. R2 ignores ACLs. Spaces honors a small subset.

BucketKit exposes `ObjectACL` as an upload option but documents it as best-effort: setting `acl: .publicRead` against a `BucketOwnerEnforced` AWS bucket or against R2 returns `AccessControlListNotSupported` or is silently ignored. Bucket policies are the portable way to grant public read; BucketKit does not manage them in v1.

## Consistency model

Modern S3 offers **strong read-after-write consistency** for new objects, overwrites, and deletes, in every region. After a successful `PutObject` returns 200, a subsequent `GetObject` from any client sees the new bytes; after a successful overwrite, no reader sees stale bytes; after a delete, no reader sees the object.

What is **not** strongly consistent:

- **`ListObjects`** is read-after-write consistent on AWS S3 today, but on some S3-compatible services (older MinIO setups, eventually consistent gateways) listing may briefly omit a just-written object.
- **Bucket configuration changes** (policies, lifecycle, public-access blocks) propagate eventually.
- **CDN-backed reads** (CloudFront, R2 public buckets fronted by Cloudflare) follow CDN cache semantics, not S3 consistency.

R2, Spaces, and B2 advertise strong read-after-write for object operations as well. Code targeting BucketKit can assume strong consistency for object writes/reads/deletes; design list-driven workflows to tolerate the rare omission.

## Common error responses and status codes

S3 error responses are XML documents with a `<Code>`, a `<Message>`, a `<RequestId>`, and an HTTP status. BucketKit decodes them into `BucketServiceError(code:message:requestID:httpStatus:resource:)`.

Codes worth recognizing:

| HTTP | Code | Typical cause |
|---|---|---|
| 301 | `PermanentRedirect` | Wrong region for the bucket; AWS returns the right region in the body. |
| 400 | `InvalidArgument` | Malformed parameter, unsupported header for the provider. |
| 400 | `InvalidRequest` | SigV4 wire-format error, bad multipart part list. |
| 400 | `EntityTooSmall` | Multipart part below 5 MiB (any part except the last). |
| 400 | `EntityTooLarge` | Single PUT above 5 GiB; use multipart. |
| 403 | `AccessDenied` | IAM/bucket-policy denial. |
| 403 | `SignatureDoesNotMatch` | Wrong secret, wrong region, wrong URL style, clock skew, header not included in signed list. |
| 403 | `RequestTimeTooSkewed` | Device clock off by more than ~15 minutes. |
| 403 | `InvalidAccessKeyId` | Access key ID does not exist (or wrong account on R2). |
| 404 | `NoSuchBucket` | Bucket does not exist or is in a different account. |
| 404 | `NoSuchKey` | Object does not exist. |
| 404 | `NoSuchUpload` | Multipart `UploadId` already aborted, completed, or expired. |
| 409 | `BucketAlreadyExists` / `BucketAlreadyOwnedByYou` | Bucket name conflict on create. |
| 412 | `PreconditionFailed` | `If-Match` / `If-None-Match` did not match. |
| 416 | `InvalidRange` | `Range` header out of bounds. |
| 503 | `SlowDown` / `RequestTimeout` | Throttling or transient server issue — BucketKit retries with exponential backoff plus full jitter. |

For non-S3 transport problems (DNS failure, TLS error, no network), BucketKit surfaces `BucketClientError.transport(URLError)` instead of a service error.
