import AppKit
import DevStackCore
import SwiftUI

/// Imports projects and databases from another local development app,
/// starting with XAMPP: pick the app, check it, choose what comes along,
/// import, and read what the checks afterwards found.
struct MigrationWizardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: MigrationController

    init(controller: MigrationController) {
        _controller = StateObject(wrappedValue: controller)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch controller.step {
                    case .source: sourceStep
                    case .check: checkStep
                    case .choose: chooseStep
                    case .importing: importStep
                    case .results: resultsStep
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 620)
        .interactiveDismissDisabled(controller.isRunning)
        .onAppear { if controller.installations.isEmpty { controller.loadSources() } }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.step.heading).font(.title2.weight(.semibold))
                Text(controller.step.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("Step \(controller.step.rawValue + 1) of \(MigrationController.Step.allCases.count)").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch controller.step {
            case .source:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    controller.step = .check
                    Task { await controller.scan() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.sources.isEmpty || (controller.source == .xampp && controller.installation == nil))
            case .check:
                Button("Back") { controller.step = .source }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") { controller.step = .choose }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.inventory == nil || controller.actionInProgress != nil || controller.hasBlockers)
            case .choose:
                Button("Back") { controller.step = .check }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { controller.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.nothingChosen || controller.hostnameProblem != nil || controller.hasBlockers || model.isBusy)
            case .importing:
                Spacer()
                Button(controller.isCancelling ? "Cancelling…" : "Cancel Import") { controller.cancel() }
                    .disabled(!controller.isRunning || controller.isCancelling)
            case .results:
                if let report = controller.results?.report {
                    Button("Open Report") { NSWorkspace.shared.open(report) }
                }
                if let exports = controller.results?.exports {
                    Button("Show Exports") { NSWorkspace.shared.activateFileViewerSelecting([exports]) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Source

    @ViewBuilder private var sourceStep: some View {
        if controller.sources.isEmpty {
            Banner(symbol: "questionmark.folder", title: "No app to import from",
                   detail: "DevStack imports from XAMPP and looks for it in Applications, where its installer puts the xamppfiles folder. None is there.", tint: .secondary)
        } else {
            Panel("Found on this Mac") {
                ForEach(controller.sources) { source in
                    SourceRow(kind: source.kind, application: source.application, selected: controller.source == source.kind) {
                        controller.source = source.kind
                    }
                }
            }
            if controller.source == .xampp {
                if controller.installations.count > 1 {
                    Panel("Installation", note: "Each copy keeps its own htdocs and databases.") {
                        ForEach(controller.installations) { installation in
                            PanelRow {
                                Image(systemName: controller.installationID == installation.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(controller.installationID == installation.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(installation.title)
                                    Text(installation.location.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .onTapGesture { controller.installationID = installation.id }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Check

    @ViewBuilder private var checkStep: some View {
        if controller.inventory == nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(controller.scanProgress ?? "Reading XAMPP…").foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } else {
            if let error = controller.actionError {
                Banner(symbol: "exclamationmark.triangle.fill", title: "That didn't work", detail: error)
            }
            Panel("Checks") {
                ForEach(controller.checks) { check in
                    PanelRow {
                        CheckIcon(status: check.status)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.title)
                            if let detail = check.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        if let action = check.action {
                            if controller.actionInProgress != nil {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(action == .installRosetta ? "Install Rosetta…" : "Stop XAMPP…") { Task { await controller.perform(action) } }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Choose

    @ViewBuilder private var chooseStep: some View {
        if let error = controller.actionError {
            Banner(symbol: "exclamationmark.triangle.fill", title: "That didn't work", detail: error)
        }
        if let problem = controller.hostnameProblem {
            Banner(symbol: "exclamationmark.triangle.fill", title: "Fix a hostname", detail: problem, tint: .red)
        }
        if !controller.projects.isEmpty {
            Panel("Projects", note: "Copies go to your DevStack folder; XAMPP keeps its own. A localhost address works as it did in XAMPP; a host of its own suits projects with a public folder.") {
                ForEach($controller.projects) { $choice in
                    ProjectChoiceRow(choice: $choice, url: controller.url(for: choice),
                                     documentRoot: controller.documentRoot(for: choice).path,
                                     chooseFolder: choice.project.kind == .folder ? { controller.chooseFolder(for: choice.id) } : nil)
                }
            } accessory: {
                selectAllButton(all: controller.projects.allSatisfy(\.selected)) { selected in
                    for index in controller.projects.indices { controller.projects[index].selected = selected }
                }
            }
        }
        if controller.databasesBlocked {
            Banner(symbol: "cpu", title: "The databases stay behind",
                   detail: controller.inventory.map { FileManager.default.isExecutableFile(atPath: $0.installation.mysqld.path) } == false
                       ? "XAMPP's MariaDB is missing, so its databases can't be read."
                       : "XAMPP's MariaDB needs Rosetta to read them. Install it here, or import the projects now and the databases later.") {
                if controller.inventory?.serverNeedsRosetta == true {
                    if controller.actionInProgress != nil { ProgressView().controlSize(.small) }
                    else { Button("Install Rosetta…") { Task { await controller.perform(.installRosetta) } } }
                }
            }
        }
        if !controller.databases.isEmpty {
            let engine = model.importDatabaseEngine
            Panel("Databases", note: "Each one is exported from XAMPP's MariaDB, converted for \(engine.displayName) and counted table by table after the import. The exports stay in Backups.") {
                ForEach($controller.databases) { $choice in
                    DatabaseChoiceRow(choice: $choice)
                }
            } accessory: {
                selectAllButton(all: controller.databases.allSatisfy(\.selected)) { selected in
                    for index in controller.databases.indices { controller.databases[index].selected = selected }
                }
            }
            .disabled(controller.databasesBlocked)
            .opacity(controller.databasesBlocked ? 0.5 : 1)
        }
        Panel("Settings") {
            SettingRow(label: "PHP version", detail: "For the imported sites\(controller.projects.contains { $0.selected && $0.address == .localhostPath } ? " and localhost" : "").") {
                Picker("PHP version", selection: $controller.phpRuntimeID) {
                    ForEach(model.runtimePackCatalog.packs.filter { $0.id.hasPrefix("php-") }, id: \.id) { pin in
                        Text(pin.displayName).tag(pin.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if controller.databases.contains(where: \.selected), !controller.databasesBlocked {
                SettingRow(label: "Root without a password, as in XAMPP",
                           detail: "Projects keep signing in as root with no password. DevStack's MySQL, phpMyAdmin and Adminer switch from root/root.") {
                    Toggle("Root without a password", isOn: $controller.rootWithoutPassword).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingRow(label: "XAMPP's SQL mode",
                           detail: "MySQL's default is stricter (ONLY_FULL_GROUP_BY, no zero dates), which older projects trip over.") {
                    Toggle("XAMPP's SQL mode", isOn: $controller.matchSQLMode).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
            SettingRow(label: "Update project settings",
                       detail: "In the copies only: wp-config.php, .env and WordPress addresses that point at XAMPP. Each changed file keeps a .xampp-backup.") {
                Toggle("Update project settings", isOn: $controller.updateProjectSettings).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private func selectAllButton(all: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button(all ? "Select None" : "Select All") { set(!all) }.buttonStyle(.borderless)
    }

    // MARK: - Import

    @ViewBuilder private var importStep: some View {
        Panel {
            ForEach(controller.tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    PanelRow {
                        TaskIcon(state: task.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).foregroundStyle(task.state == .pending || task.state == .skipped ? .secondary : .primary)
                            if let detail = task.detail {
                                Text(detail).font(.caption).foregroundStyle(task.state == .failed ? .red : .secondary)
                                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                            }
                            if task.state == .running, task.id == "files", let copy = controller.copyProgress {
                                Text("\(copy.files) of \(copy.totalFiles) files · \(MigrationController.bytes(copy.bytes)) of \(MigrationController.bytes(copy.totalBytes))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(copy.current).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    if task.state == .running, let progress = task.progress {
                        ProgressView(value: progress).padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
            }
        }
    }

    // MARK: - Results

    @ViewBuilder private var resultsStep: some View {
        if let results = controller.results {
            switch results.outcome {
            case .ok:
                Banner(symbol: "checkmark.circle.fill", title: "Everything came across",
                       detail: "Every site answered and every database has the rows XAMPP had. XAMPP is unchanged; remove it whenever you like.", tint: .green)
            case .warning:
                Banner(symbol: "exclamationmark.triangle.fill", title: "Imported, with things to look at",
                       detail: "The rows marked below need a look. The report lists everything.")
            case .failed:
                Banner(symbol: results.cancelled ? "stop.circle.fill" : "xmark.octagon.fill",
                       title: results.cancelled ? "Import cancelled" : "The import stopped",
                       detail: results.failure ?? "What finished before stays imported.", tint: results.cancelled ? .secondary : .red)
            }
            if !results.projects.isEmpty {
                Panel("Sites") {
                    ForEach(results.projects) { project in
                        PanelRow {
                            OutcomeIcon(outcome: project.outcome)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(project.name)
                                    Button(project.url) { model.openURL(project.url) }
                                        .buttonStyle(.link).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                }
                                if let message = project.message {
                                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            IconButton(title: "Show in Finder", symbol: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.folder)])
                            }
                        }
                    }
                }
            }
            if !results.databases.isEmpty {
                Panel("Databases") {
                    ForEach(results.databases) { database in
                        PanelRow {
                            OutcomeIcon(outcome: database.outcome)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(database.source == database.target ? database.source : "\(database.source) → \(database.target)")
                                if let message = database.message {
                                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            if database.outcome != .failed {
                                Text("\(database.tables) tables · \(database.rows) rows").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !results.notes.isEmpty {
                Panel("Notes") {
                    ForEach(Array(results.notes.enumerated()), id: \.offset) { _, note in
                        PanelRow {
                            Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rows

private struct SourceRow: View {
    let kind: MigrationSourceKind
    let application: URL?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        PanelRow {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        if let application, application.pathExtension == "app", FileManager.default.fileExists(atPath: application.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.path)).resizable()
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .overlay(Text(String(kind.title.prefix(1))).font(.callout.weight(.semibold)).foregroundStyle(.secondary))
                .padding(2)
        }
    }
}

private struct ProjectChoiceRow: View {
    @Binding var choice: MigrationController.ProjectChoice
    let url: String
    let documentRoot: String
    let chooseFolder: (() -> Void)?
    @State private var folders: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if choice.address == .ownSite {
                documentRootRow
            }
        }
        .opacity(choice.selected ? 1 : 0.55)
        .task(id: choice.project.source) { folders = Self.folders(in: choice.project.source) }
    }

    /// Where its own host serves from: the web root inside the project, and
    /// where the project goes.
    private var documentRootRow: some View {
        HStack(spacing: 8) {
            Text("Document root").font(.caption).foregroundStyle(.secondary)
            Text((documentRoot as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .help(documentRoot)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Picker("Web root", selection: $choice.webRoot) {
                Text("Project folder").tag("")
                if !folders.isEmpty { Divider() }
                ForEach(Array(Set(folders + (choice.webRoot.isEmpty ? [] : [choice.webRoot]))).sorted(), id: \.self) { folder in
                    Text(folder + "/").tag(folder)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
            .help("The folder inside the project the site serves")
            if let chooseFolder {
                Button("Choose…", action: chooseFolder)
                    .controlSize(.small)
                    .help("Choose where the project is copied")
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 10)
        .padding(.bottom, 7)
    }

    /// The project's top-level folders, for its web root.
    private static func folders(in project: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .prefix(40).map { $0 }
    }

    private var mainRow: some View {
        PanelRow {
            Toggle(choice.project.name, isOn: $choice.selected).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(choice.project.name).lineLimit(1).truncationMode(.middle)
                    Tag(text: choice.project.framework.title)
                    if choice.address == .ownSite, !choice.webRoot.isEmpty { Tag(text: choice.webRoot + "/") }
                }
                Text(url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 180, alignment: .leading)
            Spacer(minLength: 8)
            if choice.canChooseAddress {
                Picker("Address", selection: $choice.address) {
                    Text("localhost/…").tag(MigrationController.Address.localhostPath)
                    Text("Own host").tag(MigrationController.Address.ownSite)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .controlSize(.small)
            }
            if choice.address == .ownSite {
                TextField("Hostname", text: $choice.hostname)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(width: 170)
                    .controlSize(.small)
            }
            Text(choice.project.kind == .external ? "In place" : MigrationController.bytes(choice.project.bytes))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }
}

private struct DatabaseChoiceRow: View {
    @Binding var choice: MigrationController.DatabaseChoice

    var body: some View {
        PanelRow {
            Toggle(choice.database.name, isOn: $choice.selected).labelsHidden()
            Text(choice.database.name).font(.callout.monospaced())
            if choice.database.isSample { Tag(text: "XAMPP sample") }
            Spacer(minLength: 8)
            if choice.exists {
                Text("Exists in DevStack").font(.caption).foregroundStyle(.orange)
                Picker("When it exists", selection: $choice.clash) {
                    Text("Import as \(choice.renamedName)").tag(MigrationController.Clash.rename)
                    Text("Replace (backs up first)").tag(MigrationController.Clash.replace)
                    Text("Skip").tag(MigrationController.Clash.skip)
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
        .opacity(choice.selected ? 1 : 0.55)
    }
}

private struct CheckIcon: View {
    let status: MigrationController.Check.Status

    var body: some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .blocker: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

private struct TaskIcon: View {
    let state: MigrationController.ImportTask.State

    var body: some View {
        Group {
            switch state {
            case .pending: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 18)
    }
}

private struct OutcomeIcon: View {
    let outcome: MigrationController.Outcome

    var body: some View {
        switch outcome {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
