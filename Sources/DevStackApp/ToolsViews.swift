import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

struct PHPView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            runtimeSection(id: "php-8.5", title: "PHP 8.5.11", legacy: false)
            runtimeSection(id: "php-7.4", title: "PHP 7.4.33", legacy: true)
        }
        .formStyle(.grouped)
        .navigationTitle("PHP")
    }

    @ViewBuilder
    private func runtimeSection(id: String, title: String, legacy: Bool) -> some View {
        Section {
            if legacy {
                Label("End-of-life runtime; availability depends on the native OpenSSL 3 regression gate.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(["xdebug", "redis", "imagick"], id: \.self) { extensionName in
                Toggle(extensionName.capitalized, isOn: extensionBinding(extensionName, runtimeID: id))
            }
            Text("Xdebug listens on 127.0.0.1:9003 and is disabled by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text(title)
                if legacy { Text("EOL").foregroundStyle(.orange) }
            }
        }
    }

    private func extensionBinding(_ name: String, runtimeID: String) -> Binding<Bool> {
        Binding(
            get: { model.configuration.enabledExtensions[runtimeID]?.contains(name) == true },
            set: { enabled in
                Task { await model.setExtension(name, enabled: enabled, runtimeID: runtimeID) }
            }
        )
    }
}

struct DatabaseView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Database engine") {
                Picker("Active engine", selection: databaseBinding) {
                    ForEach(DatabaseEngine.allCases, id: \.rawValue) { engine in
                        Text(engine.displayName + (engine.isLegacy ? " — EOL" : ""))
                            .tag(engine)
                    }
                }
                Text("Each engine has an independent data directory. Switching never upgrades or shares data files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.configuration.selectedDatabase.isLegacy {
                Section {
                    Label("MySQL 5.7 is end-of-life and should only be used for legacy compatibility.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Local connection") {
                LabeledContent("Host", value: "127.0.0.1")
                LabeledContent("Port", value: "3306")
                LabeledContent("Username", value: "root")
                LabeledContent("Password", value: "root")
                Text("These credentials are intentionally convenient and are only appropriate for loopback-only development.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section {
                Button("Open phpMyAdmin", systemImage: "safari") {
                    model.openURL("https://phpmyadmin.devstack.test")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Database")
    }

    private var databaseBinding: Binding<DatabaseEngine> {
        Binding(
            get: { model.selectedDatabaseBinding },
            set: { model.selectedDatabaseBinding = $0 }
        )
    }
}

struct MailpitView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Captured mail") {
                LabeledContent("SMTP", value: "127.0.0.1:1025")
                LabeledContent("Web UI", value: "https://mailpit.devstack.test")
                Text("External SMTP relay and message release are disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open Mailpit", systemImage: "safari") {
                        model.openURL("https://mailpit.devstack.test")
                    }
                    Button("Clear Captured Mail", systemImage: "trash", role: .destructive) {
                        Task { await model.clearMailpit() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Mailpit")
    }
}

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var viewState = LogsViewState()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Service", selection: $viewState.selectedService) {
                    ForEach(ServiceKind.allCases) { service in
                        Text(service.displayName).tag(service)
                    }
                }
                .frame(width: 260)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                Button("Reveal Logs", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.logs])
                }
            }
            .padding()

            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(viewState.contents)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
            .background(.black.opacity(0.04))
        }
        .navigationTitle("Logs")
        .onAppear(perform: refresh)
        .onChange(of: viewState.selectedService) { _, _ in refresh() }
    }

    private func refresh() {
        viewState.contents = model.logContents(for: viewState.selectedService)
    }
}

@MainActor
private final class LogsViewState: ObservableObject {
    @Published var selectedService: ServiceKind = .apache
    @Published var contents = "No log output yet."
}

struct DoctorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Doctor checks ports, signatures, architecture, paths, configuration, and local state.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export Support Bundle", systemImage: "square.and.arrow.up") {
                    exportBundle()
                }
                .disabled(model.diagnosticReport == nil)
                Button("Run Doctor", systemImage: "stethoscope") {
                    Task { await model.runDoctor() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()

            if let report = model.diagnosticReport {
                List(report.results) { result in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: result.severity.symbol)
                            .foregroundStyle(result.severity.color)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.headline)
                            Text(result.evidence).foregroundStyle(.secondary).textSelection(.enabled)
                            if let remediation = result.remediation {
                                Text(remediation).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            } else {
                ContentUnavailableView("No Diagnostic Report", systemImage: "stethoscope", description: Text("Run Doctor to inspect this DevStack installation."))
            }
        }
        .navigationTitle("Doctor")
    }

    private func exportBundle() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevStack-Support-\(ISO8601DateFormatter().string(from: Date())).json"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportSupportBundle(to: url)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("System integration") {
                LabeledContent("Privileged helper") {
                    Text(model.helperInstalled ? "Installed" : "Not installed")
                        .foregroundStyle(model.helperInstalled ? .green : .secondary)
                }
                HStack {
                    Button("Install Helper") { Task { await model.installHelper() } }
                        .disabled(model.helperInstalled)
                    Button("Remove Managed System State", role: .destructive) {
                        Task { await model.removeHelper() }
                    }
                    .disabled(!model.helperInstalled)
                }
                Toggle("Start at login", isOn: .constant(model.configuration.startAtLogin))
                    .disabled(true)
                Text("Helper installation and login-item registration become available in a signed app build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Data locations") {
                LabeledContent("Application Support", value: model.paths.applicationSupport.path)
                LabeledContent("Built-in runtimes", value: model.paths.builtInRuntimes.path)
                Button("Reveal Application Support") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.applicationSupport])
                }
            }
            Section("Runtime policy") {
                Text("DevStack never downloads runtime packs. Importable packs must be signed and supplied from a local file or removable media.")
                    .foregroundStyle(.secondary)
                Button("Import Signed Runtime Pack…", systemImage: "shippingbox.and.arrow.backward") {
                    chooseRuntimePack()
                }
                .disabled(model.isBusy)
                if !model.configuration.importedRuntimeIDs.isEmpty {
                    LabeledContent("Imported") {
                        Text(model.configuration.importedRuntimeIDs.joined(separator: ", "))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func chooseRuntimePack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a signed .devstack-runtime archive."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importRuntimePack(from: url) }
        }
    }
}

private extension DiagnosticSeverity {
    var symbol: String {
        switch self {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
