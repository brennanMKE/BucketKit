# BucketKit — Source Stability Note (v1)

**Status:** Draft v1 review · **Last updated:** 2026-05-03 · **Tracks:** issue #0026 (M6 polish)

This document records the source-stability stance of every `public` symbol in
`Sources/Bucket/` ahead of the v1.0 tag. It is *not* a behavioural / wire-format
contract — for that see `PRD.md` (§6 Auth, §9 Networking, §10 XML, §17
Milestones) and `Concepts.md`.

The audit is a documentation exercise. No types were renamed, removed, or
reshaped while writing this note.

---

## 1. Scope

**In scope.** Every `public` declaration in `Sources/Bucket/`:
- All initializers and stored properties on public types
- All public methods on `BucketClient` (across `Operations/*.swift`)
- The `BucketTransferTask` protocol, its four concrete tasks, and the
  `TransferProgress` value type
- The `BucketPath` protocol and `StringBucketPath`
- All Options structs in `Options/`
- All Models in `Models/`
- `BucketServiceError` and `BucketClientError`
- `BucketConfiguration`, `R2Jurisdiction`
- `HTTPTransport`, `URLSessionTransport`, `TransportBody`, `RetryPolicy`
- `MultipartUpload` (actor)

**Out of scope.**
- Internal types in `Signing/`, `XML/`, `Logging/`, plus the internal
  `RetryRunner`, `MultipartInitiator`, `MultipartURL`, `MultipartFileReader`,
  `TransferTaskState`, and all wire-format response models in
  `XML/ResponseModels.swift` — these may be reshaped without notice. (Spot
  check confirmed: no `public` declarations exist in those directories.)
- Wire-protocol semantics, signing correctness, retry behaviour, byte-on-disk
  layout — i.e. anything observable through the network or filesystem rather
  than through the Swift type system.
- Logging subsystem / category names (PRD §11 governs).

---

## 2. Stability levels

The package will reach v1.0 with three stability tiers. Each public symbol is
classified into exactly one tier in §3.

### Frozen v1
Naming and shape will not change before a major version bump. Adding a new
case to a `public enum` declared `Frozen` is treated as a breaking change.
Adding a new stored property on a `Frozen` struct is also breaking unless the
new property has a default and the existing initializer signature is preserved
intact.

### Subject to additive change
Existing call sites will not break across minor releases, but the type can
grow:
- New cases added to enums where the type is *not* exhaustively switched on
  by callers (BucketKit cannot enforce this — we take the position that
  client-side enums where callers `switch` exhaustively are *de facto* frozen,
  but the v1 contract for these types only promises additive growth).
- New stored properties added to structs, gated behind defaulted parameters
  on the existing public initializer so `.init()` and any existing call sites
  keep compiling.
- New static factory functions on configuration / option types.
- New methods on actors and on `BucketClient` (these are always additive in
  Swift unless they collide with a name a caller is shadowing).

### Provisional
The current shape is the best guess at v1 and may be reshaped before tagging
1.0 if implementation discovers a constraint we don't yet know. Code that
binds tightly to a Provisional symbol should expect to migrate.

After 1.0, Provisional symbols are promoted (typically to *Subject to additive
change*). Until then we make no promise stronger than "we will document any
break in the changelog".

---

## 3. Symbol catalog

### 3.1 `Configuration/`

| Symbol | Kind | Stability |
|---|---|---|
| `BucketConfiguration` | struct | Subject to additive change |
| `BucketConfiguration.endpoint`, `region`, `accessKeyID`, `secretAccessKey`, `sessionToken`, `usePathStyle` | stored vars | Frozen v1 |
| `BucketConfiguration.extraHeaders` | stored var | Provisional (see §6) |
| `BucketConfiguration.init(...)` (memberwise) | init | Subject to additive change (new defaulted params) |
| `BucketConfiguration.aws / r2 / digitalOceanSpaces / custom` | static factories | Subject to additive change (new providers, new defaulted params) |
| `R2Jurisdiction` | enum | Subject to additive change (new jurisdictions) |
| `R2Jurisdiction.default / .eu / .fedramp` | cases | Frozen v1 |

### 3.2 `Client/`

| Symbol | Kind | Stability |
|---|---|---|
| `BucketClient` | actor | Frozen v1 |
| `BucketClient.configuration / transport / retryPolicy` | nonisolated let | Frozen v1 |
| `BucketClient.init(configuration:transport:retryPolicy:)` | init | Subject to additive change |
| `HTTPTransport` | protocol | Frozen v1 (see follow-up about future `.stream`) |
| `TransportBody` | enum | Subject to additive change (new payload variants — see PRD §9) |
| `TransportBody.data / .fileURL` | cases | Frozen v1 |
| `URLSessionTransport` | struct | Frozen v1 |
| `URLSessionTransport.session`, `init(session:)`, `.shared` | members | Frozen v1 |
| `RetryPolicy` | struct | Provisional (knobs may evolve) |
| `RetryPolicy.maxAttempts / baseDelay / maxDelay / retryableStatuses / retryableServiceCodes / retryNetworkErrors` | stored vars | Provisional |
| `RetryPolicy.default / .none` | static lets | Frozen v1 (the names; the *values* may change) |

`RetryRunner` is internal — out of scope.

### 3.3 `Errors/`

| Symbol | Kind | Stability |
|---|---|---|
| `BucketServiceError` | struct | Frozen v1 |
| `BucketServiceError.code / message / requestID / httpStatus / resource` | stored lets | Frozen v1 |
| `BucketServiceError.init(...)` | init | Frozen v1 |
| `BucketClientError` | enum | Subject to additive change (new cases) |
| existing cases (`invalidConfiguration`, `signingFailed`, `transport`, `decodingFailed`, `multipartPartTooSmall`, `cancelled`) | cases | Frozen v1 |

Note: `BucketClientError` is `public enum` without `@frozen`. New cases land
as a minor-version addition; callers who exhaustively `switch` will get a
warning and need a `default` clause, which is the standard Swift evolution
trade-off.

### 3.4 `Models/`

| Symbol | Kind | Stability |
|---|---|---|
| `BucketInfo` | struct (Sendable, Hashable) | Frozen v1 |
| `BucketListResult` | struct | Subject to additive change |
| `BucketMetadata` | struct | Subject to additive change (HEAD response can grow) |
| `BucketObject` | struct | Subject to additive change |
| `HTTPMethod` | enum (rawValue: String) | Frozen v1 |
| `ObjectACL` | enum (rawValue: String) | Subject to additive change |
| `ObjectMetadata` | struct | Subject to additive change |
| `ServerSideEncryption` | enum | Subject to additive change |
| `StorageClass` | enum (rawValue: String) | Subject to additive change |
| `UploadedPart` | struct | Frozen v1 |
| `UploadResult` | struct | Frozen v1 |

The "Subject to additive change" tag on `BucketObject` / `BucketListResult`
covers fields S3 may surface that we don't model yet (e.g. `Owner`,
`ChecksumAlgorithm`, `ChecksumCRC32C`).

### 3.5 `Operations/` (extensions on `BucketClient`)

Method signatures themselves are Frozen v1; their `Options` parameter is the
seam for additive change:

| Method | Signature stability |
|---|---|
| `getURL(bucket:path:options:)` | Frozen v1 |
| `downloadData(bucket:path:options:)` | Frozen v1 |
| `downloadFile(bucket:path:local:options:)` | Frozen v1 |
| `uploadData(bucket:path:data:options:)` | Frozen v1 |
| `uploadFile(bucket:path:local:options:)` | Frozen v1 |
| `remove(bucket:path:options:)` | Frozen v1 |
| `headObject(bucket:path:)` | Frozen v1 |
| `list(bucket:path:options:)` | Frozen v1 |
| `listAll(bucket:path:options:)` | Frozen v1 |
| `listBuckets()` | Frozen v1 |
| `createBucket(_:locationConstraint:)` | Frozen v1 |
| `deleteBucket(_:)` | Frozen v1 |
| `headBucket(_:)` | Frozen v1 |
| `multipartUpload(bucket:path:options:)` | Frozen v1 |

`MultipartUpload` (actor):

| Member | Stability |
|---|---|
| `MultipartUpload` (actor) | Subject to additive change |
| `MultipartUpload.bucket / key / uploadID` | nonisolated let | Frozen v1 |
| `uploadPart(_:partNumber:)` | Frozen v1 |
| `uploadPart(fileURL:partNumber:)` | Frozen v1 |
| `complete()` / `abort()` | Frozen v1 |

### 3.6 `Options/`

All Options structs are **Subject to additive change**. New fields land as
defaulted initializer parameters so `.init()` and any positional or labeled
call sites keep compiling.

| Type | Stability |
|---|---|
| `UploadDataOptions` | Subject to additive change |
| `UploadFileOptions` | Subject to additive change |
| `DownloadDataOptions` | Subject to additive change |
| `DownloadFileOptions` | Subject to additive change |
| `GetURLOptions` | Subject to additive change |
| `ListOptions` | Subject to additive change |
| `RemoveOptions` | Subject to additive change |

### 3.7 `Path/`

| Symbol | Kind | Stability |
|---|---|---|
| `BucketPath` | protocol | Frozen v1 |
| `BucketPath.resolve()` | protocol requirement | Frozen v1 |
| `BucketPath.fromString(_:)` (constrained extension) | static | Frozen v1 |
| `StringBucketPath` | struct | Frozen v1 |
| `StringBucketPath.value`, `init(_:)`, `resolve()` | members | Frozen v1 |

### 3.8 `Tasks/`

| Symbol | Kind | Stability |
|---|---|---|
| `BucketTransferTask<Output>` | protocol | Provisional — see §6 |
| `TransferProgress` | struct | Frozen v1 |
| `BucketUploadDataTask` | struct | Frozen v1 (the type; pause/resume are Provisional — see §6) |
| `BucketUploadFileTask` | struct | Frozen v1 (same caveat) |
| `BucketDownloadDataTask` | struct | Frozen v1 (same caveat) |
| `BucketDownloadFileTask` | struct | Frozen v1 (same caveat) |

Specifically: `cancel()` on every task is Frozen v1 and works today.
`pause()` / `resume()` are Provisional — they currently flip an advisory
flag in `TransferTaskState` and operation code does not observe them.
Semantics will firm up when `URLSessionTaskDelegate` integration lands.

### 3.9 Internal-only directories

`Signing/`, `XML/`, `Logging/`, `Tasks/TransferTaskState.swift`, and the
multipart helper enums (`MultipartInitiator`, `MultipartURL`,
`MultipartFileReader`) declare no `public` symbols. Confirmed by grep.

---

## 4. Naming alignment vs Amplify Storage

Per PRD §2 we borrow the *shape* of Amplify's `StorageCategoryBehavior` so
existing Amplify users find the surface familiar. This section enumerates
where the names match and where they deliberately diverge — every divergence
should have a documented reason.

### Verbs we kept

| Amplify | BucketKit |
|---|---|
| `getURL(path:options:)` | `getURL(bucket:path:options:)` |
| `downloadData(path:options:)` | `downloadData(bucket:path:options:)` |
| `downloadFile(path:local:options:)` | `downloadFile(bucket:path:local:options:)` |
| `uploadData(path:data:options:)` | `uploadData(bucket:path:data:options:)` |
| `uploadFile(path:local:options:)` | `uploadFile(bucket:path:local:options:)` |
| `remove(path:options:)` | `remove(bucket:path:options:)` |
| `list(path:options:)` | `list(bucket:path:options:)` |

### Type-shape parity

| Amplify | BucketKit |
|---|---|
| `StoragePath` (protocol) | `BucketPath` (protocol) |
| `StringStoragePath` | `StringBucketPath` |
| `StorageTask` / `StorageTransferTask` | `BucketTransferTask` |
| `StorageDownloadDataTask` etc. | `BucketDownloadDataTask` etc. |
| `progress` / `value` / `cancel` / `pause` / `resume` | identical |

### Deliberate deviations (documented, not changed)

1. **`bucket:` is a per-call argument, not configuration.** Amplify exposes
   `StorageBucket` and `StringStorageBucket` as `bucket:` overrides; we drop
   that whole shape and just take `bucket: String` directly per call. Reason:
   PRD §1/§7 — one client should serve many buckets without re-configuration,
   and an extra protocol seam adds nothing for the S3-only scope.
2. **No `StorageAccessLevel` (`.guest` / `.protected` / `.private`).** That
   abstraction is Cognito-coupled. PRD §2 ("not Amplify, no Cognito"). The
   path itself is the only level of indirection we want.
3. **No `handleBackgroundEvents(identifier:)`.** Background `URLSession` is
   PRD §15 out-of-scope for v1. Adding the entry point later is additive.
4. **No deprecated `key:` overload.** Amplify carries a deprecated
   `key: String` variant alongside `path:`; we ship only the `path:` form.
5. **Bucket-level operations** (`listBuckets`, `createBucket`, `deleteBucket`,
   `headBucket`) are BucketKit additions over Amplify's surface — Amplify
   delegates bucket lifecycle to AWS console / IaC. Documented in PRD §7.2.
6. **`getURL` returns `URL` directly.** Amplify wraps it in
   `StorageGetURLOperation`; we just return the value. No publisher, no
   operation handle.
7. **`HTTPMethod` is BucketKit's own enum.** Amplify routes presigning
   through plugin hooks; we expose method choice on `GetURLOptions.method`
   directly because GET / PUT / HEAD / DELETE is the entire grammar.
8. **No `transferAcceleration` / S3 Transfer Acceleration switch.** Amplify's
   `AWSS3StoragePlugin` exposes it; we don't model it (out-of-scope for v1).
   Callers can supply a custom `endpoint:` via
   `BucketConfiguration.custom(...)` if they really need it. Documented here
   so we revisit before 1.0 if user demand surfaces.

The naming is consistent enough that an Amplify user dropping into BucketKit
should recognize the call sites; the divergences above are all explainable
by the smaller scope and the absence of the Amplify category system.

---

## 5. Source compatibility policy

### Pre-1.0 (where we are now)

Minor versions (`0.x.y` → `0.(x+1).0`) **may break source compatibility** if
review uncovers a wrong call. We will:

- Document every break in the changelog with a migration note.
- Prefer `@available(*, deprecated, renamed: "…")` over hard removal whenever
  the new shape is expressible as a wrapper around the old.
- Avoid breaking any symbol marked Frozen v1 in this document — those are the
  symbols we have already convinced ourselves are correct.

### Post-1.0 (what tagging 1.0 commits us to)

We follow SemVer plus the relevant chunks of Swift evolution conventions:

**Non-breaking (additive) at minor versions:**
- New stored properties on Subject-to-additive-change structs, gated behind
  defaulted initializer parameters.
- New cases on `BucketClientError` and on Subject-to-additive-change enums
  (`StorageClass`, `ObjectACL`, `R2Jurisdiction`, `ServerSideEncryption`,
  `TransportBody`).
- New methods on `BucketClient` (extensions are inherently additive).
- New static factories on `BucketConfiguration`.

**Breaking (major-version only):**
- Removing or renaming any public symbol.
- Changing the type of an existing public stored property.
- Removing an enum case.
- Adding a stored property without a default to a struct whose memberwise
  initializer is public.
- Tightening generic constraints in a way that rejects existing call sites.

**Breaking even if "additive"** in the strict ABI sense — we still treat as
breaking because callers can encounter it:
- Adding a non-defaulted parameter to an existing public function.
- Adding a new associated type to a public protocol without a default.

The package has no `library evolution` mode and no `@frozen` annotations, so
ABI is not a concern — only source compatibility. Callers vendor / SwiftPM
the source.

---

## 6. Known follow-ups before v1.0

These are the items we want to resolve before tagging 1.0. None of them block
"the API is usable today"; they are stability-of-shape questions.

- **Pause/resume on `BucketTransferTask`.** Today `pause()` / `resume()` are
  no-ops above an advisory flag in `TransferTaskState`. Two paths:
  (a) keep the API and wire real semantics via `URLSessionTaskDelegate` (the
  motivating reason it's in the protocol at all), or
  (b) delete the affordance from the protocol and tell callers to cancel +
  retry instead. We shipped them in the protocol because Amplify has them;
  if we don't intend to land (a), removing them is a pre-1.0 break we should
  take while we still can.
- **`RetryPolicy` knobs.** The `Set<Int>` and `Set<String>` shape of
  `retryableStatuses` / `retryableServiceCodes` is friendly for tweaks but
  may be too permissive — e.g. a caller could add `200` and break the runner
  in confusing ways. Consider replacing with a more opinionated
  `RetryPolicy.classifier` closure or with named presets. Also consider
  whether per-operation retry overrides belong in v1 (today every op uses
  the client-wide policy).
- **`BucketConfiguration.extraHeaders` long-term shape.** Today it is the
  only escape hatch for headers we don't model directly. Pros: simple, one
  place to set vendor-specific headers across every call. Cons: forces
  configuration-level coupling for what is sometimes a per-operation
  concern. Decide before 1.0 whether to:
  (a) keep it and document the merge order (status quo), or
  (b) move to a per-operation `extraHeaders` field on each Options struct,
  or (c) ship both. The current merge contract ("operation wins on
  conflict") is documented and tested.
- **URL-builder duplication.** `Upload.makeObjectURL`,
  `Download.makeDownloadObjectURL`, `Remove.makeRemoveObjectURL`,
  `GetURL.makePresignBaseURL`, `Buckets.makeBucketRootURL` /
  `makeServiceRootURL`, and `MultipartURL.objectURL` are all variants of the
  same path-style-vs-virtual-hosted addressing. The duplication is on
  purpose for now (each was added with a separate signing path under test),
  but pre-1.0 they should collapse into one helper so a future addressing
  fix lands in one place. **Internal refactor; not a public API change.**
- **`MultipartUpload.uploadPart(_:partNumber:)` part-size validation.** The
  actor deliberately does not enforce S3's 5 MiB-per-non-final-part floor
  because it cannot know which part will be last. The auto-multipart path in
  `uploadFile` enforces it. Decide before 1.0 whether the explicit actor
  should grow a `complete(enforcePartSizeFloor: Bool = true)` knob, or
  whether the docs are enough. Today: docs only.
- **`BucketTransferTask` as a protocol with `<Output>`.** The primary
  associated type works, but the four concrete tasks are exposed as concrete
  structs; the protocol exists for documentation and shared shape. Consider
  whether the protocol should be public at all — keeping the four concrete
  task types as the public surface and demoting the protocol to internal
  would be a strictly-narrower contract.
- **`ObjectACL` portability story.** Surfaced because Amplify does, but the
  PRD §7 caveat ("AWS BucketOwnerEnforced rejects, R2 ignores, Spaces
  partial") means the v1 contract is "best-effort". Consider whether to
  leave the type as-is and just lean on its docstring, or to mark some
  cases unavailable on certain providers.
- **Transfer Acceleration (S3 TA).** Out of scope for v1 by PRD §15.
  Document the workaround (custom endpoint) in the README and reconsider for
  1.x.

---

## 7. Concrete deviations / inconsistencies found during the audit

These are findings — not action items — surfaced by walking every file. Each
is either resolved (decision recorded) or routed to §6.

1. **No `transferAcceleration` knob on `BucketConfiguration`.** Amplify
   exposes it; we don't. Decision: out of scope for v1, callers that need
   it can use `BucketConfiguration.custom(endpoint: …)`. See §6.
2. **URL-builder duplication across operations.** Each operation file ships
   its own `makeObjectURL` / `makeBucketRootURL` variant, with comments
   explaining the duplication is intentional pending a unification pass.
   Routed to §6 follow-up. Not a public-API issue.
3. **`BucketTransferTask` pause/resume are no-ops.** Confirmed by reading
   `TransferTaskState.pause()` / `resume()` — they only flip `isPaused`,
   which no operation observes. Documented at the protocol and the
   implementation. Routed to §6.
4. **`MultipartUpload.uploadPart` validates part-number but not part-size.**
   Confirmed by reading `validatePartNumber(_:)` and the type docstring.
   Documented at the type level. Routed to §6.
5. **`MultipartFileReader` is a `final class @unchecked Sendable`.** It is
   `internal`, not public — stability impact is zero; flagged here only so
   future readers don't think it's part of the public surface.
6. **`UploadDataOptions` and `UploadFileOptions` are field-identical.**
   Acknowledged in their docstrings; the duplication is deliberate (each
   side is documented next to its own type rather than via re-export). Not
   a stability concern.
7. **`DownloadDataOptions` and `DownloadFileOptions` are field-identical.**
   Same rationale as above. Not a stability concern.
8. **No symbol I'd argue should be `internal` instead of `public`.** The
   audit did not turn up a "this leaked" case. The closest call is
   `BucketTransferTask` (the protocol), which exists primarily for
   documentation — see §6.
9. **`URLSessionTransport.shared` is a static let, not a static var.** Any
   future need to swap at runtime would be a break; for v1 the immutable
   shape is the right call (matches `URLSession.shared`).
10. **`BucketConfiguration` stored properties are `var`, not `let`.** This
    means callers can mutate a configuration after construction. The current
    contract on `BucketClient` is that the configuration is captured once at
    `init` and never re-read across the actor boundary, so this is benign,
    but it's worth a docstring note before 1.0 that mutating the struct
    after passing it to a client has no effect.
11. **`HTTPTransport`'s three methods (`send` / `upload` / `download`) are
    Frozen v1.** No intent to add a `.stream` method until concrete demand
    surfaces; `TransportBody` already covers the in-memory and on-disk
    cases.

---

*End of stability note. Review in conjunction with `PRD.md` §17 (milestones)
and `issues/0026.md` (the issue this resolves).*
