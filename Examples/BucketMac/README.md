# BucketMac

A small macOS SwiftUI app for **manual / exploratory testing** of
BucketKit. Not a shipping product — there's no code signing, no
sandbox, no Info.plist tuning. It exists so a human can drive the
package's full surface against a real (or local) S3-compatible service
without rebuilding.

This is the deliverable for [issues/0003.md](../../issues/0003.md).

## File layout

```
Examples/BucketMac/
├── Package.swift                           # standalone SwiftPM package
├── README.md                               # you are here
└── Sources/BucketMac/
    ├── BucketMacApp.swift                  # @main SwiftUI App
    ├── ContentView.swift                   # root layout + sidebar
    ├── AppState.swift                      # observable state, BucketClient owner
    ├── FilePanels.swift                    # NSOpenPanel / NSSavePanel wrappers
    └── Tabs.swift                          # Buckets / Objects / Upload / Download / Presign
```

## Why a separate package?

The root package (`Bucket`) is library-only and multi-platform. Adding
an `executable` macOS product to it would either restrict the root
package to macOS or force conditional product declarations. Keeping
BucketMac as a sibling SwiftPM package that depends on `../..` keeps
the root build matrix pristine and avoids polluting consumer Xcode
projects that integrate `Bucket` as a Swift package.

## Build and run

From this directory:

```sh
swift build
swift run BucketMac
```

Or open it in Xcode:

```sh
open Package.swift
```

The window titled **BucketKit Test App** should appear.

## Configuring credentials

Three options (use whichever is least painful for you):

1. **Type them into the sidebar** every launch.
2. **Saved in UserDefaults** (no secret) — endpoint, region, access key
   ID, provider, and addressing style are saved on `Connect` and
   restored next launch. The secret is **never** persisted; you re-enter
   it each session.
3. **A config file at `~/.config/bucketkit/test-app.json`**, loaded at
   launch. `.gitignore` your home directory's copy and you'll never
   commit secrets:

   ```json
   {
     "provider": "minio",
     "endpoint": "http://localhost:9000",
     "region": "us-east-1",
     "accessKeyID": "minioadmin",
     "secretAccessKey": "minioadmin",
     "usePathStyle": true
   }
   ```

   Recognized provider strings: `aws`, `r2`, `digitalOceanSpaces`,
   `minio`, `custom`. Every field is optional — anything you omit
   stays at its default.

## Pointing at MinIO

Spin up local MinIO from the repo root:

```sh
bash ../../scripts/minio-up.sh
```

In BucketMac, pick **MinIO (path-style)** from the provider dropdown.
Endpoint defaults to `http://localhost:9000`, region to `us-east-1`,
addressing to path-style. Type `minioadmin` / `minioadmin`
(or your override). Click **Connect**, then drive the tabs.

## What the tabs do

- **Buckets** — `listBuckets` / `createBucket` / `deleteBucket` (with
  a destructive-action confirmation alert).
- **Objects** — `list` with optional prefix and delimiter; double-click
  a key to fire `headObject` and inspect metadata in the side panel.
- **Upload** — picks a local file via `NSOpenPanel`, calls
  `uploadFile` (so files >= 100 MiB exercise the multipart path),
  and renders progress from `task.progress`.
- **Download** — picks a destination via `NSSavePanel`, calls
  `downloadFile`, renders the same progress stream.
- **Presign** — `getURL` for GET / PUT / HEAD / DELETE with an
  expires-in slider from 1 second to 7 days. The generated URL is
  copied to the clipboard automatically.

## Constraints honored

- Swift 6 strict concurrency (`swiftLanguageModes: [.v6]`).
- Foundation, SwiftUI, AppKit only — no third-party dependencies.
- The root `Package.swift` and `Sources/Bucket/*` are not modified.
- All `BucketClient` calls run inside `Task { ... }` and `await` across
  the actor boundary; SwiftUI views stay `MainActor`-isolated.
