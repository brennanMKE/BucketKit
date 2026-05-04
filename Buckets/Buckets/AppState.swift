import Foundation
import SwiftUI
import Combine
import Bucket

/// Provider presets the UI exposes. The "custom" entry is for MinIO
/// or any other S3-compatible gateway the user wants to point at.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case aws
    case r2
    case digitalOceanSpaces
    case minio
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aws: return "AWS S3"
        case .r2: return "Cloudflare R2"
        case .digitalOceanSpaces: return "DigitalOcean Spaces"
        case .minio: return "MinIO (path-style)"
        case .custom: return "Custom"
        }
    }
}

/// Plain-data form bound to the configuration sidebar. Kept off the
/// `BucketClient` actor so SwiftUI views can edit it on the main actor
/// without hops.
struct ConfigForm: Equatable {
    var provider: ProviderKind = .aws
    var endpoint: String = "https://s3.us-east-1.amazonaws.com"
    var region: String = "us-east-1"
    var accessKeyID: String = ""
    var secretAccessKey: String = ""
    var usePathStyle: Bool = false
    /// R2 only — the account ID, used to assemble the endpoint URL.
    var r2AccountID: String = ""

    /// Refreshes endpoint/region/usePathStyle defaults for the chosen
    /// provider. Called from the picker handler so users get sensible
    /// fields without manual editing for first-class providers.
    mutating func applyProviderDefaults() {
        switch provider {
        case .aws:
            endpoint = "https://s3.\(regionOrDefault).amazonaws.com"
            usePathStyle = false
        case .r2:
            let id = r2AccountID.isEmpty ? "<accountID>" : r2AccountID
            endpoint = "https://\(id).r2.cloudflarestorage.com"
            region = "auto"
            usePathStyle = false
        case .digitalOceanSpaces:
            let r = regionOrDefault
            endpoint = "https://\(r).digitaloceanspaces.com"
            region = "us-east-1"
            usePathStyle = false
        case .minio:
            endpoint = "http://localhost:9000"
            region = "us-east-1"
            usePathStyle = true
        case .custom:
            usePathStyle = true
        }
    }

    private var regionOrDefault: String {
        region.isEmpty ? "us-east-1" : region
    }

    /// Builds a `BucketConfiguration` from the current form values.
    /// Throws if the endpoint URL is malformed.
    func makeConfiguration() throws -> BucketConfiguration {
        guard let url = URL(string: endpoint), url.scheme != nil, url.host != nil else {
            throw BucketMacError.invalidEndpoint(endpoint)
        }
        return BucketConfiguration(
            endpoint: url,
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: nil,
            usePathStyle: usePathStyle
        )
    }
}

enum BucketMacError: LocalizedError {
    case invalidEndpoint(String)
    case noClient

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let s): return "Invalid endpoint URL: \(s)"
        case .noClient: return "Connect first — no BucketClient is configured."
        }
    }
}

/// Shape of the optional config file at `~/.config/bucketkit/test-app.json`.
/// All fields are optional so users can supply only what they need.
struct ConfigFile: Codable, Sendable {
    var provider: String?
    var endpoint: String?
    var region: String?
    var accessKeyID: String?
    var secretAccessKey: String?
    var r2AccountID: String?
    var usePathStyle: Bool?
}

/// Top-level state for the app. Owns the (optional) `BucketClient` and
/// surfaces high-level UI state (last error, currently selected bucket
/// for navigation between tabs).
@MainActor
final class AppState: ObservableObject {
    @Published var form = ConfigForm()
    @Published var client: BucketClient? = nil
    @Published var lastError: String? = nil
    @Published var selectedBucket: String = ""
    @Published var connectionLabel: String = "not connected"

    private let userDefaultsKey = "BucketMac.LastConfig.v1"

    init() {
        // Order: file first (an explicit per-developer override),
        // then UserDefaults as a "last session" fallback. Either way
        // the secret is never persisted in UserDefaults.
        if let fromFile = Self.loadConfigFile() {
            applyConfigFile(fromFile)
        } else {
            loadFromUserDefaults()
        }
    }

    // MARK: - Connect

    func connect() {
        do {
            let configuration = try form.makeConfiguration()
            let newClient = BucketClient(configuration: configuration)
            self.client = newClient
            self.connectionLabel = "\(form.provider.displayName) — \(configuration.endpoint.host ?? configuration.endpoint.absoluteString)"
            self.lastError = nil
            saveToUserDefaults()
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func disconnect() {
        self.client = nil
        self.connectionLabel = "not connected"
    }

    func report(_ error: Error) {
        self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: - Persistence (UserDefaults — secret intentionally omitted)

    private func loadFromUserDefaults() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: userDefaultsKey),
              let snapshot = try? JSONDecoder().decode(PersistedConfig.self, from: data) else {
            return
        }
        form.provider = ProviderKind(rawValue: snapshot.provider) ?? .aws
        form.endpoint = snapshot.endpoint
        form.region = snapshot.region
        form.accessKeyID = snapshot.accessKeyID
        form.r2AccountID = snapshot.r2AccountID
        form.usePathStyle = snapshot.usePathStyle
        // secretAccessKey deliberately not restored.
    }

    private func saveToUserDefaults() {
        let snapshot = PersistedConfig(
            provider: form.provider.rawValue,
            endpoint: form.endpoint,
            region: form.region,
            accessKeyID: form.accessKeyID,
            r2AccountID: form.r2AccountID,
            usePathStyle: form.usePathStyle
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private struct PersistedConfig: Codable {
        var provider: String
        var endpoint: String
        var region: String
        var accessKeyID: String
        var r2AccountID: String
        var usePathStyle: Bool
    }

    // MARK: - Config file (~/.config/bucketkit/test-app.json)

    static func configFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("bucketkit", isDirectory: true)
            .appendingPathComponent("test-app.json", isDirectory: false)
    }

    private static func loadConfigFile() -> ConfigFile? {
        let url = configFileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            return nil
        }
        return cfg
    }

    private func applyConfigFile(_ cfg: ConfigFile) {
        if let p = cfg.provider, let kind = ProviderKind(rawValue: p) {
            form.provider = kind
        }
        if let endpoint = cfg.endpoint { form.endpoint = endpoint }
        if let region = cfg.region { form.region = region }
        if let accessKeyID = cfg.accessKeyID { form.accessKeyID = accessKeyID }
        if let secret = cfg.secretAccessKey { form.secretAccessKey = secret }
        if let id = cfg.r2AccountID { form.r2AccountID = id }
        if let usePath = cfg.usePathStyle { form.usePathStyle = usePath }
    }
}
