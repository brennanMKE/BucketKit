# Examples

Minimal, copy-pasteable Swift snippets demonstrating typical use of `Bucket`.
Each file is small (~20–60 lines) and focuses on one concept. Drop any
snippet into a Swift script context (or an iOS / macOS app target) that
depends on the `Bucket` library.

## How this folder relates to the build

These files are **documentation**, not part of the package's library
target and not compiled by SwiftPM. They demonstrate the public API but
are not linked into a product.

The package guards against API drift in
`Tests/BucketTests/PublicSurfaceCompilationTests.swift`, which exercises
the same public-surface call shapes inside `if Bool(false) { ... }`
blocks. The compiler type-checks the bodies but the runtime never
issues a network request, so the test passes offline and in CI without
credentials.

If you change the public API, update both:
- the relevant snippet here (so the docs stay accurate); and
- `PublicSurfaceCompilationTests.swift` (so the compile-check still
  references the new shape).

## Files

| File | Description |
|---|---|
| [`Configuration.swift`](Configuration.swift) | Build a `BucketConfiguration` for AWS, R2 (default and EU), DigitalOcean Spaces, and MinIO via `custom`. |
| [`UploadDownload.swift`](UploadDownload.swift) | `uploadData`, `uploadFile`, `downloadData`, `downloadFile` with progress consumption. |
| [`ListObjects.swift`](ListObjects.swift) | Page-by-page `list(...)` with continuation tokens and the streaming `listAll(...)` `AsyncSequence`. |
| [`PresignedURL.swift`](PresignedURL.swift) | `getURL` for `GET` (download via `URLSession`) and `PUT` (upload via `URLSession`). Includes the 7-day expiry note. |
| [`Multipart.swift`](Multipart.swift) | Explicit `MultipartUpload` actor: initiate, upload parts, complete (or abort). |

## Provider configuration at a glance

| Provider | Factory | Endpoint | Region (SigV4) | URL style |
|---|---|---|---|---|
| AWS S3 | `BucketConfiguration.aws` | `https://s3.{region}.amazonaws.com` | real region | virtual-hosted |
| Cloudflare R2 | `BucketConfiguration.r2` | `https://{accountID}.r2.cloudflarestorage.com` | literal `auto` | virtual-hosted |
| Cloudflare R2 (EU) | `BucketConfiguration.r2(jurisdiction: .eu)` | `https://{accountID}.eu.r2.cloudflarestorage.com` | literal `auto` | virtual-hosted |
| DigitalOcean Spaces | `BucketConfiguration.digitalOceanSpaces` | `https://{region}.digitaloceanspaces.com` | literal `us-east-1` | virtual-hosted |
| MinIO / custom | `BucketConfiguration.custom` | user-supplied | user-supplied | path-style by default |

## Credentials

Every snippet reads credentials from environment variables. Never hard-code
real credentials, and never commit them. Typical variables used here:

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`
- `DO_SPACES_REGION`, `DO_SPACES_KEY`, `DO_SPACES_SECRET`
- `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`

## Notes

- These snippets are illustrative — they're meant to be read top to
  bottom and copied into your own project.
- They do not run in CI; the package's tests handle that. The macOS
  test app (issue #0003) is the place to drive these against a live
  service interactively.
- All public BucketKit types are `Sendable`; the snippets are written
  for Swift 6 strict concurrency.
