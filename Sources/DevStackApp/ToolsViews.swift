import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PHP

struct PHPView: View {
    @EnvironmentObject private var model: AppModel

    private var runtimeID: String { model.configuration.defaultPHPRuntimeID }
    private var service: ServiceKind { ServiceKind(rawValue: runtimeID) ?? .php85 }
    private var running: Bool { model.serviceIsRunning(service) }

    private static let extensions: [(id: String, name: String, detail: String)] = [
        ("xdebug", "Xdebug", "Step debugging on 127.0.0.1:9003"),
        ("redis", "Redis", "Redis client"),
        ("imagick", "Imagick", "Image processing with ImageMagick"),
        ("pgsql", "PostgreSQL", "Native PostgreSQL functions"),
        ("pdo_pgsql", "PDO PostgreSQL", "PostgreSQL driver for PDO")
    ]

    var body: some View {
        Form {
            Section {
                Picker("Default version", selection: Binding(get: { runtimeID }, set: { id in Task { await model.selectPHP(id) } })) {
                    ForEach(model.phpRuntimes) { runtime in
                        Text(model.runtimeOptionTitle("PHP \(runtime.version)", id: runtime.id)).tag(runtime.id)
                            .disabled(!model.runtimeIsAvailable(runtime.id))
                    }
                }
                .disabled(model.isBusy || running)
                .help(running ? "Stop PHP before changing the default version." : "Used by new sites and the Terminal")
                LabeledContent("Status") {
                    if model.runtimeIsAvailable(runtimeID) {
                        StatusLabel(model.serviceState(service).phase)
                    } else {
                        Button("Install…") { model.selectedSection = .runtimes }
                    }
                }
            } footer: { SectionFooter {
                Text(running ? "Stop PHP to change the default version." : "New sites and the Terminal use the default version.")
            } }

            if runtimeID == "php-7.4" {
                Section {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", title: "Legacy runtime",
                              message: "PHP 7.4 no longer receives security fixes. Use it only for older projects that need it.")
                }
            }

            Section {
                ForEach(Self.extensions, id: \.id) { item in
                    let available = model.extensionIsAvailable(item.id, runtimeID: runtimeID)
                    Toggle(isOn: extensionBinding(item.id)) {
                        Text(item.name)
                        Text(available ? item.detail : "Not available for this version")
                    }
                    .disabled(!model.runtimeIsAvailable(runtimeID) || !available || model.isBusy)
                }
            } header: {
                Text("Extensions")
            } footer: { SectionFooter {
                Text("Turning an extension on or off restarts PHP.")
            } }

            Section("Build details") {
                DisclosureGroup("Sources, licenses and build information") {
                    ForEach(model.runtimeManifests.filter { $0.id == runtimeID || ($0.kind == .phpExtension && $0.dependencyPaths.contains(runtimeID)) }) { manifest in
                        RuntimeDetailsRow(manifest: manifest)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func extensionBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { model.extensionIsAvailable(name, runtimeID: runtimeID) && model.configuration.enabledExtensions[runtimeID]?.contains(name) == true },
                set: { enabled in Task { await model.setExtension(name, enabled: enabled, runtimeID: runtimeID) } })
    }
}

// MARK: - Database

struct DatabaseView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = DatabaseViewState()

    private var service: ServiceKind? { state.postgreSQL ? model.configuration.selectedPostgreSQL.service : model.configuration.selectedDatabase.service }
    private var running: Bool { service.map(model.serviceIsRunning) ?? false }
    private var webRunning: Bool { model.serviceIsRunning(.apache) || model.serviceIsRunning(.nginx) }
    private var engineName: String { state.postgreSQL ? "PostgreSQL" : "MySQL" }

    var body: some View {
        Form {
            Section("Services") {
                DatabaseServiceRows()
            }

            Section {
                Picker("Database", selection: $state.postgreSQL) {
                    Text("MySQL").tag(false)
                    Text("PostgreSQL").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)
                CopyableValueRow(label: "Host", value: "127.0.0.1")
                CopyableValueRow(label: "Port", value: String(state.postgreSQL ? model.configuration.ports.postgresqlListen : model.configuration.ports.mysqlListen))
                if state.postgreSQL { CopyableValueRow(label: "Database", value: "postgres") }
                CopyableValueRow(label: "Username", value: state.postgreSQL ? "devstack" : "root")
                CopyableValueRow(label: "Password", value: state.postgreSQL ? "devstack" : "root")
                CopyableValueRow(label: "Socket", value: state.postgreSQL ? model.paths.sockets.path : model.paths.sockets.appendingPathComponent("mysql.sock").path)
                LabeledContent("Web admin") {
                    HStack {
                        Button("Adminer") {
                            model.openURL(model.toolURL("adminer") + (state.postgreSQL
                                ? "/?pgsql=127.0.0.1%3A\(model.configuration.ports.postgresqlListen)&username=devstack&db=postgres"
                                : "/?server=127.0.0.1%3A\(model.configuration.ports.mysqlListen)&username=root"))
                        }
                        if !state.postgreSQL {
                            Button("phpMyAdmin") { model.openURL(model.toolURL("phpmyadmin")) }
                        }
                    }
                    .disabled(!webRunning || !running)
                }
            } header: {
                Text("Connection")
            } footer: { SectionFooter {
                if service == nil {
                    Text("Choose a \(engineName) version above to include it in the stack.")
                } else if !webRunning || !running {
                    Text("The web admin tools open while \(engineName) and the web server are running.")
                }
            } }

            Section {
                LabeledContent("SQL") {
                    HStack {
                        Button("Export…", action: exportDatabase)
                        Button("Import…", action: chooseImportFile)
                    }
                    .disabled(model.isBusy || !running)
                }
                if let backup = model.lastDatabaseBackup {
                    CopyableValueRow(label: "Last backup", value: backup.path)
                }
                LabeledContent("Backups") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.backups]) }
                }
            } header: {
                Text("Backup and restore")
            } footer: { SectionFooter {
                Text(running ? "Importing backs up \(engineName) first." : "Start \(engineName) to export or import SQL.")
            } }

            if !state.postgreSQL, service != nil {
                Section {
                    LabeledContent {
                        Button("Reset MySQL…", role: .destructive) { state.confirmingReset = true }.disabled(model.isBusy)
                    } label: {
                        Text("Reset")
                        Text("Backs up MySQL, archives its data folder and starts fresh.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Import \(state.pendingImport?.lastPathComponent ?? "SQL file")?", isPresented: $state.confirmingImport, presenting: state.pendingImport) { url in
            Button("Import", role: .destructive) { state.pendingImport = nil; Task { await model.importDatabase(from: url, postgreSQL: state.postgreSQL) } }
            Button("Cancel", role: .cancel) { state.pendingImport = nil }
        } message: { _ in
            Text("DevStack backs up \(engineName) first. The SQL file may overwrite existing data.")
        }
        .alert("Reset \(model.configuration.selectedDatabase.displayName)?", isPresented: $state.confirmingReset) {
            Button("Back Up and Reset", role: .destructive) { Task { await model.resetDatabase() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DevStack backs up MySQL, archives its data folder, and creates a clean database with root/root credentials.")
        }
    }

    private func exportDatabase() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.databaseBackupFilename(postgreSQL: state.postgreSQL)
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { Task { await model.exportDatabase(to: url, postgreSQL: state.postgreSQL) } }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { state.pendingImport = url; state.confirmingImport = true }
    }
}

@MainActor private final class DatabaseViewState: ObservableObject {
    @Published var postgreSQL = false
    @Published var pendingImport: URL?
    @Published var confirmingImport = false
    @Published var confirmingReset = false
}

// MARK: - Mail

struct MailpitView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = MailpitViewState()

    private var running: Bool { model.serviceIsRunning(.mailpit) }
    private var inboxURL: String { "http://127.0.0.1:\(model.configuration.ports.mailpitInboxListen)" }

    var body: some View {
        Form {
            Section {
                ServiceRow(title: "Mailpit", symbol: "envelope", detail: "Captures outgoing mail", service: .mailpit) {
                    Button("Open Inbox") { model.openURL(inboxURL) }.disabled(!running)
                } menuItems: {
                    Divider()
                    Button("Clear Inbox…", role: .destructive) { state.isConfirmingClear = true }.disabled(!running || model.isBusy)
                }
            }
            Section {
                CopyableValueRow(label: "Host", value: "127.0.0.1")
                CopyableValueRow(label: "Port", value: String(model.configuration.ports.mailpitSMTP))
                CopyableValueRow(label: "Inbox", value: inboxURL)
            } header: {
                Text("SMTP")
            } footer: { SectionFooter {
                Text("PHP's mail() sends here automatically. SMTP needs no authentication or encryption.")
            } }
            Section {
                LabeledContent {
                    Button("Clear Inbox…", role: .destructive) { state.isConfirmingClear = true }
                        .disabled(!running || model.isBusy)
                } label: {
                    Text("Messages")
                    Text("Deletes every captured message.")
                }
            }
        }
        .formStyle(.grouped)
        .alert("Clear the inbox?", isPresented: $state.isConfirmingClear) {
            Button("Clear Inbox", role: .destructive) { Task { await model.clearMailpit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message stored in Mailpit is deleted.")
        }
    }
}

@MainActor private final class MailpitViewState: ObservableObject { @Published var isConfirmingClear = false }

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = LogsViewState()

    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                Text(filteredContents.isEmpty ? (state.filter.isEmpty ? "No output yet." : "No lines match “\(state.filter)”.") : filteredContents)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(filteredContents.isEmpty ? .secondary : .primary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(12)
                    // At least the viewport, so short output starts at the top left.
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .searchable(text: $state.filter, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItem {
                Picker("Log", selection: $model.selectedLogFile) {
                    ForEach([LogFiles.Group.services, .sites, .other], id: \.self) { group in
                        let entries = state.entries.filter { $0.group == group }
                        if !entries.isEmpty {
                            Section(group.title) {
                                ForEach(entries) { entry in Text(entry.title).tag(entry.fileName) }
                            }
                        }
                    }
                }
                .help("Choose a log")
            }
            ToolbarItem {
                Toggle(isOn: $state.live) { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
                    .help(state.live ? "Following new output" : "Paused")
            }
            ToolbarItem {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filteredContents, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the shown output")
            }
            ToolbarItem {
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.paths.logs]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show the logs folder in Finder")
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.selectedLogFile) { _, _ in refresh() }
        .task(id: state.live) {
            guard state.live else { return }
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private var filteredContents: String {
        state.filter.isEmpty ? state.contents
            : state.contents.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(state.filter) }.joined(separator: "\n")
    }

    private func refresh() {
        let fileName = model.selectedLogFile
        Task {
            let snapshot = await model.logSnapshot(selected: fileName)
            // A slower read for an earlier selection must not overwrite the current one.
            guard fileName == model.selectedLogFile else { return }
            state.entries = snapshot.entries
            state.contents = snapshot.contents
        }
    }
}

private extension LogFiles.Group {
    var title: String {
        switch self {
        case .services: "Services"
        case .sites: "Sites"
        case .other: "Other"
        }
    }
}

@MainActor private final class LogsViewState: ObservableObject {
    @Published var entries: [LogFiles.Entry] = []
    @Published var contents = ""
    @Published var filter = ""
    @Published var live = true
}

// MARK: - Doctor

struct DoctorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = DoctorViewState()

    var body: some View {
        Group {
            if let report = model.diagnosticReport {
                Form {
                    if model.isRunningDoctor { progressSection }
                    Section {
                        LabeledContent("Results") {
                            HStack(spacing: 14) {
                                count(report, .info, "passed", "passed")
                                count(report, .warning, "warning", "warnings")
                                count(report, .error, "error", "errors")
                            }
                        }
                        LabeledContent("Checked", value: report.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        Toggle("Show only what needs attention", isOn: $state.attentionOnly)
                    }
                    let results = report.results.filter { !state.attentionOnly || $0.severity != .info }
                    Section("Checks") {
                        if results.isEmpty {
                            NoticeRow(symbol: "checkmark.seal.fill", title: "Nothing needs attention",
                                      message: "Every check passed. Turn off the filter to see them all.", tint: .green)
                        }
                        ForEach(results) { result in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(result.evidence).foregroundStyle(.secondary).textSelection(.enabled)
                                    if let remediation = result.remediation {
                                        Label(remediation, systemImage: "wrench.and.screwdriver").foregroundStyle(.primary)
                                    }
                                }
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            } label: {
                                Label {
                                    Text(result.title)
                                } icon: {
                                    Image(systemName: result.severity.symbol).foregroundStyle(result.severity.color)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else if model.isRunningDoctor {
                Form { progressSection }.formStyle(.grouped)
            } else {
                ContentUnavailableView {
                    Label("Check Your Stack", systemImage: "stethoscope")
                } description: {
                    Text("Doctor checks ports, runtimes, signatures, configuration and system integration.")
                } actions: {
                    Button("Run Checks") { Task { await model.runDoctor() } }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: exportBundle) { Label("Export Support Bundle…", systemImage: "square.and.arrow.up") }
                    .disabled(model.diagnosticReport == nil || model.isRunningDoctor)
                    .help("Save a support bundle with the report and logs")
            }
            ToolbarItem {
                Button { Task { await model.runDoctor() } } label: { Label("Run Checks", systemImage: "arrow.clockwise") }
                    .disabled(model.isRunningDoctor)
                    .help("Run every check again")
            }
        }
    }

    private var progressSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.diagnosticProgress ?? "Checking your stack…").foregroundStyle(.secondary)
            }
        }
    }

    private func count(_ report: DiagnosticReport, _ severity: DiagnosticSeverity, _ singular: String, _ plural: String) -> some View {
        let number = report.results.filter { $0.severity == severity }.count
        return Label("\(number) \(number == 1 ? singular : plural)", systemImage: severity.symbol)
            .foregroundStyle(severity.color)
            .labelStyle(.titleAndIcon)
    }

    private func exportBundle() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevStack-Support-\(Date().formatted(.iso8601.year().month().day())).zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { model.exportSupportBundle(to: url) }
    }
}

@MainActor private final class DoctorViewState: ObservableObject { @Published var attentionOnly = true }

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

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SettingsViewState()
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in Text(appearance.rawValue).tag(appearance) }
                }
                Toggle("Open DevStack at login", isOn: Binding(get: { model.configuration.startAtLogin },
                                                                set: { enabled in Task { await model.setStartAtLogin(enabled) } }))
            }

            Section {
                LabeledContent("Version") {
                    HStack(spacing: 10) {
                        Text(AppUpdater.currentVersion).foregroundStyle(.secondary)
                        Button("Check Now", action: updater.checkForUpdates).disabled(!updater.canCheckForUpdates)
                    }
                }
                Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                                                         set: { updater.automaticallyChecksForUpdates = $0 }))
                    .disabled(!updater.isAvailable)
            } header: {
                Text("Updates")
            } footer: { SectionFooter {
                if !updater.isAvailable { Text("Development builds don't check for updates.") }
            } }

            Section {
                LabeledContent("Helper") {
                    HStack(spacing: 10) {
                        if model.helperIsRegistered {
                            StatusLabel(title: model.helperInstalled ? "Ready" : "Not responding", color: model.helperInstalled ? .green : .orange)
                            if !model.helperInstalled {
                                Button("Repair…") { Task { await model.installHelper() } }.disabled(model.isBusy)
                            }
                            Button("Remove…", role: .destructive) { state.confirmRemove = true }
                                .disabled(model.isBusy || model.hasRunningServices)
                        } else {
                            StatusLabel(title: "Not set up", color: Color(nsColor: .tertiaryLabelColor))
                            Button(model.helperSetupState.actionTitle) { Task { await model.installHelper() } }.disabled(model.isBusy)
                        }
                    }
                }
                LabeledContent("HTTPS certificates") {
                    HStack(spacing: 10) {
                        StatusLabel(title: model.localCATrusted ? "Trusted" : "Not trusted", color: model.localCATrusted ? .green : .orange)
                        Button("Manage…") { model.selectedSection = .ssl }
                    }
                }
                LabeledContent("Setup") {
                    Button("Run Setup Assistant…") { model.presentSetupWizard() }.disabled(model.isBusy)
                }
                if model.isPreviewBuild {
                    LabeledContent {
                        Button("Open Signed Copy…", action: model.openApplicationsBuild)
                    } label: {
                        Text("Preview build")
                        Text("The helper works only with the signed copy in Applications.")
                    }
                }
            } header: {
                Text("System integration")
            } footer: { SectionFooter {
                Text(model.helperSetupState.message)
            } }

            PortsSection()
            LocalDNSSection()

            Section {
                LabeledContent("Runtimes") {
                    Button("Manage…") { model.selectedSection = .runtimes }
                }
                DisclosureGroup("Sources and licenses") {
                    ForEach(model.runtimeManifests.filter { $0.kind != .phpExtension }) { manifest in RuntimeDetailsRow(manifest: manifest) }
                }
            } header: {
                Text("Runtimes")
            }

            Section {
                CopyableValueRow(label: "App data", value: model.paths.applicationSupport.path)
                CopyableValueRow(label: "Runtimes", value: model.paths.importedRuntimes.path)
                CopyableValueRow(label: "Logs", value: model.paths.logs.path)
                LabeledContent("Shell") {
                    HStack {
                        Button("Copy Environment", action: model.copyManagedEnvironmentCommand)
                            .help("Copy a command that puts DevStack's tools on your shell's PATH")
                        Button("Show App Data") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.applicationSupport]) }
                    }
                }
            } header: {
                Text("Locations")
            } footer: { SectionFooter {
                Text("DevStack \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build") · Apple silicon · macOS 15 or later")
            } }
        }
        .formStyle(.grouped)
        .alert("Remove system integration?", isPresented: $state.confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.removeHelper() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DevStack removes its local domain mappings, port forwarding and certificate trust, then unregisters the helper. Your projects and databases stay in place.")
        }
    }
}

@MainActor private final class SettingsViewState: ObservableObject { @Published var confirmRemove = false }

struct RuntimeDetailsRow: View {
    let manifest: RuntimeManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(manifest.kind.displayName) \(manifest.version)")
                Spacer()
                Text("\(manifest.architecture) · \(manifest.license)").foregroundStyle(.secondary)
            }
            Text(manifest.source.url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("SHA-256 \(manifest.source.sha256)").font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            if let gate = manifest.build?.feasibilityGate {
                Text("Compatibility gate: \(gate)").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PortsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = PortsDraft()
    @State private var applied = ServicePorts()

    private var locked: Bool { model.hasRunningServices || model.isBusy }

    var body: some View {
        Section {
            portField("Web HTTP", text: $draft.webHTTP, fallback: ServicePorts.webHTTPFallback, isWebPort: true)
            portField("Web HTTPS", text: $draft.webHTTPS, fallback: ServicePorts.webHTTPSFallback, isWebPort: true)
            portField("MySQL", text: $draft.mysql, fallback: ServicePorts.mysqlFallback, isWebPort: false)
            portField("PostgreSQL", text: $draft.postgresql, fallback: ServicePorts.postgresqlFallback, isWebPort: false)
            portField("Mail SMTP", text: $draft.mailpitSMTP, fallback: ServicePorts.mailpitSMTPFallback, isWebPort: false)
            portField("Mail inbox", text: $draft.mailpitInbox, fallback: ServicePorts.mailpitInboxFallback, isWebPort: false)
            HStack {
                Button("Use 8080 and 8443") { useDevPorts() }.disabled(locked).help("Ports that work without the helper")
                Button("Use 80 and 443") { useStandardPorts() }.disabled(locked).help("Site addresses without a port number; needs the helper")
                Spacer()
                Button("Revert") { sync() }.disabled(locked || draft.ports == applied)
                Button("Apply") { Task { await apply() } }
                    .disabled(locked || draft.ports?.isValid != true || draft.ports == applied)
            }
        } header: {
            Text("Ports")
        } footer: { SectionFooter {
            if model.hasRunningServices {
                Text("Stop the stack to change ports.")
            } else if let message = validationMessage {
                Label(message, systemImage: validationIsError ? "exclamationmark.circle.fill" : "lock.shield")
                    .foregroundStyle(validationIsError ? Color.red : Color.orange)
            } else {
                Text("Ports below 1024 use the helper, which forwards them to unprivileged ports.")
            }
        } }
        .onAppear { sync() }
        .onChange(of: model.configuration.ports) { _, _ in sync() }
    }

    private func portField(_ title: String, text: Binding<String>, fallback: UInt16, isWebPort: Bool) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let value = UInt16(text.wrappedValue), value > 0, value < 1024 {
                    Text(verbatim: isWebPort && (value == 80 || value == 443) ? "Via the helper; no port in site URLs" : "Via the helper, to \(fallback)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField(title, text: text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(locked)
            }
        } label: {
            Text(title)
        }
    }

    private var validationMessage: String? {
        guard let ports = draft.ports else { return "Enter a port from 1 to 65535 for every service." }
        if !ports.reservedRequests.isEmpty { return "Port 22 is reserved and cannot be assigned to a DevStack service." }
        if !ports.collisions.isEmpty { return "These ports conflict: \(ports.collisions.map(String.init).joined(separator: ", "))." }
        if ports.requiresHelper, !model.helperInstalled { return "Set up the helper to use ports below 1024." }
        return nil
    }

    private var validationIsError: Bool {
        guard let ports = draft.ports else { return true }
        return !ports.isValid
    }

    private func useDevPorts() {
        draft.webHTTP = String(ServicePorts.webHTTPFallback)
        draft.webHTTPS = String(ServicePorts.webHTTPSFallback)
    }

    private func useStandardPorts() {
        draft.webHTTP = "80"
        draft.webHTTPS = "443"
    }

    private func sync() {
        applied = model.configuration.ports
        draft = PortsDraft(model.configuration.ports)
    }

    private func apply() async {
        guard let ports = draft.ports else { return }
        await model.updatePorts(ports)
        sync()
    }
}

private struct PortsDraft: Equatable {
    var webHTTP = ""
    var webHTTPS = ""
    var mysql = ""
    var postgresql = ""
    var mailpitSMTP = ""
    var mailpitInbox = ""

    init() {}
    init(_ ports: ServicePorts) {
        webHTTP = String(ports.webHTTP)
        webHTTPS = String(ports.webHTTPS)
        mysql = String(ports.mysql)
        postgresql = String(ports.postgresql)
        mailpitSMTP = String(ports.mailpitSMTP)
        mailpitInbox = String(ports.mailpitInbox)
    }

    var ports: ServicePorts? {
        guard let webHTTP = UInt16(webHTTP), let webHTTPS = UInt16(webHTTPS), let mysql = UInt16(mysql),
              let postgresql = UInt16(postgresql), let mailpitSMTP = UInt16(mailpitSMTP), let mailpitInbox = UInt16(mailpitInbox),
              [webHTTP, webHTTPS, mysql, postgresql, mailpitSMTP, mailpitInbox].allSatisfy({ $0 > 0 }) else { return nil }
        return ServicePorts(webHTTP: webHTTP, webHTTPS: webHTTPS, mysql: mysql, postgresql: postgresql, mailpitSMTP: mailpitSMTP, mailpitInbox: mailpitInbox)
    }
}

private struct LocalDNSSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            Toggle("Serve DevStack hostnames to this network", isOn: Binding(
                get: { model.configuration.localNetworkAccess },
                set: { enabled in Task { await model.setLocalNetworkAccess(enabled) } }))
                .disabled(model.isBusy || !model.helperInstalled)
            if let address = model.localNetworkAddress {
                CopyableValueRow(label: "DNS address", value: address)
            }
            LabeledContent("Device setup") {
                Button("Show Instructions…") { model.selectedSection = .localDNS }
            }
        } header: {
            Text("Local DNS")
        } footer: { SectionFooter {
            Text(footer)
        } }
    }

    private var footer: String {
        guard model.helperInstalled else { return "Needs the helper. Set it up under System integration." }
        guard model.localNetworkAddress != nil else { return "Connect to Wi-Fi or Ethernet to serve other devices." }
        return "Phones and other devices can use this Mac as their DNS server for DevStack hostnames. Every other domain resolves as usual."
    }
}
