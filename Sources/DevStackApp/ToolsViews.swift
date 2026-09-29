import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

struct PHPView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        WorkspacePage {
            PageHeading(title: "PHP", subtitle: "Choose the capabilities your projects need. Each version keeps its own extensions.")
            runtimePanel(id: "php-8.5", title: "PHP 8.5", subtitle: "8.5.11 · The default for new projects", legacy: false)
            runtimePanel(id: "php-7.4", title: "PHP 7.4", subtitle: "7.4.33 · For existing legacy projects", legacy: true)
            SurfacePanel(title: "Runtime details") {
                DisclosureGroup("Sources, licenses, and build information") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.runtimeManifests.filter { $0.kind == .php || $0.kind == .phpExtension }) { manifest in
                            RuntimeDetailsRow(manifest: manifest)
                        }
                    }.padding(.top, 12)
                }.font(.system(size: 12))
            }
        }
    }

    private func runtimePanel(id: String, title: String, subtitle: String, legacy: Bool) -> some View {
        SurfacePanel {
            HStack(spacing: 12) {
                FeatureIcon(symbol: "chevron.left.forwardslash.chevron.right", color: legacy ? .orange : DevStackDesign.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(title: model.runtimeIsAvailable(id) ? legacy ? "Legacy" : "Installed" : "Not installed", color: model.runtimeIsAvailable(id) ? legacy ? .orange : DevStackDesign.accent : .secondary)
            }
            if legacy {
                InfoNotice(symbol: "exclamationmark.triangle", title: "Legacy compatibility", message: "PHP 7.4 no longer receives security fixes. Use it only for older projects that need it.", color: .orange)
            }
            ForEach(Array([("xdebug", "Xdebug", "Step debugging on 127.0.0.1:9003. Off by default."), ("redis", "Redis", "PHP client extension for a Redis server."), ("imagick", "Imagick", "Image processing with bundled ImageMagick.")].enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.1).font(.system(size: 13, weight: .medium))
                        Text(model.extensionIsAvailable(item.0, runtimeID: id) ? item.2 : "Extension not installed for this runtime.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(item.1, isOn: extensionBinding(item.0, runtimeID: id)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!model.runtimeIsAvailable(id) || !model.extensionIsAvailable(item.0, runtimeID: id) || model.isBusy)
                }
            }
        }
    }
    private func extensionBinding(_ name: String, runtimeID: String) -> Binding<Bool> {
        Binding(get: { model.extensionIsAvailable(name, runtimeID: runtimeID) && model.configuration.enabledExtensions[runtimeID]?.contains(name) == true }, set: { enabled in Task { await model.setExtension(name, enabled: enabled, runtimeID: runtimeID) } })
    }
}

struct DatabaseView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = DatabaseViewState()
    private var running: Bool { model.serviceIsRunning(model.configuration.selectedDatabase == .mysql57 ? .mysql57 : .mysql84) }
    var body: some View {
        WorkspacePage {
            HStack {
                PageHeading(title: "Database", subtitle: "Local MySQL, with simple connection details and built-in backups.")
                Spacer()
                Button("Open phpMyAdmin", systemImage: "arrow.up.right") { model.openURL("https://phpmyadmin.devstack.test") }
                    .buttonStyle(.glass).disabled(!model.serviceIsRunning(.apache) || !running)
            }
            SurfacePanel {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: "externaldrive")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Database engine").font(.system(size: 15, weight: .semibold))
                        Text("Each version keeps an independent data directory.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(title: running ? "Running" : "Stopped", color: running ? DevStackDesign.accent : .secondary, dot: true)
                }
                Picker("Active engine", selection: databaseBinding) {
                    ForEach(DatabaseEngine.allCases, id: \.rawValue) { engine in
                        Text(engine.displayName + (!model.runtimeIsAvailable(engine.rawValue) ? " · Not installed" : engine.isLegacy ? " · Legacy" : ""))
                            .tag(engine).disabled(!model.runtimeIsAvailable(engine.rawValue))
                    }
                }.disabled(model.isBusy)
                if model.configuration.selectedDatabase.isLegacy {
                    InfoNotice(symbol: "exclamationmark.triangle", title: "MySQL 5.7 is end-of-life", message: "Use this engine only when a legacy project needs it. Switching engines keeps your data files separate.", color: .orange)
                }
            }
            SurfacePanel(title: "Local connection", subtitle: "Available to applications on this Mac.") {
                CopyValueRow(label: "Host", value: "127.0.0.1")
                CopyValueRow(label: "Port", value: "3306")
                CopyValueRow(label: "Username", value: "root")
                CopyValueRow(label: "Password", value: "root")
                CopyValueRow(label: "Socket", value: model.paths.sockets.appendingPathComponent("mysql.sock").path)
            }
            SurfacePanel(title: "Backup and restore", subtitle: "Import creates a timestamped backup before changing your data.") {
                HStack(spacing: 12) {
                    Button("Export Databases…", systemImage: "square.and.arrow.up", action: exportDatabase).buttonStyle(.glass).disabled(model.isBusy || !running)
                    Button("Import SQL…", systemImage: "arrow.down.doc", action: chooseImportFile).buttonStyle(.glass).disabled(model.isBusy || !running)
                    Spacer()
                    Button("Show Backups", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.backups]) }.buttonStyle(.borderless)
                }
                if !running { Text("Start the stack to export or import databases.").font(.system(size: 11)).foregroundStyle(.secondary) }
                if let backup = model.lastDatabaseBackup {
                    Divider()
                    CopyValueRow(label: "Last backup", value: backup.path)
                }
            }
            SurfacePanel {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reset database").font(.system(size: 13, weight: .medium))
                        Text("Archive the current data directory and start fresh.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset…", role: .destructive) { state.isConfirmingReset = true }.disabled(model.isBusy || !model.runtimeIsAvailable(model.configuration.selectedDatabase.rawValue))
                }
            }
        }
        .alert("Import SQL file?", isPresented: $state.isConfirmingImport, presenting: state.pendingImport) { url in
            Button("Import", role: .destructive) { state.pendingImport = nil; Task { await model.importDatabase(from: url) } }
            Button("Cancel", role: .cancel) { state.pendingImport = nil }
        } message: { url in Text("DevStack creates a backup before importing \(url.lastPathComponent). Existing databases may be overwritten.") }
        .alert("Reset \(model.configuration.selectedDatabase.displayName)?", isPresented: $state.isConfirmingReset) {
            Button("Back Up and Reset", role: .destructive) { Task { await model.resetDatabase() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("DevStack backs up the current databases, stops the engine, archives its data directory, and creates a clean database with root/root credentials.") }
        .alert("Use legacy MySQL 5.7?", isPresented: $state.isConfirmingLegacy) {
            Button("Use MySQL 5.7", role: .destructive) { model.selectedDatabaseBinding = .mysql57 }
            Button("Cancel", role: .cancel) {}
        } message: { Text("MySQL 5.7 no longer receives security fixes. Its data stays separate from MySQL 8.4.") }
    }
    private var databaseBinding: Binding<DatabaseEngine> {
        Binding(get: { model.selectedDatabaseBinding }, set: { engine in
            if engine == .mysql57, model.configuration.selectedDatabase != .mysql57 { state.isConfirmingLegacy = true }
            else { model.selectedDatabaseBinding = engine }
        })
    }
    private func exportDatabase() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = model.databaseBackupFilename(); panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]; panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { Task { await model.exportDatabase(to: url) } }
    }
    private func chooseImportFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { state.pendingImport = url; state.isConfirmingImport = true }
    }
}
@MainActor private final class DatabaseViewState: ObservableObject {
    @Published var pendingImport: URL?
    @Published var isConfirmingImport = false
    @Published var isConfirmingReset = false
    @Published var isConfirmingLegacy = false
}

struct MailpitView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = MailpitViewState()
    var body: some View {
        WorkspacePage {
            PageHeading(title: "Mail Inbox", subtitle: "Development emails stay here, safely on your Mac.")
            SurfacePanel {
                HStack(spacing: 14) {
                    FeatureIcon(symbol: "tray")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mailpit").font(.system(size: 16, weight: .semibold))
                        Text("A local inbox for every project.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(title: model.serviceIsRunning(.mailpit) ? "Capturing mail" : "Stopped", color: model.serviceIsRunning(.mailpit) ? DevStackDesign.accent : .secondary, dot: true)
                }
                EmptyWorkspace(symbol: "envelope.open", title: "See what your app sends", description: "Send a test email from your project, then open the inbox to inspect its content and headers.")
                HStack {
                    Button("Open Inbox", systemImage: "arrow.up.right") { model.openURL("https://mailpit.devstack.test") }
                        .buttonStyle(.glassProminent).controlSize(.large).disabled(!model.serviceIsRunning(.mailpit) || !model.serviceIsRunning(.apache))
                    Spacer()
                    Button("Clear Inbox…", systemImage: "trash", role: .destructive) { state.isConfirmingClear = true }
                        .disabled(!model.serviceIsRunning(.mailpit) || model.isBusy)
                }
            }
            SurfacePanel(title: "Connect your app", subtitle: "No SMTP authentication or encryption is needed on loopback.") {
                CopyValueRow(label: "SMTP host", value: "127.0.0.1")
                CopyValueRow(label: "SMTP port", value: "1025")
                CopyValueRow(label: "Inbox URL", value: "https://mailpit.devstack.test")
                Divider()
                Text("PHP mail() is configured automatically. Mailpit captures messages locally and does not relay them to recipients.")
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
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                PageHeading(title: "Logs", subtitle: "Follow service output and find the details behind a failure.")
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.paths.logs]) } label: { Image(systemName: "folder") }.buttonStyle(.glass).help("Show logs folder").accessibilityLabel("Show logs folder")
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass).help("Refresh logs").accessibilityLabel("Refresh logs")
            }
            HStack(spacing: 14) {
                Picker("Service", selection: $model.selectedLogService) {
                    ForEach(ServiceKind.allCases) { service in Text(service.displayName).tag(service) }
                }.frame(width: 205)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter output", text: $state.filter).textFieldStyle(.plain)
                }.padding(9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).frame(maxWidth: 300)
                Spacer()
                Toggle("Live", isOn: $state.live).toggleStyle(.switch).controlSize(.small)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(filteredContents, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy displayed output").accessibilityLabel("Copy displayed output")
            }
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(currentPhase.color).frame(width: 6, height: 6)
                    Text("\(model.selectedLogService.rawValue).log").font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Text(state.live ? "LIVE" : "PAUSED").font(.system(size: 9, weight: .medium)).tracking(1)
                }.foregroundStyle(.white.opacity(0.5)).padding(13).background(.white.opacity(0.025))
                Divider().overlay(.white.opacity(0.06))
                ScrollView([.horizontal, .vertical]) {
                    Text(filteredContents.isEmpty ? "No lines match your filter." : filteredContents)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.83)).lineSpacing(5)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
                }
            }.background(Color(red: 0.055, green: 0.07, blue: 0.085), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
        }.padding(28).frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.background(WorkspaceBackground())
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
                PageHeading(title: "Doctor", subtitle: "Understand your installation and get a clear next step when something needs attention.")
                Spacer()
                Button("Export…", systemImage: "square.and.arrow.up", action: exportBundle).buttonStyle(.glass).disabled(model.diagnosticReport == nil || model.isRunningDoctor)
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    if model.isRunningDoctor { HStack { ProgressView().controlSize(.mini); Text("Checking…") } }
                    else { Label("Run Checks", systemImage: "stethoscope") }
                }.buttonStyle(.glassProminent).disabled(model.isRunningDoctor)
            }
            if model.isRunningDoctor {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.diagnosticProgress ?? "Checking your stack…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("You can keep using DevStack.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(16).background(DevStackDesign.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            if let report = model.diagnosticReport {
                HStack(spacing: 12) {
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
                ForEach(results) { result in
                    SurfacePanel {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: result.severity.symbol).font(.system(size: 18)).foregroundStyle(result.severity.color)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(result.title).font(.system(size: 13, weight: .semibold))
                                Text(result.evidence).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                                if let remediation = result.remediation {
                                    Text(remediation).font(.system(size: 12)).foregroundStyle(result.severity.color)
                                }
                            }
                        }
                    }
                }
            } else {
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(report.results.filter { $0.severity == severity }.count)").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: severity.symbol).foregroundStyle(severity.color).font(.system(size: 20))
            }
        }
    }
    private func exportBundle() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DevStack-Support-\(Date().formatted(.iso8601.year().month().day())).zip"; panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { model.exportSupportBundle(to: url) }
    }
}
@MainActor private final class DoctorViewState: ObservableObject { @Published var attentionOnly = false }

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SettingsViewState()
    var body: some View {
        WorkspacePage {
            PageHeading(title: "Settings", subtitle: "")
            SurfacePanel(title: "Appearance") {
                HStack {
                    Label("Theme", systemImage: "circle.lefthalf.filled").font(.system(size: 13))
                    Spacer()
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in Text(appearance.rawValue).tag(appearance) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
            }
            SurfacePanel(title: "System integration", subtitle: "Enable local domains, standard web ports, and trusted HTTPS.") {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: "lock.shield")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DevStack Helper").font(.system(size: 13, weight: .medium))
                        Text(model.helperSetupState.message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.helperInstalled { StatusBadge(title: "Installed", color: DevStackDesign.accent, dot: true) }
                    else {
                        Button(model.helperSetupState.actionTitle) { Task { await model.installHelper() } }.buttonStyle(.glassProminent).disabled(model.isBusy)
                    }
                }
                Divider()
                Toggle(isOn: Binding(get: { model.configuration.startAtLogin }, set: { enabled in Task { await model.setStartAtLogin(enabled) } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open DevStack at login").font(.system(size: 13))
                    }
                }.toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Open DevStack at login")
                if model.helperInstalled {
                    Button("Remove System Integration…", role: .destructive) { state.confirmRemove = true }.font(.system(size: 11)).disabled(model.isBusy || model.hasRunningServices)
                    if model.hasRunningServices { Text("Stop the stack before removing system integration.").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            }
            SurfacePanel(title: "Offline runtimes", subtitle: "Import a signed pack from your Mac or removable media.") {
                HStack {
                    Text("Runtime packs are verified before installation.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import Pack…", systemImage: "shippingbox", action: chooseRuntimePack).buttonStyle(.glass).disabled(model.isBusy)
                }
                if !model.configuration.importedRuntimeIDs.isEmpty {
                    Text("Imported: \(model.configuration.importedRuntimeIDs.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DisclosureGroup("Installed runtimes and provenance") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.runtimeManifests.filter { $0.kind != .phpExtension }) { manifest in RuntimeDetailsRow(manifest: manifest) }
                    }.padding(.top, 12)
                }.font(.system(size: 12))
            }
            SurfacePanel(title: "Data locations") {
                CopyValueRow(label: "App data", value: model.paths.applicationSupport.path)
                CopyValueRow(label: "Runtimes", value: model.paths.builtInRuntimes.path)
                CopyValueRow(label: "Logs", value: model.paths.logs.path)
                HStack {
                    Button("Show App Data", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.applicationSupport]) }.buttonStyle(.borderless)
                    Spacer()
                    Button("Copy Shell Environment", systemImage: "doc.on.clipboard", action: model.copyManagedEnvironmentCommand).buttonStyle(.borderless)
                }.font(.system(size: 11))
            }
            HStack(spacing: 9) {
                BrandIcon(size: 42)
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
