import AppKit
import Combine
import DevStackCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PHP

struct PHPView: View {
    @EnvironmentObject private var model: AppModel
    @State private var inspected: String?

    private static let extensions: [(id: String, name: String, detail: String)] = [
        ("xdebug", "Xdebug", "Step debugging on 127.0.0.1:9003"),
        ("redis", "Redis", "Redis client"),
        ("imagick", "Imagick", "Image processing with ImageMagick"),
        ("pgsql", "PostgreSQL", "Native PostgreSQL functions"),
        ("pdo_pgsql", "PDO PostgreSQL", "PostgreSQL driver for PDO")
    ]

    /// The version whose configuration the page shows.
    private var runtimeID: String { inspected ?? model.configuration.defaultPHPRuntimeID }
    private var defaultRunning: Bool { model.serviceIsRunning(ServiceKind(rawValue: model.configuration.defaultPHPRuntimeID) ?? .php85) }

    var body: some View {
        PanelPage {
            if runtimeID == "php-7.4" {
                Banner(symbol: "exclamationmark.triangle.fill", title: "PHP 7.4 is end-of-life",
                       detail: "It no longer receives security fixes. Use it only for older projects that need it.")
            }

            Panel("Versions", note: "New sites and the Terminal use the default version. Stop it to choose another.") {
                ForEach(model.phpRuntimes) { runtime in
                    let isDefault = runtime.id == model.configuration.defaultPHPRuntimeID
                    let sites = model.configuration.sites.filter { $0.phpRuntimeID == runtime.id }.count
                    ServiceRow(title: "PHP \(runtime.version)", symbol: "chevron.left.forwardslash.chevron.right",
                               address: (["php-fpm"] + (isDefault ? ["default"] : []) + ["\(sites) site\(sites == 1 ? "" : "s")"]).joined(separator: " · "),
                               service: ServiceKind(rawValue: runtime.id)) {
                        EmptyView()
                    } menuItems: {
                        Divider()
                        Button("Make Default") { Task { await model.selectPHP(runtime.id) } }
                            .disabled(isDefault || defaultRunning || model.isBusy || !model.runtimeIsAvailable(runtime.id))
                        Button("Configure") { inspected = runtime.id }
                    }
                }
            }

            Panel("Configuration", note: "Turning an extension on or off restarts that PHP version.") {
                ValueRow(label: "php.ini", value: model.paths.generatedPHP.appendingPathComponent("\(runtimeID).ini").path, revealsFile: true)
                ValueRow(label: "Binary", value: model.runtimeDirectory(runtimeID).appendingPathComponent("bin/php").path)
                ForEach(Self.extensions, id: \.id) { item in
                    let available = model.extensionIsAvailable(item.id, runtimeID: runtimeID)
                    PanelRow {
                        Text(item.name).lineLimit(1).frame(width: 120, alignment: .leading)
                        Text(available ? item.detail : "Not available for this version").foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Toggle(item.name, isOn: extensionBinding(item.id))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .disabled(!model.runtimeIsAvailable(runtimeID) || !available || model.isBusy)
                    }
                }
                PanelRow {
                    DisclosureGroup("Sources, licenses and build information") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.runtimeManifests.filter { $0.id == runtimeID || ($0.kind == .phpExtension && $0.dependencyPaths.contains(runtimeID)) }) { manifest in
                                RuntimeDetailsRow(manifest: manifest)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            } accessory: {
                Picker("Version", selection: Binding(get: { runtimeID }, set: { inspected = $0 })) {
                    ForEach(model.phpRuntimes) { runtime in
                        Text(runtime.version.split(separator: ".").prefix(2).joined(separator: ".")).tag(runtime.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("The PHP version to configure")
            }
        }
    }

    private func extensionBinding(_ name: String) -> Binding<Bool> {
        let runtimeID = runtimeID
        return Binding(get: { model.extensionIsAvailable(name, runtimeID: runtimeID) && model.configuration.enabledExtensions[runtimeID]?.contains(name) == true },
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
    private var port: UInt16 { state.postgreSQL ? model.configuration.ports.postgresqlListen : model.configuration.ports.mysqlListen }
    private var user: String { state.postgreSQL ? "devstack" : "root" }
    private var password: String { state.postgreSQL ? "devstack" : "root" }

    var body: some View {
        PanelPage {
            Panel("Services") { DatabaseServiceRows() }

            Panel("Connection", note: service == nil ? "\(engineName) is not part of the stack. Choose a version under Services." : nil) {
                ValueRow(label: "Host", value: "127.0.0.1")
                ValueRow(label: "Port", value: String(port))
                if state.postgreSQL { ValueRow(label: "Database", value: "postgres") }
                ValueRow(label: "Username", value: user)
                ValueRow(label: "Password", value: password)
                ValueRow(label: "Socket", value: state.postgreSQL ? model.paths.sockets.path : model.paths.sockets.appendingPathComponent("mysql.sock").path)
                ValueRow(label: "URL", value: state.postgreSQL ? "postgresql://\(user):\(password)@127.0.0.1:\(port)/postgres" : "mysql://\(user):\(password)@127.0.0.1:\(port)")
                ValueRow(label: "Shell", value: state.postgreSQL ? "psql postgresql://\(user):\(password)@127.0.0.1:\(port)/postgres" : "mysql -h 127.0.0.1 -P \(port) -u \(user) -p\(password)")
            } accessory: {
                Button { Pasteboard.copy(dotEnv) } label: { Label("Copy .env", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy DB_ settings for a Laravel or Symfony .env file")
                Picker("Database", selection: $state.postgreSQL) {
                    Text("MySQL").tag(false)
                    Text("PostgreSQL").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Panel("Tools", note: webRunning && running ? nil : "The web admin tools open while \(engineName) and the web server run.") {
                PanelRow {
                    Button {
                        model.openURL(model.toolURL("adminer") + (state.postgreSQL
                            ? "/?pgsql=127.0.0.1%3A\(port)&username=devstack&db=postgres"
                            : "/?server=127.0.0.1%3A\(port)&username=root"))
                    } label: { Label("Adminer", systemImage: "tablecells") }
                    if !state.postgreSQL {
                        Button { model.openURL(model.toolURL("phpmyadmin")) } label: { Label("phpMyAdmin", systemImage: "tablecells") }
                    }
                    Spacer()
                }
                .controlSize(.small)
                .disabled(!webRunning || !running)
            }

            Panel("Backup and Restore", note: running ? "Importing backs up \(engineName) first." : "Start \(engineName) to export or import SQL.") {
                PanelRow {
                    Button("Export…", action: exportDatabase)
                    Button("Import…", action: chooseImportFile)
                    Spacer()
                    Button("Show Backups") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.backups]) }
                }
                .controlSize(.small)
                .disabled(model.isBusy || !running)
                if let backup = model.lastDatabaseBackup {
                    ValueRow(label: "Last backup", value: backup.path, revealsFile: true)
                }
                if !state.postgreSQL, service != nil {
                    SettingRow(label: "Reset MySQL", detail: "Backs up MySQL, archives its data folder and starts fresh.") {
                        Button("Reset…", role: .destructive) { state.confirmingReset = true }
                            .controlSize(.small)
                            .disabled(model.isBusy)
                    }
                }
            }
        }
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

    private var dotEnv: String {
        state.postgreSQL
            ? "DB_CONNECTION=pgsql\nDB_HOST=127.0.0.1\nDB_PORT=\(port)\nDB_DATABASE=postgres\nDB_USERNAME=\(user)\nDB_PASSWORD=\(password)\n"
            : "DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=\(port)\nDB_USERNAME=\(user)\nDB_PASSWORD=\(password)\n"
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
    private var ports: ServicePorts { model.configuration.ports }

    var body: some View {
        PanelPage {
            Panel("Service") {
                ServiceRow(title: model.runtimeTitle("Mailpit", id: ServiceKind.mailpit.runtimeID), symbol: "envelope",
                           address: "smtp :\(ports.mailpitSMTP) · web :\(ports.mailpitInbox)", service: .mailpit) {
                    EmptyView()
                } menuItems: {
                    Divider()
                    Button("Open Inbox") { model.openURL(model.mailInboxURL) }
                }
            }

            Panel("SMTP", note: "PHP's mail() sends here automatically. SMTP needs no authentication or encryption.") {
                ValueRow(label: "Host", value: "127.0.0.1")
                ValueRow(label: "Port", value: String(ports.mailpitSMTP))
                ValueRow(label: "Inbox", value: model.mailInboxURL)
            } accessory: {
                Button { Pasteboard.copy(dotEnv) } label: { Label("Copy .env", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy MAIL_ settings for a Laravel .env file")
            }

            Panel("Inbox") {
                PanelRow {
                    Button { model.openURL(model.mailInboxURL) } label: { Label("Open Inbox", systemImage: "tray") }
                    Spacer()
                    Button("Clear Inbox…", role: .destructive) { state.isConfirmingClear = true }
                        .disabled(model.isBusy)
                }
                .controlSize(.small)
                .disabled(!running)
            }
        }
        .alert("Clear the inbox?", isPresented: $state.isConfirmingClear) {
            Button("Clear Inbox", role: .destructive) { Task { await model.clearMailpit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message stored in Mailpit is deleted.")
        }
    }

    private var dotEnv: String {
        "MAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT=\(ports.mailpitSMTP)\nMAIL_USERNAME=null\nMAIL_PASSWORD=null\nMAIL_ENCRYPTION=null\n"
    }
}

@MainActor private final class MailpitViewState: ObservableObject { @Published var isConfirmingClear = false }

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = LogsViewState()

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if state.rendered.characters.isEmpty {
                            Text(state.filter.isEmpty ? "No output yet." : "No lines match “\(state.filter)”.").foregroundStyle(.secondary)
                        } else {
                            Text(state.rendered)
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // At least the viewport, so short output starts at the top left.
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                }
                // Like tail -f: the newest lines stay in view.
                .defaultScrollAnchor(.bottomLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear(perform: refresh)
        .onChange(of: model.selectedLogFile) { _, _ in
            state.contents = ""
            state.rendered = AttributedString()
            refresh()
        }
        .onChange(of: state.filter) { _, _ in render() }
        .task(id: state.live) {
            guard state.live else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                refresh()
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
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
            .labelsHidden()
            .fixedSize()
            .help("Choose a log")
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Filter", text: $state.filter).textFieldStyle(.plain)
                if !state.filter.isEmpty {
                    Button { state.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PanelStyle.stroke))
            .frame(maxWidth: 260)
            Text("\(state.lineCount.formatted()) line\(state.lineCount == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 8)
            LiveToggle(isOn: $state.live)
            IconButton(title: "Copy the shown output", symbol: "doc.on.doc") {
                Pasteboard.copy(String(state.rendered.characters))
            }
            IconButton(title: "Show the log in Finder", symbol: "folder") {
                let file = model.paths.logs.appendingPathComponent(model.selectedLogFile)
                NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : model.paths.logs])
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func refresh() {
        let fileName = model.selectedLogFile
        Task {
            let snapshot = await model.logSnapshot(selected: fileName)
            // A slower read for an earlier selection must not overwrite the current one.
            guard fileName == model.selectedLogFile else { return }
            state.entries = snapshot.entries
            guard snapshot.contents != state.contents || state.rendered.characters.isEmpty else { return }
            state.contents = snapshot.contents
            render()
        }
    }

    private func render() {
        let contents = state.contents
        let filter = state.filter
        Task {
            let output = await Task.detached(priority: .userInitiated) { LogRendering.render(contents, filter: filter) }.value
            guard contents == state.contents, filter == state.filter else { return }
            state.rendered = output.text
            state.lineCount = output.lines
        }
    }
}

/// Whether the log follows new output, spelled out: a green dot and "Live",
/// or a pause symbol and "Paused".
private struct LiveToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                if isOn {
                    Circle().fill(.green).frame(width: 7, height: 7)
                } else {
                    Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
                }
                Text(isOn ? "Live" : "Paused")
            }
            .frame(minWidth: 54)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .green : nil)
        .help(isOn ? "Following new output. Click to pause." : "Paused. Click to follow new output.")
        .accessibilityLabel(isOn ? "Live, following new output" : "Paused")
    }
}

enum LogRendering {
    /// The log as styled text: errors in red, warnings in orange; only the
    /// lines containing `filter` when one is set.
    static func render(_ contents: String, filter: String) -> (text: AttributedString, lines: Int) {
        var text = AttributedString()
        var lines = 0
        var body = Substring(contents)
        // The file's final newline does not start another line.
        if body.hasSuffix("\n") { body = body.dropLast() }
        guard !body.isEmpty else { return (text, 0) }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if !filter.isEmpty, !line.localizedCaseInsensitiveContains(filter) { continue }
            var piece = AttributedString(lines == 0 ? String(line) : "\n" + line)
            let lower = line.lowercased()
            if lower.contains("error") || lower.contains("fatal") || lower.contains("[crit") || lower.contains("[emerg") || lower.contains("[alert") {
                piece.foregroundColor = .red
            } else if lower.contains("warn") || lower.contains("deprecated") {
                piece.foregroundColor = .orange
            }
            text.append(piece)
            lines += 1
        }
        return (text, lines)
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
    @Published var rendered = AttributedString()
    @Published var lineCount = 0
    @Published var filter = ""
    @Published var live = true
}

// MARK: - Doctor

struct DoctorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = DoctorViewState()

    var body: some View {
        content
            .alert("Remove the other DevStack helper?", isPresented: Binding(get: { state.pendingRemoval != nil }, set: { if !$0 { state.pendingRemoval = nil } }),
                   presenting: state.pendingRemoval) { executable in
                Button("Remove") { Task { await model.applyFix(.removeOtherHelper(executable: executable)) } }
                Button("Cancel", role: .cancel) {}
            } message: { executable in
                let copy = HelperProcesses.Running(pid: 0, executable: executable).applicationPath ?? executable
                Text("It runs from \(copy). DevStack stops it (macOS asks for an administrator password), moves that copy to the Trash and sets up this copy's helper. Empty the Trash afterwards so it cannot start again.")
            }
    }

    @ViewBuilder private var content: some View {
        if model.diagnosticReport == nil && !model.isRunningDoctor {
            ContentUnavailableView {
                Label("Check Your Stack", systemImage: "stethoscope")
            } description: {
                Text("Doctor checks ports, runtimes, signatures, configuration and system integration.")
            } actions: {
                HStack {
                    Button("Run Checks") { Task { await model.runDoctor() } }
                    fixAllButton
                }
            }
        } else {
            PanelPage {
                if model.isRepairing {
                    Banner(symbol: "wrench.and.screwdriver", title: model.repairProgress ?? "Fixing…",
                           detail: "macOS may ask for your password.", tint: .accentColor) {
                        ProgressView().controlSize(.small)
                    }
                } else if model.isRunningDoctor {
                    Banner(symbol: "stethoscope", title: model.diagnosticProgress ?? "Checking your stack…", tint: .accentColor) {
                        ProgressView().controlSize(.small)
                    }
                } else if let summary = model.repairSummary {
                    repairSummaryBanner(summary)
                }
                if let report = model.diagnosticReport {
                    let results = report.results.filter { !state.attentionOnly || $0.severity != .info }
                    Panel("Checks", note: "Checked \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)).") {
                        PanelRow {
                            count(report, .info, "passed", "passed")
                            count(report, .warning, "warning", "warnings")
                            count(report, .error, "error", "errors")
                            Spacer()
                            Toggle("Only what needs attention", isOn: $state.attentionOnly).toggleStyle(.checkbox).controlSize(.small)
                        }
                        if results.isEmpty {
                            PanelRow {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                Text("Nothing needs attention.").foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        ForEach(results) { result in
                            PanelRow {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(result.evidence).foregroundStyle(.secondary).textSelection(.enabled)
                                        if let remediation = result.remediation {
                                            Label(remediation, systemImage: "wrench.and.screwdriver")
                                        }
                                    }
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                                } label: {
                                    HStack {
                                        Label {
                                            Text(result.title)
                                        } icon: {
                                            Image(systemName: result.severity.symbol).foregroundStyle(result.severity.color)
                                        }
                                        Spacer(minLength: 8)
                                        if let fix = result.fix {
                                            Button(title(of: fix)) { apply(fix) }
                                                .controlSize(.small)
                                                .disabled(model.isBusy || model.isRunningDoctor || model.isRepairing)
                                        }
                                    }
                                }
                            }
                        }
                    } accessory: {
                        Button(action: exportBundle) { Label("Export Support Bundle…", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                            .disabled(model.isRunningDoctor)
                            .help("Save a support bundle with the report and logs")
                        Button { Task { await model.runDoctor() } } label: { Label("Run Again", systemImage: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .disabled(model.isRunningDoctor || model.isRepairing)
                        fixAllButton.padding(.leading, 6)
                    }
                }
            }
        }
    }

    private func title(of fix: DiagnosticFix) -> String {
        switch fix {
        case .removeOtherHelper: "Remove…"
        case .repairHelper: model.helperIsRegistered ? "Repair…" : "Set Up…"
        case .trustCertificate: "Trust…"
        case .installRuntime: "Install"
        case .stopProcess: "Stop"
        case .applyHostMappings: "Write"
        case .restartLocalDNS: "Restart"
        case .approveLoginItem: "Approve…"
        case .usePort(_, let port, _): "Use \(port)"
        }
    }

    /// Checks from scratch and applies every fix; its own, prominent button.
    private var fixAllButton: some View {
        Button { Task { await model.repairAll() } } label: { Label("Fix All", systemImage: "wrench.and.screwdriver") }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRepairing || model.isRunningDoctor || model.isBusy)
            .help("Run every check again and fix everything DevStack can: the helper and its approval, other copies' helpers, leftover servers, runtimes, certificate trust, host names, Local DNS and Open at Login. macOS asks for your password where needed.")
    }

    private func repairSummaryBanner(_ summary: RepairSummary) -> some View {
        let clean = summary.remaining.isEmpty
        let title = summary.done.isEmpty
            ? (clean ? "Everything is in order." : "Nothing DevStack can fix on its own.")
            : "Fixed \(summary.done.count) issue\(summary.done.count == 1 ? "" : "s").\(clean ? " Everything is in order." : "")"
        var lines = summary.done.map { "✓ " + $0 }
        if !clean { lines.append("Still needs attention: " + summary.remaining.joined(separator: ", ") + ".") }
        return Banner(symbol: clean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", title: title,
                      detail: lines.isEmpty ? nil : lines.joined(separator: "\n"), tint: clean ? .green : .orange) {
            Button("Dismiss") { model.repairSummary = nil }
        }
    }

    private func apply(_ fix: DiagnosticFix) {
        if case .removeOtherHelper(let executable) = fix {
            state.pendingRemoval = executable
        } else {
            Task { await model.applyFix(fix) }
        }
    }

    private func count(_ report: DiagnosticReport, _ severity: DiagnosticSeverity, _ singular: String, _ plural: String) -> some View {
        let number = report.results.filter { $0.severity == severity }.count
        return Label("\(number) \(number == 1 ? singular : plural)", systemImage: severity.symbol)
            .foregroundStyle(number == 0 && severity != .info ? Color.secondary : severity.color)
            .labelStyle(.titleAndIcon)
            .padding(.trailing, 6)
    }

    private func exportBundle() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DevStack-Support-\(Date().formatted(.iso8601.year().month().day())).zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { model.exportSupportBundle(to: url) }
    }
}

@MainActor private final class DoctorViewState: ObservableObject {
    @Published var attentionOnly = true
    /// The other copy's helper awaiting confirmation before removal.
    @Published var pendingRemoval: String?
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

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var state = SettingsViewState()
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage(MenuBarMode.defaultsKey) private var hideDockIcon = false

    var body: some View {
        PanelPage {
            Panel("General") {
                SettingRow(label: "Appearance") {
                    Picker("Appearance", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in Text(appearance.rawValue).tag(appearance) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow(label: "Open DevStack at login") {
                    Toggle("Open DevStack at login", isOn: Binding(get: { model.configuration.startAtLogin },
                                                                    set: { enabled in Task { await model.setStartAtLogin(enabled) } }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                SettingRow(label: "Hide app icon from Dock", detail: "When the window is minimized or closed, DevStack stays in the menu bar only. Open it again from there.") {
                    Toggle("Hide app icon from Dock", isOn: $hideDockIcon)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }

            Panel("Updates", note: updater.isAvailable ? nil : "Development builds don't check for updates.") {
                SettingRow(label: "Version") {
                    Text(AppUpdater.currentVersion).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Check Now", action: updater.checkForUpdates).controlSize(.small).disabled(!updater.canCheckForUpdates)
                }
                SettingRow(label: "Check for updates automatically") {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                                                             set: { updater.automaticallyChecksForUpdates = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .disabled(!updater.isAvailable)
                }
            }

            Panel("System Integration", note: model.helperSetupState.message) {
                SettingRow(label: "Helper", detail: "Custom hostnames, ports 80 and 443, local DNS") {
                    if model.helperIsRegistered {
                        StatusLabel(title: model.helperInstalled ? "Ready" : "Not responding", color: model.helperInstalled ? .green : .orange)
                        if !model.helperInstalled {
                            Button("Repair…") { Task { await model.installHelper() } }.controlSize(.small).disabled(model.isBusy)
                        }
                        Button("Remove…", role: .destructive) { state.confirmRemove = true }
                            .controlSize(.small)
                            .disabled(model.isBusy || model.hasRunningServices)
                    } else {
                        StatusLabel(title: "Not set up", color: Color(nsColor: .tertiaryLabelColor))
                        Button(model.helperSetupState.actionTitle) { Task { await model.installHelper() } }.controlSize(.small).disabled(model.isBusy)
                    }
                }
                SettingRow(label: "HTTPS certificates") {
                    StatusLabel(title: model.localCATrusted ? "Trusted" : "Not trusted", color: model.localCATrusted ? .green : .orange)
                    Button("Manage…") { model.selectedSection = .ssl }.controlSize(.small)
                }
                SettingRow(label: "Setup assistant") {
                    Button("Run…") { model.presentSetupWizard() }.controlSize(.small).disabled(model.isBusy)
                }
                if model.isPreviewBuild {
                    SettingRow(label: "Preview build", detail: "The helper works only with the signed copy in Applications.") {
                        Button("Open Signed Copy…", action: model.openApplicationsBuild).controlSize(.small)
                    }
                }
            }

            PortsPanel()
            LocalDNSPanel()

            Panel("Runtimes") {
                SettingRow(label: "Installed runtimes") {
                    Button("Manage…") { model.selectedSection = .runtimes }.controlSize(.small)
                }
                PanelRow {
                    DisclosureGroup("Sources and licenses") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.runtimeManifests.filter { $0.kind != .phpExtension }) { manifest in RuntimeDetailsRow(manifest: manifest) }
                        }
                        .padding(.top, 4)
                    }
                }
            }

            Panel("Locations", note: "DevStack \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build") · Apple silicon · macOS 15 or later") {
                ValueRow(label: "App data", value: model.paths.applicationSupport.path, revealsFile: true)
                ValueRow(label: "Runtimes", value: model.paths.importedRuntimes.path, revealsFile: true)
                ValueRow(label: "Logs", value: model.paths.logs.path, revealsFile: true)
                SettingRow(label: "Shell environment", detail: "Puts DevStack's PHP, Composer and database tools on your shell's PATH") {
                    Button("Copy Command", action: model.copyManagedEnvironmentCommand).controlSize(.small)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 2) {
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
    }
}

private struct PortsPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = PortsDraft()
    @State private var applied = ServicePorts()

    private var locked: Bool { model.hasRunningServices || model.isBusy }

    var body: some View {
        Panel("Ports", note: note) {
            portRow("Web HTTP", text: $draft.webHTTP, role: .webHTTP, isWebPort: true)
            portRow("Web HTTPS", text: $draft.webHTTPS, role: .webHTTPS, isWebPort: true)
            portRow("MySQL", text: $draft.mysql, role: .mysql, isWebPort: false)
            portRow("PostgreSQL", text: $draft.postgresql, role: .postgresql, isWebPort: false)
            portRow("Mail SMTP", text: $draft.mailpitSMTP, role: .mailpitSMTP, isWebPort: false)
            portRow("Mail inbox", text: $draft.mailpitInbox, role: .mailpitInbox, isWebPort: false)
            PanelRow {
                Button("Use 8080 and 8443") { useDevPorts() }.disabled(locked).help("Ports that work without the helper")
                Button("Use 80 and 443") { useStandardPorts() }.disabled(locked).help("Site addresses without a port number; needs the helper")
                Spacer()
                Button("Revert") { sync() }.disabled(locked || !changed)
                Button("Apply") { Task { await apply() } }
                    .disabled(locked || draft.ports?.isValid != true || !changed)
            }
            .controlSize(.small)
        }
        .onAppear { sync() }
        .onChange(of: model.configuration.ports) { _, _ in sync() }
    }

    /// Edited public ports; DevStack's internal choices are not edited here.
    private var changed: Bool { draft.ports?.publicOnly != applied.publicOnly }

    private var note: String {
        if model.hasRunningServices { return "Stop the stack to change ports." }
        if let message = validationMessage { return message }
        return "Ports below 1024 use the helper, which forwards them to unprivileged ports."
    }

    private func portRow(_ title: String, text: Binding<String>, role: PortRole, isWebPort: Bool) -> some View {
        PanelRow {
            Text(title)
            Spacer(minLength: 8)
            if let value = UInt16(text.wrappedValue), value > 0, value < 1024 {
                // The internal port the helper forwards to; DevStack moves it
                // when another program holds it.
                let internalPort = applied.internalPort(role)
                Text(verbatim: isWebPort && (value == 80 || value == 443) ? "via the helper to \(internalPort); no port in site URLs" : "via the helper, to \(internalPort)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField(title, text: text)
                .labelsHidden()
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .controlSize(.small)
                .disabled(locked)
        }
    }

    private var validationMessage: String? {
        guard let ports = draft.ports else { return "Enter a port from 1 to 65535 for every service." }
        if !ports.reservedRequests.isEmpty { return "Port 22 is reserved and cannot be assigned to a DevStack service." }
        if !ports.collisions.isEmpty { return "These ports conflict: \(ports.collisions.map(String.init).joined(separator: ", "))." }
        if ports.requiresHelper, !model.helperInstalled { return "Set up the helper to use ports below 1024." }
        return nil
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
        guard var ports = draft.ports else { return }
        ports.internalPorts = applied.internalPorts
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

private struct LocalDNSPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel("Local DNS", note: note) {
            SettingRow(label: "Serve DevStack hostnames to this network") {
                Toggle("Serve DevStack hostnames to this network", isOn: Binding(
                    get: { model.configuration.localNetworkAccess },
                    set: { enabled in Task { await model.setLocalNetworkAccess(enabled) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(model.isBusy || !model.helperInstalled)
            }
            if let address = model.localNetworkAddress {
                ValueRow(label: "DNS address", value: address)
            }
            SettingRow(label: "Device setup") {
                Button("Show Instructions…") { model.selectedSection = .localDNS }.controlSize(.small)
            }
        }
    }

    private var note: String? {
        guard model.helperInstalled else { return "Needs the helper. Set it up under System Integration." }
        guard model.localNetworkAddress != nil else { return "Connect to Wi-Fi or Ethernet to serve other devices." }
        return nil
    }
}
