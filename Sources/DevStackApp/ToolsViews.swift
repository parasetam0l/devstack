import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

struct PHPView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        WorkspacePage {
            PageHeading(title: "PHP", subtitle: "Choose the default runtime and manage its extensions.")
            runtimePanel(id: model.configuration.defaultPHPRuntimeID, legacy: model.configuration.defaultPHPRuntimeID == "php-7.4")
            SurfacePanel(title: "Runtime details") {
                DisclosureGroup("Sources, licenses, and build information") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.runtimeManifests.filter { $0.id == model.configuration.defaultPHPRuntimeID || ($0.kind == .phpExtension && $0.dependencyPaths.contains(model.configuration.defaultPHPRuntimeID)) }) { manifest in
                            RuntimeDetailsRow(manifest: manifest)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 12))
            }
        }
    }

    private func runtimePanel(id: String, legacy: Bool) -> some View {
        let installed = model.runtimeIsAvailable(id)
        let phase = model.serviceState(ServiceKind(rawValue: id) ?? .php85).phase
        return SurfacePanel {
            HStack(spacing: 8) {
                FeatureIcon(symbol: "chevron.left.forwardslash.chevron.right", color: legacy ? .orange : DevStackDesign.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default runtime").font(.system(size: 13, weight: .semibold))
                    Text("Used for new sites and the managed Terminal").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(
                    title: phase == .running ? "Running" : installed ? (legacy ? "Legacy" : "Installed") : "Not installed",
                    color: phase == .running ? phase.color : installed ? (legacy ? .orange : DevStackDesign.accent) : .secondary,
                    dot: phase == .running,
                    dotColor: phase.dotColor
                )
                PHPDefaultRuntimePicker()
            }
            if legacy {
                InfoNotice(symbol: "exclamationmark.triangle", title: "Legacy compatibility", message: "PHP 7.4 no longer receives security fixes. Use it only for older projects that need it.", color: .orange)
            }
            Divider()
            HStack {
                Text("Extensions").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Changes restart PHP automatically.").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array([("xdebug", "Xdebug", "Step debugging · 127.0.0.1:9003"), ("redis", "Redis", "Redis client"), ("imagick", "Imagick", "ImageMagick image processing"), ("pgsql", "PostgreSQL", "Native PostgreSQL functions"), ("pdo_pgsql", "PDO PostgreSQL", "PostgreSQL driver for PDO")].enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        Text(item.1).font(.system(size: 12, weight: .medium)).frame(width: 115, alignment: .leading)
                        Text(model.extensionIsAvailable(item.0, runtimeID: id) ? item.2 : "Not installed for this runtime").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Toggle(item.1, isOn: extensionBinding(item.0, runtimeID: id)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(!model.runtimeIsAvailable(id) || !model.extensionIsAvailable(item.0, runtimeID: id) || model.isBusy)
                    }.padding(.vertical, 6)
                }
            }
        }
    }
    private func extensionBinding(_ name: String, runtimeID: String) -> Binding<Bool> {
        Binding(get: { model.extensionIsAvailable(name, runtimeID: runtimeID) && model.configuration.enabledExtensions[runtimeID]?.contains(name) == true }, set: { enabled in Task { await model.setExtension(name, enabled: enabled, runtimeID: runtimeID) } })
    }
}

/// Segmented default-runtime picker for the PHP page: all installed versions
/// are visible at a glance instead of hidden behind a menu.
private struct PHPDefaultRuntimePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let running = model.serviceIsRunning(ServiceKind(rawValue: model.configuration.defaultPHPRuntimeID) ?? .php85)
        return Picker("PHP", selection: Binding(
            get: { model.configuration.defaultPHPRuntimeID },
            set: { id in Task { await model.selectPHP(id) } }
        )) {
            ForEach(model.availablePHPRuntimes) { runtime in
                Text(runtime.version.split(separator: ".").prefix(2).joined(separator: ".")).tag(runtime.id)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(model.isBusy || running)
        .help(running ? "Stop PHP before changing the default version." : "Choose the default PHP runtime.")
    }
}

struct DatabaseView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = DatabaseViewState()
    private var service: ServiceKind? { state.postgreSQL ? model.configuration.selectedPostgreSQL.service : model.configuration.selectedDatabase.service }
    private var running: Bool { service.map(model.serviceIsRunning) ?? false }
    private var webRunning: Bool { model.serviceIsRunning(.apache) || model.serviceIsRunning(.nginx) }
    var body: some View {
        WorkspacePage {
            HStack {
                PageHeading(title: "Database", subtitle: "Connections, backups and engine selection.")
                Spacer()
                Button("Open Adminer", systemImage: "arrow.up.right") {
                    model.openURL(model.toolURL("adminer") + (state.postgreSQL ? "/?pgsql=127.0.0.1%3A\(model.configuration.ports.postgresqlListen)&username=devstack&db=postgres" : "/?server=127.0.0.1%3A\(model.configuration.ports.mysqlListen)&username=root"))
                }.buttonStyle(DevStackGlassButtonStyle()).disabled(!webRunning || !running)
                if !state.postgreSQL {
                    Button("Open phpMyAdmin", systemImage: "arrow.up.right") { model.openURL(model.toolURL("phpmyadmin")) }
                        .buttonStyle(DevStackGlassButtonStyle()).disabled(!webRunning || !running)
                }
            }
            DatabaseServiceControl()
            HStack(spacing: 8) {
                Text("Tools for").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Picker("Connection and backup tools", selection: $state.postgreSQL) {
                    Text("MySQL").tag(false)
                    Text("PostgreSQL").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(model.isBusy)
                Spacer()
            }.padding(.horizontal, 4)
            SurfacePanel(title: "Connection") {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 8) {
                        CopyValueRow(label: "Host", value: "127.0.0.1")
                        CopyValueRow(label: "Port", value: state.postgreSQL ? String(model.configuration.ports.postgresqlListen) : String(model.configuration.ports.mysqlListen))
                        if state.postgreSQL { CopyValueRow(label: "Database", value: "postgres") }
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 8) {
                        CopyValueRow(label: "Username", value: state.postgreSQL ? "devstack" : "root")
                        CopyValueRow(label: "Password", value: state.postgreSQL ? "devstack" : "root")
                    }.frame(maxWidth: .infinity)
                }
                DisclosureGroup("Unix socket") {
                    CopyValueRow(label: "Socket", value: state.postgreSQL ? model.paths.sockets.path : model.paths.sockets.appendingPathComponent("mysql.sock").path).padding(.top, 6)
                }.font(.system(size: 11))
                if service == nil { Text("Choose a version to include this database in Start Stack.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            SurfacePanel(title: "Backup and restore", subtitle: "Import creates a backup before changing your data.") {
                HStack(spacing: 8) {
                    Button("Export Databases…", systemImage: "square.and.arrow.up", action: exportDatabase).buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy || !running)
                    Button("Import SQL…", systemImage: "arrow.down.doc", action: chooseImportFile).buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy || !running)
                    Spacer()
                    Button("Show Backups", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.backups]) }.buttonStyle(.borderless)
                }
                if !running { Text("Start this database to export or import SQL.").font(.system(size: 11)).foregroundStyle(.secondary) }
                if let backup = model.lastDatabaseBackup { Divider(); CopyValueRow(label: "Last backup", value: backup.path) }
            }
            if !state.postgreSQL, service != nil {
                HStack {
                    Text("Reset archives the data directory and starts fresh.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset MySQL…", role: .destructive) { state.confirmingReset = true }.disabled(model.isBusy)
                }.padding(.horizontal, 4)
            }
        }
        .alert("Import SQL file?", isPresented: $state.confirmingImport, presenting: state.pendingImport) { url in
            Button("Import", role: .destructive) { state.pendingImport = nil; Task { await model.importDatabase(from: url, postgreSQL: state.postgreSQL) } }
            Button("Cancel", role: .cancel) { state.pendingImport = nil }
        } message: { url in Text("DevStack backs up \(state.postgreSQL ? "PostgreSQL" : "MySQL") before importing \(url.lastPathComponent). The SQL file may overwrite existing data.") }
        .alert("Reset \(model.configuration.selectedDatabase.displayName)?", isPresented: $state.confirmingReset) {
            Button("Back Up and Reset", role: .destructive) { Task { await model.resetDatabase() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("DevStack backs up MySQL, archives its data directory, and creates a clean database with root/root credentials.") }
    }
    private func exportDatabase() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = model.databaseBackupFilename(postgreSQL: state.postgreSQL)
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { Task { await model.exportDatabase(to: url, postgreSQL: state.postgreSQL) } }
    }
    private func chooseImportFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { state.pendingImport = url; state.confirmingImport = true }
    }
}

@MainActor private final class DatabaseViewState: ObservableObject {
    @Published var postgreSQL = false
    @Published var pendingImport: URL?
    @Published var confirmingImport = false
    @Published var confirmingReset = false
}

struct MailpitView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = MailpitViewState()
    var body: some View {
        WorkspacePage {
            PageHeading(title: "Mail Inbox", subtitle: "Captured outgoing mail.")
            SurfacePanel {
                HStack(spacing: 8) {
                    FeatureIcon(symbol: "tray")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mailpit").font(.system(size: 13, weight: .semibold))
                        Text(verbatim: "SMTP capture on port \(model.configuration.ports.mailpitSMTP).").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(title: model.serviceIsRunning(.mailpit) ? "Capturing mail" : "Stopped", color: model.serviceIsRunning(.mailpit) ? DevStackDesign.accent : .secondary, dot: true)
                    Button(model.serviceIsRunning(.mailpit) ? "Stop" : "Start") {
                        Task {
                            if model.serviceIsRunning(.mailpit) { await model.stopService(.mailpit) }
                            else { await model.startService(.mailpit) }
                        }
                    }.buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
                        .accessibilityLabel(model.serviceIsRunning(.mailpit) ? "Stop Mailpit" : "Start Mailpit")
                }
                HStack {
                    Button("Open Inbox", systemImage: "arrow.up.right") { model.openURL("http://127.0.0.1:\(model.configuration.ports.mailpitInboxListen)") }
                        .buttonStyle(DevStackGlassButtonStyle()).controlSize(.small).disabled(!model.serviceIsRunning(.mailpit))
                    Spacer()
                    Button("Clear Inbox…", systemImage: "trash", role: .destructive) { state.isConfirmingClear = true }
                        .disabled(!model.serviceIsRunning(.mailpit) || model.isBusy)
                }
            }
            SurfacePanel(title: "SMTP connection") {
                CopyValueRow(label: "SMTP host", value: "127.0.0.1")
                CopyValueRow(label: "SMTP port", value: String(model.configuration.ports.mailpitSMTP))
                CopyValueRow(label: "Inbox URL", value: "http://127.0.0.1:\(model.configuration.ports.mailpitInboxListen)")
                Divider()
                Text("PHP mail() is configured automatically. SMTP requires no authentication or encryption.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .alert("Clear the local inbox?", isPresented: $state.isConfirmingClear) {
            Button("Clear Inbox", role: .destructive) { Task { await model.clearMailpit() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("All messages stored in Mailpit will be deleted.") }
    }
}
@MainActor private final class MailpitViewState: ObservableObject { @Published var isConfirmingClear = false }

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = LogsViewState()
    var body: some View {
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PageHeading(title: "Logs", subtitle: "Service output.")
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.paths.logs]) } label: { Image(systemName: "folder") }.buttonStyle(DevStackGlassButtonStyle()).help("Show logs folder").accessibilityLabel("Show logs folder")
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(DevStackGlassButtonStyle()).help("Refresh logs").accessibilityLabel("Refresh logs")
            }
            HStack(spacing: 8) {
                Picker("Service", selection: $model.selectedLogService) {
                    ForEach(ServiceKind.allCases) { service in Text(service.displayName).tag(service) }
                }.pickerStyle(.menu).fixedSize()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter output", text: $state.filter).textFieldStyle(.plain)
                }.padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).frame(maxWidth: 300)
                Spacer()
                Toggle("Live", isOn: $state.live).toggleStyle(.switch).controlSize(.small)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(filteredContents, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy displayed output").accessibilityLabel("Copy displayed output")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(currentPhase.color).frame(width: 6, height: 6)
                    Text("\(model.selectedLogService.rawValue).log").font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Text(state.live ? "LIVE" : "PAUSED").font(.system(size: 9, weight: .medium)).tracking(1)
                }.foregroundStyle(.white.opacity(0.5)).padding(8).background(.white.opacity(0.025))
                Divider().overlay(.white.opacity(0.06))
                ScrollView([.horizontal, .vertical]) {
                    Text(filteredContents.isEmpty ? (state.filter.isEmpty ? "No log output yet." : "No lines match your filter.") : filteredContents)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.83)).lineSpacing(2)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
                }
            }.background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
        }.padding(14).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.background(WorkspaceBackground()).controlSize(.small).font(.system(size: 12))
        .onAppear(perform: refresh)
        .onChange(of: model.selectedLogService) { _, _ in refresh() }
        .task(id: state.live) {
            guard state.live else { return }
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
    private var currentPhase: ServicePhase { model.serviceStates.first { $0.service == model.selectedLogService }?.phase ?? .stopped }
    private var filteredContents: String {
        state.filter.isEmpty ? state.contents : state.contents.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains(state.filter) }.joined(separator: "\n")
    }
    private func refresh() { state.contents = model.logContents(for: model.selectedLogService) }
}
@MainActor private final class LogsViewState: ObservableObject {
    @Published var contents = "No log output yet."
    @Published var filter = ""
    @Published var live = true
}

struct DoctorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = DoctorViewState()
    var body: some View {
        WorkspacePage {
            HStack {
                PageHeading(title: "Doctor", subtitle: "Health checks and support bundle.")
                Spacer()
                Button("Export…", systemImage: "square.and.arrow.up", action: exportBundle).buttonStyle(DevStackGlassButtonStyle()).disabled(model.diagnosticReport == nil || model.isRunningDoctor)
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    if model.isRunningDoctor { HStack { ProgressView().controlSize(.mini); Text("Checking…") } }
                    else { Label("Run Checks", systemImage: "stethoscope") }
                }.buttonStyle(DevStackProminentButtonStyle()).disabled(model.isRunningDoctor)
            }
            if model.isRunningDoctor {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.diagnosticProgress ?? "Checking your stack…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(10).background(DevStackDesign.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            if let report = model.diagnosticReport {
                HStack(spacing: 8) {
                    diagnosticCount(report, severity: .info, title: "Passed")
                    diagnosticCount(report, severity: .warning, title: "Warnings")
                    diagnosticCount(report, severity: .error, title: "Errors")
                }
                HStack {
                    Text("Checked \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Needs attention only", isOn: $state.attentionOnly).toggleStyle(.switch).controlSize(.small)
                }
                let results = report.results.filter { !state.attentionOnly || $0.severity != .info }
                if results.isEmpty { EmptyWorkspace(symbol: "checkmark.seal", title: "No issues in this view", description: "All checks passed. Turn off the filter to see the full report.") }
                SurfacePanel {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            if index > 0 { Divider() }
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: result.severity.symbol).foregroundStyle(result.severity.color).frame(width: 16).padding(.top, 2)
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(result.evidence).foregroundStyle(.secondary).textSelection(.enabled)
                                        if let remediation = result.remediation { Text(remediation).foregroundStyle(result.severity.color) }
                                    }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                                } label: {
                                    HStack {
                                        Text(result.title).font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Text(result.severity == .info ? "Passed" : result.severity == .warning ? "Warning" : "Error")
                                            .font(.system(size: 10)).foregroundStyle(result.severity.color)
                                    }
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
            } else if !model.isRunningDoctor {
                SurfacePanel {
                    EmptyWorkspace(symbol: "stethoscope", title: "Let's check your stack", description: "Doctor checks ports, runtimes, signatures, configuration, and local system integration.", actionTitle: "Run Checks", action: { Task { await model.runDoctor() } })
                        .disabled(model.isRunningDoctor)
                }
            }
        }
    }
    private func diagnosticCount(_ report: DiagnosticReport, severity: DiagnosticSeverity, title: String) -> some View {
        SurfacePanel {
            HStack {
                Image(systemName: severity.symbol).foregroundStyle(severity.color).font(.system(size: 14))
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text("\(report.results.filter { $0.severity == severity }.count)").font(.system(size: 18, weight: .semibold))
            }
        }
    }
    private func exportBundle() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DevStack-Support-\(Date().formatted(.iso8601.year().month().day())).zip"; panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { model.exportSupportBundle(to: url) }
    }
}
@MainActor private final class DoctorViewState: ObservableObject { @Published var attentionOnly = true }

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SettingsViewState()
    var body: some View {
        WorkspacePage {
            PageHeading(title: "Settings", subtitle: "Appearance, helper, ports and runtimes.")
            SurfacePanel {
                HStack {
                    Label("Appearance", systemImage: "circle.lefthalf.filled").fontWeight(.medium)
                    Spacer()
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in Text(appearance.rawValue).tag(appearance) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
                }
                Divider()
                HStack {
                    Label("System integration", systemImage: "lock.shield").fontWeight(.medium)
                    Spacer()
                    if model.helperIsRegistered {
                        StatusBadge(title: model.helperInstalled ? "Ready" : "Not responding", color: model.helperInstalled ? DevStackDesign.success : .orange)
                        if !model.helperInstalled {
                            Button("Repair…") { Task { await model.installHelper() } }.buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
                        }
                        Button("Remove…", role: .destructive) { state.confirmRemove = true }.disabled(model.isBusy || model.hasRunningServices)
                    } else {
                        Button(model.helperSetupState.actionTitle) { Task { await model.installHelper() } }.buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
                    }
                }
                Text(model.helperSetupState.message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.isPreviewBuild {
                    HStack {
                        Text("Helper needs the signed /Applications install.").font(.system(size: 11)).foregroundStyle(.orange)
                        Spacer()
                        Button("Open /Applications Build…", action: model.openApplicationsBuild).buttonStyle(.borderless)
                    }
                }
                Toggle("Open DevStack at login", isOn: Binding(get: { model.configuration.startAtLogin }, set: { enabled in Task { await model.setStartAtLogin(enabled) } }))
                    .toggleStyle(.switch).controlSize(.small)
                HStack {
                    Label(model.localCATrusted ? "HTTPS certificates trusted" : "HTTPS certificate trust required", systemImage: "lock.shield").foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage SSL…") { model.selectedSection = .ssl }.buttonStyle(.borderless)
                }
                Divider()
                HStack {
                    Label("Runtime packs", systemImage: "shippingbox").fontWeight(.medium)
                    Spacer()
                    Button("Import Pack…", action: chooseRuntimePack).buttonStyle(DevStackGlassButtonStyle()).disabled(model.isBusy)
                }
                if !model.configuration.importedRuntimeIDs.isEmpty {
                    Text("Imported: \(model.configuration.importedRuntimeIDs.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DisclosureGroup("Installed runtimes and provenance") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.runtimeManifests.filter { $0.kind != .phpExtension }) { manifest in RuntimeDetailsRow(manifest: manifest) }
                    }.padding(.top, 8)
                }.font(.system(size: 11))
                Divider()
                CopyValueRow(label: "App data", value: model.paths.applicationSupport.path)
                CopyValueRow(label: "Runtimes", value: model.paths.builtInRuntimes.path)
                CopyValueRow(label: "Logs", value: model.paths.logs.path)
                HStack {
                    Button("Show App Data", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.applicationSupport]) }.buttonStyle(.borderless)
                    Spacer()
                    Button("Copy Shell Environment", systemImage: "doc.on.clipboard", action: model.copyManagedEnvironmentCommand).buttonStyle(.borderless)
                }.font(.system(size: 11))
            }
            PortsEditor()
            LocalNetworkEditor()
            HStack(spacing: 9) {
                BrandIcon(size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DevStack").font(.system(size: 12, weight: .semibold))
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · Apple Silicon · macOS 27+").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 4)
        }
        .alert("Remove system integration?", isPresented: $state.confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.removeHelper() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("DevStack will remove its local domain mappings, port forwarding, and certificate trust, then unregister the helper. Your projects and databases stay in place.") }
    }
    private func chooseRuntimePack() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.data]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.message = "Choose a signed .devstack-runtime archive."
        if panel.runModal() == .OK, let url = panel.url { Task { await model.importRuntimePack(from: url) } }
    }
}
@MainActor private final class SettingsViewState: ObservableObject { @Published var confirmRemove = false }

private struct RuntimeDetailsRow: View {
    let manifest: RuntimeManifest
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(manifest.kind.displayName) \(manifest.version)").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(manifest.architecture) · \(manifest.license)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(manifest.source.url.absoluteString).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
            Text("SHA-256 \(manifest.source.sha256)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
            if let gate = manifest.build?.feasibilityGate { Text("Compatibility gate: \(gate)").font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
}

private extension DiagnosticSeverity {
    var symbol: String {
        switch self { case .info: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" }
    }
    var color: Color {
        switch self { case .info: DevStackDesign.accent; case .warning: .orange; case .error: .red }
    }
}

private struct PortsEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = PortsDraft()
    @State private var applied = ServicePorts()

    var body: some View {
        SurfacePanel(title: "Ports", subtitle: model.hasRunningServices
            ? "Stop the stack to change ports."
            : "Choose where DevStack services listen. Keep the defaults, or use 80 and 443 to open sites without a port number.") {
            VStack(alignment: .leading, spacing: 10) {
                group("Web server") {
                    portRow("HTTP", text: $draft.webHTTP, fallback: ServicePorts.webHTTPFallback, isWebPort: true)
                    portRow("HTTPS", text: $draft.webHTTPS, fallback: ServicePorts.webHTTPSFallback, isWebPort: true)
                }
                Divider()
                group("Databases and mail") {
                    portRow("MySQL", text: $draft.mysql, fallback: ServicePorts.mysqlFallback, isWebPort: false)
                    portRow("PostgreSQL", text: $draft.postgresql, fallback: ServicePorts.postgresqlFallback, isWebPort: false)
                    portRow("Mailpit SMTP", text: $draft.mailpitSMTP, fallback: ServicePorts.mailpitSMTPFallback, isWebPort: false)
                    portRow("Mailpit inbox", text: $draft.mailpitInbox, fallback: ServicePorts.mailpitInboxFallback, isWebPort: false)
                }
                if let message = validationMessage {
                    Label(message, systemImage: validationIsError ? "exclamationmark.triangle" : "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(validationIsError ? Color.red : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Dev ports") { useDevPorts() }
                        .buttonStyle(DevStackGlassButtonStyle())
                        .disabled(model.hasRunningServices || model.isBusy)
                        .help("Use 8080 and 8443")
                    Button("Standard ports 80 / 443") { useStandardPorts() }
                        .buttonStyle(DevStackGlassButtonStyle())
                        .disabled(model.hasRunningServices || model.isBusy)
                    Spacer()
                    Button("Apply") { Task { await apply() } }
                        .buttonStyle(DevStackGlassButtonStyle())
                        .disabled(model.hasRunningServices || model.isBusy || draft.ports?.isValid != true || draft.ports == applied)
                }
            }
            .onAppear { sync() }
            .onChange(of: model.configuration.ports) { _, _ in sync() }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private var validationMessage: String? {
        guard let ports = draft.ports else { return "Enter a port from 1 to 65535 for every service." }
        if !ports.reservedRequests.isEmpty { return "Port 22 is reserved and cannot be assigned to a DevStack service." }
        if !ports.collisions.isEmpty { return "These ports conflict: \(ports.collisions.map(String.init).joined(separator: ", "))." }
        if ports.requiresHelper, !model.helperInstalled {
            return "Approve the helper (Settings → System integration) to use the ports below 1024."
        }
        return nil
    }

    private var validationIsError: Bool {
        guard let ports = draft.ports else { return true }
        return !ports.isValid
    }

    private func portRow(_ title: String, text: Binding<String>, fallback: UInt16, isWebPort: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).frame(width: 100, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .disabled(model.hasRunningServices || model.isBusy)
            if let value = UInt16(text.wrappedValue), value > 0, value < 1024 {
                Text(verbatim: helperHint(publicPort: value, fallback: fallback, isWebPort: isWebPort))
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    private func helperHint(publicPort: UInt16, fallback: UInt16, isWebPort: Bool) -> String {
        if isWebPort, publicPort == 80 || publicPort == 443 {
            return "Uses the helper · site URLs drop the port"
        }
        return "Uses the helper · forwards to \(fallback)"
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

private struct LocalNetworkEditor: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SurfacePanel(title: "Local network", subtitle: "Phones and other devices can use this Mac as DNS for DevStack hostnames. All other domains keep resolving through your normal DNS servers.") {
            VStack(alignment: .leading, spacing: 8) {
                if let address = model.localNetworkAddress {
                    CopyValueRow(label: "DNS address", value: address)
                } else {
                    Text("No active Wi-Fi or Ethernet connection.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Label("Local network access", systemImage: "wifi.router").fontWeight(.medium)
                    Spacer()
                    Toggle("Local network access", isOn: Binding(
                        get: { model.configuration.localNetworkAccess },
                        set: { enabled in Task { await model.setLocalNetworkAccess(enabled) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(model.isBusy || !model.helperInstalled)
                }
                Text(message)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.configuration.localNetworkAccess, let site = model.configuration.sites.first {
                    CopyValueRow(label: "Example", value: model.siteURL(site))
                }
            }
        }
    }

    private var message: String {
        guard model.helperInstalled else { return "Requires the helper (Settings → System integration)." }
        guard let address = model.localNetworkAddress else { return "Connect to Wi-Fi or Ethernet, then enable access for your devices." }
        if model.configuration.localNetworkAccess {
            var text = "On each device: Wi-Fi settings → Configure DNS → Manual → \(address)."
            text += " For HTTPS, open http://\(address):\(model.configuration.ports.webHTTPListen)/devstack-ca.crt on the device and trust the DevStack CA."
            if model.configuration.sites.contains(where: { $0.hostname.hasSuffix(".localhost") }) {
                text += " Names ending in .localhost resolve on the device itself, so use a .test domain (e.g. mysite.test) for sites you open from other devices."
            }
            return text
        }
        return "Enable to serve DevStack hostnames (and their web ports) to other devices on this network."
    }
}
