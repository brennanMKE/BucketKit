import SwiftUI
import AppKit
import Bucket

// MARK: - Buckets

struct BucketsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var buckets: [BucketInfo] = []
    @State private var newBucketName: String = ""
    @State private var loading = false
    @State private var pendingDeleteName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Refresh") { Task { await refresh() } }
                    .disabled(appState.client == nil || loading)
                if loading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            HStack {
                TextField("Bucket name to create", text: $newBucketName)
                    .textFieldStyle(.roundedBorder)
                Button("Create") { Task { await create() } }
                    .disabled(appState.client == nil || newBucketName.isEmpty)
            }

            List(buckets, id: \.name) { bucket in
                HStack {
                    VStack(alignment: .leading) {
                        Text(bucket.name).font(.body.monospaced())
                        Text(bucket.creationDate, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use") {
                        appState.selectedBucket = bucket.name
                    }
                    Button("Delete", role: .destructive) {
                        pendingDeleteName = bucket.name
                    }
                }
            }
        }
        .padding()
        .alert(
            "Delete bucket?",
            isPresented: Binding(
                get: { pendingDeleteName != nil },
                set: { if !$0 { pendingDeleteName = nil } }
            ),
            actions: {
                Button("Cancel", role: .cancel) { pendingDeleteName = nil }
                Button("Delete", role: .destructive) {
                    if let name = pendingDeleteName {
                        pendingDeleteName = nil
                        Task { await delete(name) }
                    }
                }
            },
            message: {
                Text("This permanently deletes \"\(pendingDeleteName ?? "")\". The bucket must be empty.")
            }
        )
    }

    private func refresh() async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.listBuckets()
            self.buckets = result
        } catch {
            appState.report(error)
        }
    }

    private func create() async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        let name = newBucketName
        do {
            try await client.createBucket(name)
            newBucketName = ""
            await refresh()
        } catch {
            appState.report(error)
        }
    }

    private func delete(_ name: String) async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        do {
            try await client.deleteBucket(name)
            await refresh()
        } catch {
            appState.report(error)
        }
    }
}

// MARK: - Objects

struct ObjectsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var prefix: String = ""
    @State private var delimiter: String = ""
    @State private var objects: [BucketObject] = []
    @State private var commonPrefixes: [String] = []
    @State private var loading = false
    @State private var selectedKey: String? = nil
    @State private var headMetadata: ObjectMetadata? = nil

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Bucket", text: $appState.selectedBucket)
                        .textFieldStyle(.roundedBorder)
                    Button("Refresh") { Task { await refresh() } }
                        .disabled(appState.client == nil || appState.selectedBucket.isEmpty || loading)
                }
                HStack {
                    TextField("Prefix", text: $prefix)
                        .textFieldStyle(.roundedBorder)
                    TextField("Delimiter", text: $delimiter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                }
                if loading {
                    ProgressView().controlSize(.small)
                }
                List(selection: $selectedKey) {
                    if !commonPrefixes.isEmpty {
                        Section("Common prefixes") {
                            ForEach(commonPrefixes, id: \.self) { p in
                                Text(p).font(.body.monospaced())
                            }
                        }
                    }
                    Section("Objects") {
                        ForEach(objects, id: \.key) { obj in
                            HStack {
                                Text(obj.key).font(.body.monospaced())
                                Spacer()
                                Text("\(obj.size) B").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(obj.key as String?)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                Task { await head(obj.key) }
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Metadata").font(.headline)
                if let m = headMetadata {
                    metadataRow("key", m.key)
                    metadataRow("size", "\(m.size) B")
                    metadataRow("eTag", m.eTag)
                    metadataRow("lastModified", m.lastModified.formatted())
                    if let ct = m.contentType { metadataRow("contentType", ct) }
                    if let cc = m.cacheControl { metadataRow("cacheControl", cc) }
                    if let sc = m.storageClass { metadataRow("storageClass", sc.rawValue) }
                    if let v = m.versionID { metadataRow("versionID", v) }
                    if !m.metadata.isEmpty {
                        Divider()
                        Text("User metadata").font(.subheadline)
                        ForEach(Array(m.metadata.keys).sorted(), id: \.self) { k in
                            metadataRow(k, m.metadata[k] ?? "")
                        }
                    }
                } else {
                    Text("Double-click an object to load its HEAD metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .frame(width: 280)
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption.bold())
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func refresh() async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        loading = true
        defer { loading = false }
        var options = ListOptions(prefix: prefix.isEmpty ? nil : prefix)
        options.delimiter = delimiter.isEmpty ? nil : delimiter
        do {
            let page = try await client.list(
                bucket: appState.selectedBucket,
                options: options
            )
            self.objects = page.items
            self.commonPrefixes = page.commonPrefixes
        } catch {
            appState.report(error)
        }
    }

    private func head(_ key: String) async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        do {
            let m = try await client.headObject(
                bucket: appState.selectedBucket,
                path: .fromString(key)
            )
            self.headMetadata = m
            self.selectedKey = key
        } catch {
            appState.report(error)
        }
    }
}

// MARK: - Upload

struct UploadTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var key: String = ""
    @State private var localPath: String = ""
    @State private var bytesTransferred: Int64 = 0
    @State private var totalBytes: Int64? = nil
    @State private var lastResult: UploadResult? = nil
    @State private var inFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Bucket", text: $appState.selectedBucket)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Key", text: $key)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Local file", text: $localPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    if let url = FilePanels.chooseOpenFile() {
                        localPath = url.path
                        if key.isEmpty { key = url.lastPathComponent }
                    }
                }
            }
            HStack {
                Button("Upload") { Task { await upload() } }
                    .disabled(appState.client == nil || appState.selectedBucket.isEmpty || key.isEmpty || localPath.isEmpty || inFlight)
                if inFlight { ProgressView().controlSize(.small) }
            }
            if let total = totalBytes, total > 0 {
                ProgressView(value: Double(bytesTransferred), total: Double(total))
                Text("\(bytesTransferred) / \(total) bytes")
                    .font(.caption.monospaced())
            } else if inFlight {
                ProgressView()
            }
            if let r = lastResult {
                Divider()
                Text("Last upload").font(.headline)
                Text("key: \(r.key)").font(.caption.monospaced())
                Text("eTag: \(r.eTag)").font(.caption.monospaced()).textSelection(.enabled)
                if let v = r.versionID {
                    Text("versionID: \(v)").font(.caption.monospaced())
                }
            }
            Spacer()
        }
        .padding()
    }

    private func upload() async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        let local = URL(fileURLWithPath: localPath)
        let bucket = appState.selectedBucket
        let resolvedKey = key
        inFlight = true
        bytesTransferred = 0
        totalBytes = nil
        defer { inFlight = false }

        let task = await client.uploadFile(
            bucket: bucket,
            path: .fromString(resolvedKey),
            local: local,
            options: UploadFileOptions()
        )

        // Drive progress on the main actor by hopping back from
        // the AsyncStream iteration — TransferProgress is Sendable.
        let progressTask = Task { @MainActor in
            for await event in task.progress {
                self.bytesTransferred = event.bytesTransferred
                self.totalBytes = event.totalBytes
            }
        }

        do {
            let result = try await task.value
            self.lastResult = result
        } catch {
            appState.report(error)
        }
        progressTask.cancel()
    }
}

// MARK: - Download

struct DownloadTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var key: String = ""
    @State private var destinationPath: String = ""
    @State private var bytesTransferred: Int64 = 0
    @State private var totalBytes: Int64? = nil
    @State private var inFlight = false
    @State private var lastSavedURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Bucket", text: $appState.selectedBucket)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Key", text: $key)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Destination file", text: $destinationPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose...") {
                    let suggestion = (key as NSString).lastPathComponent
                    if let url = FilePanels.chooseSaveFile(suggestedName: suggestion.isEmpty ? "download.bin" : suggestion) {
                        destinationPath = url.path
                    }
                }
            }
            HStack {
                Button("Download") { Task { await download() } }
                    .disabled(appState.client == nil || appState.selectedBucket.isEmpty || key.isEmpty || destinationPath.isEmpty || inFlight)
                if inFlight { ProgressView().controlSize(.small) }
            }
            if let total = totalBytes, total > 0 {
                ProgressView(value: Double(bytesTransferred), total: Double(total))
                Text("\(bytesTransferred) / \(total) bytes")
                    .font(.caption.monospaced())
            } else if inFlight {
                ProgressView()
            }
            if let url = lastSavedURL {
                Divider()
                Text("Saved to:")
                Text(url.path).font(.caption.monospaced()).textSelection(.enabled)
            }
            Spacer()
        }
        .padding()
    }

    private func download() async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        let bucket = appState.selectedBucket
        let resolvedKey = key
        let destination = URL(fileURLWithPath: destinationPath)
        inFlight = true
        bytesTransferred = 0
        totalBytes = nil
        defer { inFlight = false }

        let task = await client.downloadFile(
            bucket: bucket,
            path: .fromString(resolvedKey),
            local: destination,
            options: DownloadFileOptions()
        )

        let progressTask = Task { @MainActor in
            for await event in task.progress {
                self.bytesTransferred = event.bytesTransferred
                self.totalBytes = event.totalBytes
            }
        }

        do {
            let savedURL = try await task.value
            self.lastSavedURL = savedURL
        } catch {
            appState.report(error)
        }
        progressTask.cancel()
    }
}

// MARK: - Presign

struct PresignTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var key: String = ""
    @State private var method: HTTPMethod = .get
    /// Slider range is 1s ... 7d (604_800s).
    @State private var expiresInSeconds: Double = 3600
    @State private var generatedURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Bucket", text: $appState.selectedBucket)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Key", text: $key)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("Method", selection: $method) {
                ForEach(HTTPMethod.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 4) {
                Text("Expires in: \(formatDuration(Int(expiresInSeconds)))")
                    .font(.callout)
                Slider(value: $expiresInSeconds, in: 1 ... 604_800)
            }

            HStack {
                Button("Generate URL") { Task { await generate() } }
                    .disabled(appState.client == nil || appState.selectedBucket.isEmpty || key.isEmpty)
                if let url = generatedURL {
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(url.absoluteString, forType: .string)
                    }
                }
            }

            if let url = generatedURL {
                Divider()
                Text("Generated URL (also copied to clipboard):").font(.caption)
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding()
    }

    private func generate() async {
        guard let client = appState.client else {
            appState.report(BucketMacError.noClient); return
        }
        do {
            let url = try await client.getURL(
                bucket: appState.selectedBucket,
                path: .fromString(key),
                options: GetURLOptions(
                    method: method,
                    expiresIn: .seconds(Int(expiresInSeconds))
                )
            )
            self.generatedURL = url
            // Copy on generation as the spec requires.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.absoluteString, forType: .string)
        } catch {
            appState.report(error)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        if seconds < 86_400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        return "\(days)d \(hours)h"
    }
}
