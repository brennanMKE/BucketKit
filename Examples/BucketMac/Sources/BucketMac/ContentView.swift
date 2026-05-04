import SwiftUI

/// Root layout: configuration sidebar on the leading edge, an
/// operations tab view trailing.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: OperationTab = .buckets

    var body: some View {
        HSplitView {
            ConfigurationSidebar()
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)

            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(OperationTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()

                Divider()

                Group {
                    switch selectedTab {
                    case .buckets:  BucketsTab()
                    case .objects:  ObjectsTab()
                    case .upload:   UploadTab()
                    case .download: DownloadTab()
                    case .presign:  PresignTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 560)
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { if !$0 { appState.lastError = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { appState.lastError = nil }
            },
            message: {
                Text(appState.lastError ?? "")
            }
        )
    }
}

enum OperationTab: String, CaseIterable, Identifiable, Hashable {
    case buckets, objects, upload, download, presign

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buckets:  return "Buckets"
        case .objects:  return "Objects"
        case .upload:   return "Upload"
        case .download: return "Download"
        case .presign:  return "Presign"
        }
    }
}

// MARK: - Configuration sidebar

struct ConfigurationSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.title3.bold())

            Picker("Provider", selection: providerBinding) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            if appState.form.provider == .r2 {
                LabeledTextField(
                    label: "Account ID",
                    text: Binding(
                        get: { appState.form.r2AccountID },
                        set: { newValue in
                            appState.form.r2AccountID = newValue
                            appState.form.applyProviderDefaults()
                        }
                    )
                )
            }

            LabeledTextField(label: "Endpoint", text: $appState.form.endpoint)
            LabeledTextField(label: "Region", text: $appState.form.region)
            LabeledTextField(label: "Access Key ID", text: $appState.form.accessKeyID)

            VStack(alignment: .leading, spacing: 4) {
                Text("Secret Access Key").font(.callout)
                SecureField("", text: $appState.form.secretAccessKey)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Use path-style addressing", isOn: $appState.form.usePathStyle)

            HStack {
                Button("Connect") { appState.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(appState.form.accessKeyID.isEmpty || appState.form.secretAccessKey.isEmpty)
                Button("Disconnect") { appState.disconnect() }
                    .disabled(appState.client == nil)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.client == nil ? Color.gray : Color.green)
                    .frame(width: 8, height: 8)
                Text(appState.connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.top, 4)

            Text("Persistence")
                .font(.caption.bold())
            Text("Endpoint, region, access key ID, and provider are saved in UserDefaults across launches. The secret is **never** persisted; re-enter it each session.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("To prefill from a config file, drop one at:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(AppState.configFileURL().path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { appState.form.provider },
            set: { newValue in
                appState.form.provider = newValue
                appState.form.applyProviderDefaults()
            }
        )
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }
}
