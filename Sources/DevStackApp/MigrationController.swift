import AppKit
import DevStackCore
import SwiftUI

/// A cancel request that background work can read.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func reset() { lock.withLock { value = false } }
}

/// One import from another app: where from, what was found, what to bring,
/// the import itself and what the checks afterwards found. XAMPP is the
/// first source; the others show in the list for what comes next.
@MainActor
final class MigrationController: ObservableObject {
    enum Step: Int, CaseIterable {
        case source, check, choose, importing, results

        var heading: String {
            switch self {
            case .source: "Import from Another App"
            case .check: "Check XAMPP"
            case .choose: "Choose What to Import"
            case .importing: "Importing"
            case .results: "Import Results"
            }
        }

        var subtitle: String {
            switch self {
            case .source: "Bring your projects and databases into DevStack. The other app is only read, never changed."
            case .check: "What DevStack found, and anything to settle first."
            case .choose: "Projects get a DevStack site; databases move into DevStack's MySQL."
            case .importing: "Copying and converting. You can cancel at any time."
            case .results: "Each site was opened and each database counted after the import."
            }
        }
    }

    /// Where an imported project answers.
    enum Address: Hashable {
        /// https://localhost/folder, as it was in XAMPP.
        case localhostPath
        /// Its own hostname, such as https://shop.localhost.
        case ownSite
    }

    struct ProjectChoice: Identifiable {
        var project: MigrationProject
        var selected = true
        var address: Address
        var hostname: String
        var id: String { project.id }

        var canChooseAddress: Bool { project.kind == .folder }
    }

    enum Clash: String, CaseIterable, Identifiable {
        case rename, replace, skip
        var id: String { rawValue }
    }

    struct DatabaseChoice: Identifiable {
        var database: MigrationDatabase
        var selected: Bool
        /// A database of that name is in DevStack's MySQL already.
        var exists: Bool
        var clash: Clash = .rename
        var renamedName: String
        var id: String { database.id }

        var targetName: String { exists && clash == .rename ? renamedName : database.name }
        var willImport: Bool { selected && !(exists && clash == .skip) }
    }

    struct Check: Identifiable {
        enum Status { case ok, info, warning, blocker }
        enum Action { case installRosetta, stopXAMPP }
        var id: String
        var status: Status
        var title: String
        var detail: String?
        var action: Action?
    }

    struct ImportTask: Identifiable {
        enum State { case pending, running, done, warning, failed, skipped }
        var id: String
        var title: String
        var state: State = .pending
        var detail: String?
        var progress: Double?
    }

    enum Outcome: Comparable { case ok, warning, failed }

    struct ProjectResult: Identifiable {
        var id: String
        var name: String
        var url: String
        var folder: String
        var outcome: Outcome
        var message: String?
    }

    struct DatabaseResult: Identifiable {
        var id: String
        var source: String
        var target: String
        var tables: Int
        var rows: Int64
        var outcome: Outcome
        var message: String?
    }

    struct Results {
        var projects: [ProjectResult] = []
        var databases: [DatabaseResult] = []
        var notes: [String] = []
        var failure: String?
        var cancelled = false
        var report: URL?
        var exports: URL?

        var outcome: Outcome {
            if failure != nil || cancelled { return .failed }
            return (projects.map(\.outcome) + databases.map(\.outcome)).max() ?? .ok
        }
    }

    @Published var step: Step = .source
    @Published var source: MigrationSourceKind = .xampp
    @Published var installations: [XAMPPInstallation] = []
    @Published var installationID: String?
    @Published var inventory: XAMPPInventory?
    @Published var scanProgress: String?
    @Published var rosettaAvailable = true
    @Published var runningServers: [String] = []
    @Published var actionInProgress: String?
    @Published var actionError: String?
    @Published var projects: [ProjectChoice] = []
    @Published var databases: [DatabaseChoice] = []
    @Published var phpRuntimeID = "php-8.4"
    @Published var rootWithoutPassword = true
    @Published var matchSQLMode = true
    @Published var updateProjectSettings = true
    @Published var tasks: [ImportTask] = []
    @Published var copyProgress: FileCopyProgress?
    @Published var isRunning = false
    @Published var isCancelling = false
    @Published var results: Results?

    private let cancelFlag = CancelFlag()
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    var installation: XAMPPInstallation? { installations.first { $0.id == installationID } }

    /// Where apps are looked for; the end-to-end review points it at a
    /// fixture.
    static var applicationsFolder = URL(fileURLWithPath: "/Applications")

    func loadSources() {
        installations = XAMPPInstallation.find(applications: Self.applicationsFolder)
        if installationID == nil || installation == nil { installationID = installations.first?.id }
    }

    // MARK: - Pre-checks

    func scan() async {
        guard let installation, let model else { return }
        inventory = nil
        scanProgress = "Reading \(installation.title)…"
        let found = await Task.detached { [weak self] in
            XAMPPScanner.scan(installation) { message in Task { @MainActor in self?.scanProgress = message } }
        }.value
        let needsRosetta = found.serverNeedsRosetta
        let (rosetta, servers) = await Task.detached { (needsRosetta ? Rosetta.isAvailable : true, XAMPPProcesses.running(installation)) }.value
        rosettaAvailable = rosetta
        runningServers = servers
        inventory = found
        scanProgress = nil

        let engine = model.importDatabaseEngine
        phpRuntimeID = PHPVersionMapping.runtimeID(for: installation.phpVersion, available: model.runtimePackCatalog.packs.map(\.id).filter { $0.hasPrefix("php-") })
            ?? model.configuration.defaultPHPRuntimeID
        var taken = Set(model.configuration.sites.map(\.hostname) + HostnameValidator.managementHostnames)
        projects = found.projects.map { project in
            let hostname = MigrationNaming.hostname(for: project, taken: taken)
            taken.insert(hostname)
            // A project with its own web root or host name keeps working only
            // at a host of its own; plain folders keep their XAMPP address.
            let ownSite = project.kind == .external || !project.webRoot.isEmpty || project.virtualHost != nil
            let address: Address = { if case .looseFiles = project.kind { return .localhostPath }; return ownSite ? .ownSite : .localhostPath }()
            return ProjectChoice(project: project, address: address, hostname: hostname)
        }
        let existing = model.existingDatabaseNames(engine)
        let names = existing.union(found.databases.map(\.name))
        databases = found.databases.map { database in
            DatabaseChoice(database: database, selected: !database.isSample, exists: existing.contains { $0.lowercased() == database.name.lowercased() },
                           renamedName: MigrationNaming.databaseName(database.name, taken: names))
        }
        // XAMPP's root has no password unless someone set one; switching
        // DevStack's root to match is safe while DevStack holds no databases.
        rootWithoutPassword = existing.isEmpty || model.configuration.mysql(engine).rootPassword.isEmpty
    }

    var checks: [Check] {
        guard let inventory, let model else { return [] }
        let installation = inventory.installation
        var result: [Check] = []
        result.append(Check(id: "found", status: .ok, title: "\(installation.title) in \(installation.location.path)",
                             detail: installation.phpVersion.map { "PHP \($0), Apache and MariaDB." }))
        let projectCount = inventory.projects.count
        result.append(Check(id: "projects", status: projectCount == 0 ? .info : .ok,
                            title: projectCount == 0 ? "No projects in htdocs" : "\(projectCount) project\(projectCount == 1 ? "" : "s"), \(Self.bytes(inventory.projectBytes))",
                            detail: inventory.skippedDefaults.isEmpty ? nil : "XAMPP's own pages (\(inventory.skippedDefaults.joined(separator: ", "))) stay behind."))
        if inventory.databases.isEmpty {
            result.append(Check(id: "databases", status: .info, title: "No databases found"))
        } else {
            result.append(Check(id: "databases", status: .ok, title: "\(inventory.databases.count) database\(inventory.databases.count == 1 ? "" : "s")",
                                detail: inventory.dataReadable ? nil : "XAMPP's data folder belongs to its MySQL account, so macOS asks for your administrator password to copy it."))
            if !FileManager.default.isExecutableFile(atPath: installation.mysqld.path) {
                result.append(Check(id: "mariadb", status: .warning, title: "XAMPP's MariaDB is missing",
                                    detail: "Without it the databases can't be read; projects still import."))
            } else if inventory.serverNeedsRosetta {
                result.append(rosettaAvailable
                    ? Check(id: "mariadb", status: .ok, title: "XAMPP's MariaDB runs through Rosetta")
                    : Check(id: "mariadb", status: .blocker, title: "XAMPP's MariaDB needs Rosetta",
                            detail: "XAMPP is built for Intel Macs, which is likely why it stopped working here. Install Rosetta reads the databases; it installs Apple's translator and accepts Apple's license for it. Or leave the databases out.",
                            action: .installRosetta))
            }
        }
        if !runningServers.isEmpty {
            result.append(Check(id: "running", status: .blocker, title: "XAMPP is running: \(runningServers.joined(separator: ", "))",
                                detail: "Its MariaDB must be stopped for a consistent copy, and its Apache holds ports 80 and 443.", action: .stopXAMPP))
        }
        let engine = model.importDatabaseEngine
        var runtimes: [String] = []
        if !model.runtimeIsAvailable(phpRuntimeID) { runtimes.append(phpRuntimeID) }
        if !inventory.databases.isEmpty, !model.runtimeIsAvailable(engine.rawValue) { runtimes.append(engine.rawValue) }
        let phpTitle = model.runtimePackCatalog.pin(for: phpRuntimeID)?.displayName ?? phpRuntimeID
        result.append(Check(id: "php", status: .ok, title: "XAMPP's PHP \(installation.phpVersion ?? "?") → \(phpTitle)",
                            detail: installation.phpVersion.map { $0 == phpRuntimeID.dropFirst(4) ? nil : "The closest DevStack has; you can pick another on the next step." } ?? nil))
        if !inventory.databases.isEmpty {
            result.append(Check(id: "mysql", status: .ok, title: "Databases go to \(engine.displayName)",
                                detail: "MariaDB-only syntax is converted on the way, and each table's rows are counted on both sides."))
        }
        if !runtimes.isEmpty {
            let size = model.runtimePackDownloadSize(runtimes)
            result.append(Check(id: "runtimes", status: .info, title: "Installs \(runtimes.compactMap { model.runtimePackCatalog.pin(for: $0)?.displayName }.joined(separator: " and "))",
                                detail: "\(Self.bytes(size)) download, checked against DevStack's signature."))
        }
        let free = (try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        let needed = inventory.projectBytes + inventory.dataBytes * 3 + 512 << 20
        result.append(Check(id: "disk", status: free >= needed ? .ok : .blocker, title: "\(Self.bytes(free)) free on disk",
                            detail: free >= needed ? nil : "The import needs about \(Self.bytes(needed)) for the copies and the database exports."))
        if !model.helperInstalled {
            result.append(Check(id: "helper", status: .warning, title: "The helper isn't set up",
                                detail: "Sites answer on port \(model.configuration.ports.webHTTPSListen) until it is. Set it up in Settings."))
        }
        if XAMPPInstallation.virtualMachineFound() {
            result.append(Check(id: "vm", status: .info, title: "XAMPP-VM isn't supported yet", detail: "Its projects and databases live inside a Linux virtual machine."))
        }
        return result
    }

    /// XAMPP's MariaDB can't run here (no Rosetta, or it is gone), so the
    /// databases stay behind while projects still import.
    var databasesBlocked: Bool {
        guard let inventory, !inventory.databases.isEmpty else { return false }
        return !FileManager.default.isExecutableFile(atPath: inventory.installation.mysqld.path) || (inventory.serverNeedsRosetta && !rosettaAvailable)
    }

    /// Problems that stop the import; Rosetta only stops the databases.
    var hasBlockers: Bool {
        checks.contains { $0.status == .blocker && $0.action != .installRosetta }
    }

    func perform(_ action: Check.Action) async {
        guard let model, let installation else { return }
        actionError = nil
        switch action {
        case .installRosetta:
            actionInProgress = "Installing Rosetta…"
            do { try await model.runAsAdministrator(Rosetta.installCommand, prompt: "DevStack installs Rosetta so XAMPP's MariaDB can run and your databases can be read.") }
            catch { actionError = error.localizedDescription }
            rosettaAvailable = await Task.detached { Rosetta.isAvailable }.value
        case .stopXAMPP:
            actionInProgress = "Stopping XAMPP…"
            let command = model.quoteForShell(installation.root.appendingPathComponent("xampp").path) + " stop"
            do { try await model.runAsAdministrator(command, prompt: "DevStack stops XAMPP's servers so its data can be copied.") }
            catch { actionError = error.localizedDescription }
            runningServers = await Task.detached { XAMPPProcesses.running(installation) }.value
        }
        actionInProgress = nil
    }

    // MARK: - Choices

    var hostnameProblem: String? {
        guard let model else { return nil }
        var taken = model.configuration.sites.map(\.hostname)
        for choice in projects where choice.selected && choice.address == .ownSite {
            do { taken.append(try HostnameValidator.validateSite(choice.hostname, existing: taken)) }
            catch { return "\(choice.project.name): \(error.localizedDescription)" }
        }
        return nil
    }

    var nothingChosen: Bool { !projects.contains(where: \.selected) && (databasesBlocked || !databases.contains(where: \.willImport)) }

    /// The project's address in DevStack. A project under localhost answers
    /// at its folder's name: `folder` once it is copied, else the name the
    /// copy will get (with -xampp when localhost has that folder already).
    func url(for choice: ProjectChoice, folder: URL? = nil) -> String {
        guard let model else { return "" }
        let port = model.configuration.ports.webHTTPS
        let suffix = port == 443 ? "" : ":\(port)"
        switch choice.address {
        case .ownSite: return "https://\(choice.hostname)\(suffix)"
        case .localhostPath:
            if case .looseFiles = choice.project.kind { return "https://localhost\(suffix)/" }
            let name = folder?.lastPathComponent ?? MigrationNaming.folder(named: choice.project.name, in: localhostRoot).lastPathComponent
            return "https://localhost\(suffix)/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"
        }
    }

    private var localhostRoot: URL {
        guard let model else { return URL(fileURLWithPath: NSHomeDirectory()) }
        return URL(fileURLWithPath: model.configuration.sites.first { $0.hostname == "localhost" }?.documentRoot ?? model.paths.defaultSiteRoot.path, isDirectory: true)
    }

    // MARK: - Import

    func cancel() {
        cancelFlag.set()
        isCancelling = true
    }

    private var cancelled: Bool { cancelFlag.isSet }

    private func update(_ id: String, _ state: ImportTask.State, detail: String? = nil, progress: Double? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = state
        tasks[index].detail = detail
        tasks[index].progress = progress
    }

    private func progress(_ id: String, _ fraction: Double?, detail: String?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].state == .running else { return }
        tasks[index].progress = fraction
        if let detail { tasks[index].detail = detail }
    }

    func start() {
        cancelFlag.reset()
        isCancelling = false
        step = .importing
        Task { await run() }
    }

    private func run() async {
        guard let model, let inventory else { return }
        let installation = inventory.installation
        isRunning = true
        defer { isRunning = false; isCancelling = false; copyProgress = nil }

        let chosenProjects = projects.filter(\.selected)
        let chosenDatabases = databasesBlocked ? [] : databases.filter(\.willImport)
        let engine = model.importDatabaseEngine
        let readsDatabases = !chosenDatabases.isEmpty
        var runtimeIDs = [phpRuntimeID]
        if readsDatabases { runtimeIDs.append(engine.rawValue) }
        let missingRuntimes = runtimeIDs.filter { !model.runtimeIsAvailable($0) }

        tasks = []
        if !missingRuntimes.isEmpty { tasks.append(ImportTask(id: "runtimes", title: "Install runtimes")) }
        if !chosenProjects.isEmpty {
            tasks.append(ImportTask(id: "files", title: "Copy projects"))
            tasks.append(ImportTask(id: "sites", title: "Add sites"))
        }
        if readsDatabases {
            tasks += [
                ImportTask(id: "data", title: "Copy XAMPP's database files"),
                ImportTask(id: "server", title: "Start XAMPP's MariaDB on the copy"),
                ImportTask(id: "export", title: "Export databases"),
                ImportTask(id: "mysql", title: "Prepare \(engine.displayName)"),
                ImportTask(id: "import", title: "Import and verify databases"),
                ImportTask(id: "accounts", title: "Recreate database accounts")
            ]
        }
        if !chosenProjects.isEmpty {
            if updateProjectSettings { tasks.append(ImportTask(id: "settings", title: "Update project settings")) }
            tasks.append(ImportTask(id: "stack", title: "Start the stack"))
            tasks.append(ImportTask(id: "probe", title: "Open each site"))
        }

        var outcome = Results()
        let stamp = Self.stamp()
        let exportsFolder = model.paths.backups.appendingPathComponent("XAMPP import \(stamp)", isDirectory: true)
        let workFolder = model.paths.applicationSupport.appendingPathComponent("Imports/\(UUID().uuidString)", isDirectory: true)
        defer {
            let folder = workFolder
            Task.detached { try? FileManager.default.removeItem(at: folder) }
        }

        func finish(failure: String? = nil) {
            outcome.failure = failure
            outcome.cancelled = cancelled && failure == nil
            if outcome.cancelled {
                for task in tasks where task.state == .pending || task.state == .running { update(task.id, .skipped, detail: "Cancelled") }
            }
            outcome.report = writeReport(outcome, installation: installation, folder: exportsFolder)
            outcome.exports = FileManager.default.fileExists(atPath: exportsFolder.path) ? exportsFolder : nil
            results = outcome
            step = .results
        }

        // Runtimes.
        if !missingRuntimes.isEmpty {
            update("runtimes", .running, detail: missingRuntimes.compactMap { model.runtimePackCatalog.pin(for: $0)?.displayName }.joined(separator: ", "))
            if let error = await model.installRuntimePacks(missingRuntimes) {
                update("runtimes", .failed, detail: error)
                return finish(failure: error)
            }
            update("runtimes", .done)
        }

        // Projects.
        var placed: [(choice: ProjectChoice, folder: URL)] = []
        // Folders this run copied; a cancel before their sites exist removes them.
        var createdFolders: [URL] = []
        func cancelCopies() {
            for folder in createdFolders { try? FileManager.default.removeItem(at: folder) }
            if !createdFolders.isEmpty { outcome.notes.append("The projects copied before the cancel were removed again.") }
        }
        if !chosenProjects.isEmpty {
            update("files", .running)
            let localhostRoot = self.localhostRoot
            let projectsRoot = model.paths.defaultSiteRoot.deletingLastPathComponent()
            let totalBytes = chosenProjects.filter { $0.project.kind != .external }.reduce(Int64(0)) { $0 + $1.project.bytes }
            let totalFiles = chosenProjects.filter { $0.project.kind != .external }.reduce(0) { $0 + $1.project.files }
            var doneBytes: Int64 = 0
            var doneFiles = 0
            var skippedFiles: [FileCopyFailure] = []
            var takenFolders: Set<String> = []
            for choice in chosenProjects {
                if cancelled { cancelCopies(); return finish() }
                let project = choice.project
                switch project.kind {
                case .external:
                    placed.append((choice, project.source))
                case .looseFiles(let names):
                    let result = await Task.detached { try? ProjectCopier.copyFiles(names, from: project.source, into: localhostRoot) }.value
                    if let result {
                        skippedFiles += result.failures
                        if !result.kept.isEmpty { outcome.notes.append("Kept the localhost site's own \(result.kept.joined(separator: ", ")) instead of XAMPP's.") }
                    }
                    doneFiles += project.files
                    doneBytes += project.bytes
                    placed.append((choice, localhostRoot))
                case .folder:
                    let parent = choice.address == .localhostPath ? localhostRoot : projectsRoot
                    let destination = MigrationNaming.folder(named: project.name, in: parent, taken: takenFolders)
                    takenFolders.insert(destination.lastPathComponent.lowercased())
                    if destination.lastPathComponent != project.name {
                        outcome.notes.append("\(project.name) went to \(destination.lastPathComponent), as \(parent.path) already has a \(project.name).")
                    }
                    let base = (bytes: doneBytes, files: doneFiles)
                    let flag = cancelFlag
                    do {
                        let failures = try await Task.detached { [weak self] in
                            try ProjectCopier.copyFolder(project.source, to: destination, totals: (project.files, project.bytes),
                                                         isCancelled: { flag.isSet }) { progress in
                                Task { @MainActor in
                                    guard let self else { return }
                                    var total = progress
                                    total.files += base.files
                                    total.bytes += base.bytes
                                    total.totalFiles = totalFiles
                                    total.totalBytes = totalBytes
                                    total.current = "\(project.name)/\(progress.current)"
                                    self.copyProgress = total
                                    self.progress("files", total.fraction, detail: nil)
                                }
                            }
                        }.value
                        skippedFiles += failures
                    } catch is CancellationError {
                        cancelCopies()
                        return finish()
                    } catch {
                        update("files", .failed, detail: "\(project.name): \(error.localizedDescription)")
                        return finish(failure: error.localizedDescription)
                    }
                    doneBytes += project.bytes
                    doneFiles += project.files
                    createdFolders.append(destination)
                    placed.append((choice, destination))
                }
            }
            copyProgress = nil
            if skippedFiles.isEmpty {
                update("files", .done, detail: "\(doneFiles) files, \(Self.bytes(doneBytes))")
            } else {
                update("files", .warning, detail: "\(skippedFiles.count) files could not be read and were left out.")
                outcome.notes.append("Files XAMPP's folders did not let DevStack read: " + skippedFiles.prefix(10).map(\.path).joined(separator: ", ") + (skippedFiles.count > 10 ? ", …" : ""))
            }

            // Sites.
            update("sites", .running)
            let overrides = PHPSettingsImport.overrides(fromPHPINI: inventory.phpINI)
            var sites: [SiteDefinition] = []
            for (choice, folder) in placed where choice.address == .ownSite {
                let webRoot = choice.project.webRoot.isEmpty ? folder : folder.appendingPathComponent(choice.project.webRoot, isDirectory: true)
                let id = UUID()
                sites.append(SiteDefinition(
                    id: id, name: choice.project.name, hostname: choice.hostname,
                    documentRoot: FileManager.default.fileExists(atPath: webRoot.path) ? webRoot.path : folder.path,
                    tlsEnabled: true, phpRuntimeID: phpRuntimeID, phpOverrides: overrides, createPlaceholderIndex: false,
                    logs: SiteLogPaths(access: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-access.log").path,
                                       error: model.paths.logs.appendingPathComponent("site-\(id.uuidString)-error.log").path)))
            }
            let usesLocalhost = placed.contains { $0.choice.address == .localhostPath }
            let localhostSite = model.configuration.sites.first { $0.hostname == "localhost" }
            do {
                try await model.addImportedSites(sites, localhostPHP: usesLocalhost ? phpRuntimeID : nil,
                                                 localhostOverrides: usesLocalhost ? PHPSettingsImport.overrides(fromPHPINI: inventory.phpINI, base: localhostSite?.phpOverrides ?? PHPSiteOverrides()) : nil)
                update("sites", .done, detail: [sites.isEmpty ? nil : "\(sites.count) site\(sites.count == 1 ? "" : "s")",
                                                usesLocalhost ? "localhost serves the rest" : nil].compactMap { $0 }.joined(separator: "; "))
            } catch {
                update("sites", .failed, detail: error.localizedDescription)
                outcome.notes.append("Sites were not added: \(error.localizedDescription)")
            }
        }

        // Databases.
        var renamed: [String: String] = [:]
        var imported: Set<String> = []
        if readsDatabases {
            if cancelled { return finish() }
            let databaseResult = await importDatabases(chosenDatabases, installation: installation, inventory: inventory, engine: engine,
                                                       exportsFolder: exportsFolder, workFolder: workFolder)
            outcome.databases = databaseResult.results
            outcome.notes += databaseResult.notes
            renamed = databaseResult.renamed
            imported = databaseResult.imported
            if let failure = databaseResult.failure, chosenProjects.isEmpty { return finish(failure: failure) }
        } else if databasesBlocked, databases.contains(where: \.willImport) {
            outcome.notes.append("Databases were not imported: XAMPP's MariaDB can't run on this Mac\(rosettaAvailable ? "" : " without Rosetta").")
        }
        if cancelled { return finish() }

        // Project settings.
        if !chosenProjects.isEmpty, updateProjectSettings {
            update("settings", .running)
            var changed: [String] = []
            let port = model.configuration.ports.mysqlListen
            let renames = renamed.filter { $0.key != $0.value }
            for (choice, folder) in placed {
                if case .looseFiles = choice.project.kind { continue }
                let newURL = url(for: choice, folder: folder)
                // Read before the update, which may rename its database.
                let wordPress = choice.project.framework == .wordpress ? ProjectSettingsUpdater.wordPressSettings(in: folder) : nil
                if let changes = try? ProjectSettingsUpdater.update(project: folder, renamedDatabases: renames, mysqlPort: port, newURL: newURL, oldURLs: choice.project.originalURLs),
                   !changes.isEmpty {
                    changed += changes.map { "\(choice.project.name): \($0)" }
                }
                if let settings = wordPress, let database = settings.database, let target = renamed[database], imported.contains(target) {
                    if let rows = await replaceWordPressAddresses(database: target, prefix: settings.tablePrefix, oldURLs: choice.project.originalURLs, newURL: newURL) {
                        if rows > 0 { changed.append("\(choice.project.name): \(rows) database values now use \(newURL)") }
                    } else {
                        outcome.notes.append("\(choice.project.name): WordPress addresses could not be updated; it may send you to its XAMPP address.")
                    }
                }
            }
            update("settings", .done, detail: changed.isEmpty ? "Nothing pointed at XAMPP." : "\(changed.count) change\(changed.count == 1 ? "" : "s"); originals kept as .xampp-backup")
            outcome.notes += changed
        }

        // The stack and each site.
        if !chosenProjects.isEmpty {
            if cancelled { return finish() }
            update("stack", .running)
            if model.stackIsRunning {
                update("stack", .done, detail: "Already running")
            } else if let error = await model.startStackForImport() {
                update("stack", .failed, detail: error)
                outcome.notes.append("The stack did not start: \(error)")
            } else {
                update("stack", .done)
            }
            update("probe", .running)
            outcome.projects = await probe(placed)
            let failing = outcome.projects.filter { $0.outcome != .ok }.count
            update("probe", failing == 0 ? .done : .warning, detail: failing == 0 ? "Every site answered." : "\(failing) need\(failing == 1 ? "s" : "") a look.")
            if let missing = await missingExtensions(installation: installation) , !missing.isEmpty {
                outcome.notes.append("PHP extensions XAMPP had that \(phpRuntimeID) lacks: \(missing.joined(separator: ", ")).")
            }
        }
        finish()
    }

    // MARK: Databases

    private struct DatabasePhase {
        var results: [DatabaseResult] = []
        var notes: [String] = []
        var renamed: [String: String] = [:]
        var imported: Set<String> = []
        var failure: String?
    }

    private func importDatabases(_ chosen: [DatabaseChoice], installation: XAMPPInstallation, inventory: XAMPPInventory, engine: DatabaseEngine,
                                 exportsFolder: URL, workFolder: URL) async -> DatabasePhase {
        guard let model else { return DatabasePhase() }
        let data = workFolder.appendingPathComponent("data", isDirectory: true)
        let server = TemporaryMariaDB(tools: MariaDBTools(installation: installation), dataDirectory: data,
                                      workDirectory: workFolder.appendingPathComponent("server", isDirectory: true),
                                      socket: model.paths.sockets.appendingPathComponent("xampp-import.sock"),
                                      serverSettings: installation.mysqlServerSettings())
        let phase = await importDatabases(chosen, installation: installation, inventory: inventory, engine: engine,
                                          exportsFolder: exportsFolder, workFolder: workFolder, data: data, server: server)
        // Stopping waits for InnoDB to flush; the work folder goes only after.
        await Task.detached { server.stop() }.value
        return phase
    }

    private func importDatabases(_ chosen: [DatabaseChoice], installation: XAMPPInstallation, inventory: XAMPPInventory, engine: DatabaseEngine,
                                 exportsFolder: URL, workFolder: URL, data: URL, server: TemporaryMariaDB) async -> DatabasePhase {
        guard let model else { return DatabasePhase() }
        var phase = DatabasePhase()
        let flag = cancelFlag
        func fail(_ task: String, _ message: String) -> DatabasePhase {
            update(task, .failed, detail: message)
            for later in ["server", "export", "mysql", "import", "accounts"] where tasks.first(where: { $0.id == later })?.state == .pending {
                update(later, .skipped)
            }
            phase.failure = message
            phase.notes.append("Databases were not imported: \(message)")
            return phase
        }

        // 1. A copy of the data folder; XAMPP's own stays as it is.
        update("data", .running)
        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            if inventory.dataReadable {
                let source = installation.dataDirectory
                let bytes = inventory.dataBytes
                _ = try await Task.detached { [weak self] in
                    try ProjectCopier.copyFolder(source, to: data, totals: (0, bytes), isCancelled: { flag.isSet }) { progress in
                        Task { @MainActor in self?.progress("data", progress.fraction, detail: "\(Self.bytes(progress.bytes)) of \(Self.bytes(bytes))") }
                    }
                }.value
            } else {
                update("data", .running, detail: "macOS asks for your administrator password.")
                let source = model.quoteForShell(installation.dataDirectory.path)
                let target = model.quoteForShell(data.path)
                let owner = "\(getuid()):\(getgid())"
                let command = "/bin/cp -Rpc \(source) \(target) 2>/dev/null || { /bin/rm -rf \(target); /bin/cp -Rp \(source) \(target); } && /usr/sbin/chown -R \(owner) \(target) && /bin/chmod -R u+rwX \(target)"
                try await model.runAsAdministrator(command, prompt: "DevStack copies XAMPP's database files to read your databases. XAMPP itself is not changed.")
            }
        } catch is CancellationError {
            return phase
        } catch {
            return fail("data", error.localizedDescription)
        }
        update("data", .done, detail: inventory.dataReadable ? Self.bytes(inventory.dataBytes) : nil)
        if flag.isSet { return phase }

        // 2. XAMPP's own MariaDB, privately, on the copy.
        update("server", .running, detail: "Replaying its log can take a minute when XAMPP did not stop cleanly.")
        let names = chosen.map(\.database.name)
        let startup: Result<(recovery: Int, rootHasPassword: Bool?, accounts: [MariaDBAccount], sqlMode: String?, snapshots: [String: DatabaseSnapshot], events: Bool), Error> = await Task.detached {
            do {
                var recovery = 0
                var startError: Error?
                for attempt in 0..<5 {
                    do {
                        try server.start(forceRecovery: recovery, isCancelled: { flag.isSet })
                        startError = nil
                        break
                    } catch let error as MariaDBReaderError {
                        startError = error
                        let log = server.logTail(lines: 60).lowercased()
                        if attempt == 0, log.contains("aria") {
                            // Aria's recovery log often blocks a start after a
                            // crash; the copy can do without it.
                            for entry in (try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? [] where entry.hasPrefix("aria_log") {
                                try? FileManager.default.removeItem(at: data.appendingPathComponent(entry))
                            }
                            continue
                        }
                        guard error.suggestsRecovery, recovery < 3 else { break }
                        recovery += 1
                    }
                }
                if let startError { throw startError }
                let run: (String) throws -> [[String]] = { try server.query($0) }
                let rootHasPassword = MariaDBAccounts.rootHasPassword(run: run)
                let accounts = (try? MariaDBAccounts.read(run: run)) ?? []
                let sqlMode = try? server.query("SELECT @@GLOBAL.sql_mode").first?.first
                var snapshots: [String: DatabaseSnapshot] = [:]
                for name in names { snapshots[name] = try DatabaseInspector.snapshot(of: name, mariaDBEvents: true, run: run) }
                // Events only export while the server checks passwords, which
                // works when root has none, as XAMPP sets it up.
                var events = snapshots.values.allSatisfy { $0.events == 0 }
                if rootHasPassword == false {
                    server.stop()
                    do {
                        try server.start(forceRecovery: recovery, checkPasswords: true, isCancelled: { flag.isSet })
                        events = true
                    } catch {
                        try server.start(forceRecovery: recovery, isCancelled: { flag.isSet })
                    }
                }
                return .success((recovery, rootHasPassword, accounts, sqlMode, snapshots, events))
            } catch {
                return .failure(error)
            }
        }.value
        guard case .success(let source) = startup else {
            if case .failure(let error) = startup {
                if error is CancellationError { return phase }
                return fail("server", error.localizedDescription)
            }
            return phase
        }
        update("server", .done, detail: source.recovery > 0 ? "Started in recovery mode \(source.recovery)" : nil)
        if source.recovery > 0 {
            phase.notes.append("XAMPP's data needed InnoDB recovery mode \(source.recovery) to be read. Check the imported data; rows written just before XAMPP stopped may be missing.")
        }
        if !source.events { phase.notes.append("Scheduled events stay behind: XAMPP's root has a password, and MariaDB only exports events after signing in.") }

        // 3. Exports, kept in Backups as a copy of what XAMPP had.
        update("export", .running)
        var exports: [String: URL] = [:]
        var exportWarnings: [String: [String]] = [:]
        do { try FileManager.default.createDirectory(at: exportsFolder, withIntermediateDirectories: true) }
        catch { return fail("export", error.localizedDescription) }
        for (index, name) in names.enumerated() {
            if flag.isSet { return phase }
            let file = exportsFolder.appendingPathComponent("\(Self.fileName(name)).sql")
            let expected = max(source.snapshots[name]?.bytes ?? 0, 1)
            let label = "\(name) (\(index + 1) of \(names.count))"
            progress("export", Double(index) / Double(names.count), detail: label)
            do {
                let warnings = try await Task.detached { [weak self] in
                    try server.dump(name, to: file, progress: { bytes in
                        Task { @MainActor in
                            self?.progress("export", (Double(index) + min(0.99, Double(bytes) / Double(expected))) / Double(names.count),
                                           detail: "\(label) · \(Self.bytes(bytes))")
                        }
                    }, isCancelled: { flag.isSet })
                }.value
                exports[name] = file
                exportWarnings[name] = warnings
            } catch is CancellationError {
                return phase
            } catch {
                phase.results.append(DatabaseResult(id: name, source: name, target: name, tables: 0, rows: 0, outcome: .failed, message: error.localizedDescription))
            }
        }
        await Task.detached {
            server.stop()
            try? FileManager.default.removeItem(at: data)
        }.value
        update("export", exports.count == names.count ? .done : .warning, detail: "\(exports.count) of \(names.count) exported to Backups")

        // 4. DevStack's MySQL, with XAMPP's sign-in and SQL mode when chosen.
        update("mysql", .running)
        let current = model.configuration.mysql(engine)
        let needsNative = engine == .mysql84 && source.accounts.contains(where: \.needsNativePassword)
        let settings = MySQLSettings(
            rootPassword: rootWithoutPassword ? "" : current.rootPassword,
            sqlMode: matchSQLMode ? source.sqlMode.map { MySQLSettings.sqlMode($0, for: engine) } ?? current.sqlMode : current.sqlMode,
            nativePassword: current.nativePassword || needsNative)
        let manager: DatabaseManager
        do { manager = try await model.prepareDatabaseForImport(engine, settings: settings) }
        catch { return fail("mysql", error.localizedDescription) }
        update("mysql", .done, detail: [settings.rootPassword.isEmpty ? "root signs in without a password" : nil,
                                        matchSQLMode && settings.sqlMode != nil ? "XAMPP's SQL mode" : nil].compactMap { $0 }.joined(separator: ", "))
        if source.rootHasPassword == true {
            phase.notes.append("XAMPP's root had a password. Projects that sign in with it need DevStack's root login from the Database page instead.")
        }

        // 5. Convert, import and count each database.
        update("import", .running)
        var imported: Set<String> = []
        let importer = DatabaseImporter(manager: manager, engine: engine)
        for (index, choice) in chosen.enumerated() {
            if flag.isSet { return phase }
            let name = choice.database.name
            guard let export = exports[name], let snapshot = source.snapshots[name] else { continue }
            let target = choice.targetName
            let replace = choice.exists && choice.clash == .replace
            let label = "\(name)\(target == name ? "" : " → \(target)") (\(index + 1) of \(chosen.count))"
            progress("import", Double(index) / Double(chosen.count), detail: label)
            let converted = workFolder.appendingPathComponent("\(Self.fileName(name)).mysql.sql")
            let size = Double(max(1, (try? export.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1))
            let backupsRoot = model.paths.backups
            let result: Result<(DumpConversionReport, DatabaseSnapshot, URL?), Error> = await Task.detached { [weak self] in
                do {
                    var backup: URL?
                    if replace { backup = try manager.exportSQL(engine, database: target, destination: backupsRoot.appendingPathComponent(manager.backupFilename(engine: engine, database: target))) }
                    let report = try MariaDBDumpConverter.convert(export, to: converted, target: engine, renamed: target == name ? nil : (name, target),
                                                                  isCancelled: { flag.isSet })
                    try importer.importDump(converted, into: target, characterSet: snapshot.characterSet, collation: snapshot.collation, replace: replace,
                                            progress: { sent in
                                                Task { @MainActor in self?.progress("import", (Double(index) + min(0.99, Double(sent) / size)) / Double(chosen.count), detail: nil) }
                                            }, isCancelled: { flag.isSet })
                    try? FileManager.default.removeItem(at: converted)
                    return .success((report, try importer.snapshot(target), backup))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let (report, arrived, backup)):
                imported.insert(target)
                phase.renamed[name] = target
                let differences = snapshot.differences(from: arrived)
                var message = differences.isEmpty ? nil : differences.prefix(4).joined(separator: "; ")
                if !snapshot.unreadable.isEmpty {
                    message = ([message] + ["XAMPP could not read \(snapshot.unreadable.keys.sorted().joined(separator: ", "))"]).compactMap { $0 }.joined(separator: "; ")
                }
                let warnings = (exportWarnings[name] ?? []).filter { !$0.isEmpty }
                phase.results.append(DatabaseResult(id: name, source: name, target: target, tables: arrived.tables.count, rows: arrived.rows,
                                                    outcome: differences.isEmpty && snapshot.unreadable.isEmpty && warnings.isEmpty ? .ok : .warning,
                                                    message: message ?? warnings.first))
                phase.notes += report.notes.sorted().map { "\(target): \($0)" } + report.skipped.map { "\(target): left out \($0)" }
                if let backup { phase.notes.append("\(target) existed in DevStack; its previous contents are in \(backup.lastPathComponent).") }
            case .failure(let error):
                if error is CancellationError { return phase }
                phase.results.append(DatabaseResult(id: name, source: name, target: target, tables: 0, rows: 0, outcome: .failed, message: error.localizedDescription))
            }
        }
        let failed = phase.results.filter { $0.outcome == .failed }.count
        update("import", failed == 0 ? .done : .warning, detail: "\(imported.count) imported\(failed > 0 ? ", \(failed) failed" : "")")
        phase.imported = imported

        // 6. Accounts projects may sign in with.
        update("accounts", .running)
        let accounts = source.accounts.filter { account in
            !account.globalPrivileges.isEmpty || account.databasePrivileges.keys.contains { phase.renamed[$0] != nil }
        }
        if accounts.isEmpty {
            update("accounts", .done, detail: "XAMPP had only root.")
        } else {
            let renamedNow = phase.renamed
            let failures = await Task.detached { importer.createAccounts(accounts, renamed: renamedNow) }.value
            for (account, reason) in failures.sorted(by: { $0.key < $1.key }) { phase.notes.append("Account \(account) was not recreated: \(reason)") }
            update("accounts", failures.isEmpty ? .done : .warning, detail: accounts.map(\.title).joined(separator: ", "))
        }
        return phase
    }

    private func replaceWordPressAddresses(database: String, prefix: String, oldURLs: [String], newURL: String) async -> Int? {
        guard let model else { return nil }
        let engine = model.importDatabaseEngine
        let php = model.phpBinary(phpRuntimeID)
        let configuration = model.phpConfiguration(phpRuntimeID)
        let script = model.paths.generated.appendingPathComponent("wordpress-addresses.php")
        let pairs = WordPressAddressUpdate.pairs(oldURLs: oldURLs, newURL: newURL)
        guard let pairsJSON = try? JSONSerialization.data(withJSONObject: pairs) else { return nil }
        let environment = model.managedEnvironment.merging([
            "DS_HOST": "127.0.0.1", "DS_PORT": String(model.configuration.ports.mysqlListen), "DS_USER": "root",
            "DS_PASSWORD": model.configuration.mysql(engine).rootPassword, "DS_DATABASE": database, "DS_PREFIX": prefix,
            "DS_PAIRS": String(decoding: pairsJSON, as: UTF8.self)
        ]) { _, new in new }
        return await Task.detached {
            do {
                try AtomicFileWriter.write(WordPressAddressUpdate.script, to: script, permissions: 0o600)
                defer { try? FileManager.default.removeItem(at: script) }
                var arguments = ["-d", "pcre.jit=0", "-d", "display_errors=stderr", script.path]
                if FileManager.default.fileExists(atPath: configuration.path) { arguments = ["-c", configuration.path] + arguments }
                let result = try ProcessRunner().runChecked(executable: php, arguments: arguments, environment: environment, timeout: 600)
                return Int(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return nil
            }
        }.value
    }

    // MARK: After-checks

    private func probe(_ placed: [(choice: ProjectChoice, folder: URL)]) async -> [ProjectResult] {
        guard let model else { return [] }
        let port = model.configuration.ports.webHTTPSListen
        var results: [ProjectResult] = []
        for (choice, folder) in placed {
            let url = url(for: choice, folder: folder)
            let site = choice.address == .ownSite
                ? model.configuration.sites.first { $0.hostname == choice.hostname.lowercased() }
                : model.configuration.sites.first { $0.hostname == "localhost" }
            guard let site else {
                results.append(ProjectResult(id: choice.id, name: choice.project.name, url: url, folder: folder.path, outcome: .failed, message: "Its site was not added."))
                continue
            }
            let path: String
            if choice.address == .localhostPath, choice.project.kind == .folder {
                path = "/" + (folder.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folder.lastPathComponent) + "/"
            } else {
                path = "/"
            }
            let log = URL(fileURLWithPath: site.logs.error)
            let host = site.hostname
            let response = await Task.detached { () -> (SiteProbe.Response, [String]) in
                let offset = SiteProbe.size(of: log)
                let response = SiteProbe.request(host: host, port: port, path: path)
                usleep(300_000)
                return (response, SiteProbe.lines(in: log, after: offset))
            }.value
            let (answer, lines) = response
            var outcome: Outcome = .ok
            var message: String?
            if let status = answer.status {
                switch status {
                case 200..<300:
                    if let diagnosis = SiteProbe.diagnosis(lines), lines.contains(where: { $0.lowercased().contains("fatal") }) {
                        outcome = .warning
                        message = diagnosis
                    }
                case 300..<400:
                    if let redirect = answer.redirect, choice.project.originalURLs.contains(where: { redirect.hasPrefix($0) }) {
                        outcome = .warning
                        message = "It sends visitors to its XAMPP address, \(redirect). Update the address in its settings."
                    }
                case 403, 404:
                    outcome = .warning
                    message = status == 404 ? "Not found: the folder may have no index file." : "Forbidden: the folder may have no index file."
                default:
                    outcome = .failed
                    message = SiteProbe.diagnosis(lines) ?? "The site answered with HTTP \(status)."
                }
            } else {
                outcome = .failed
                message = answer.error ?? "The site did not answer."
            }
            results.append(ProjectResult(id: choice.id, name: choice.project.name, url: url, folder: folder.path, outcome: outcome, message: message))
        }
        return results
    }

    /// Extensions XAMPP's PHP loads that DevStack's lacks; nil when XAMPP's
    /// PHP can't run here.
    private func missingExtensions(installation: XAMPPInstallation) async -> [String]? {
        guard let model else { return nil }
        let xampp = installation.php
        let devstack = model.phpBinary(phpRuntimeID)
        let configuration = model.phpConfiguration(phpRuntimeID)
        let environment = model.managedEnvironment
        return await Task.detached {
            func modules(_ php: URL, _ arguments: [String], _ environment: [String: String] = [:]) -> Set<String>? {
                guard let result = try? ProcessRunner().run(executable: php, arguments: arguments + ["-m"], environment: environment, timeout: 20), result.exitCode == 0 else { return nil }
                return Set(result.standardOutput.split(whereSeparator: \.isNewline).map { $0.lowercased() }.filter { !$0.hasPrefix("[") })
            }
            guard let theirs = modules(xampp, []),
                  let ours = modules(devstack, FileManager.default.fileExists(atPath: configuration.path) ? ["-c", configuration.path] : [], environment) else { return nil }
            return theirs.subtracting(ours).subtracting(["xdebug", "zend opcache", "mysqlnd", "pdo_sqlite", "sqlite3"]).sorted()
        }.value
    }

    // MARK: Report

    private func writeReport(_ results: Results, installation: XAMPPInstallation, folder: URL) -> URL? {
        var lines = ["# XAMPP import, \(Self.stamp())", "", "From \(installation.title) in \(installation.location.path). XAMPP was only read.", ""]
        if let failure = results.failure { lines += ["**Stopped:** \(failure)", ""] }
        if results.cancelled { lines += ["**Cancelled.** What finished before stays imported.", ""] }
        if !results.projects.isEmpty {
            lines += ["## Projects", "", "| Project | Address | Folder | Result |", "|---|---|---|---|"]
            for project in results.projects {
                lines.append("| \(project.name) | \(project.url) | \(project.folder) | \(Self.word(project.outcome))\(project.message.map { ": \($0)" } ?? "") |")
            }
            lines.append("")
        }
        if !results.databases.isEmpty {
            lines += ["## Databases", "", "| XAMPP | DevStack | Tables | Rows | Result |", "|---|---|---|---|---|"]
            for database in results.databases {
                lines.append("| \(database.source) | \(database.target) | \(database.tables) | \(database.rows) | \(Self.word(database.outcome))\(database.message.map { ": \($0)" } ?? "") |")
            }
            lines.append("")
        }
        if !results.notes.isEmpty { lines += ["## Notes", ""] + results.notes.map { "- \($0)" } + [""] }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("Report.md")
            try AtomicFileWriter.write(lines.joined(separator: "\n"), to: file, permissions: 0o644)
            return file
        } catch {
            return nil
        }
    }

    private static func word(_ outcome: Outcome) -> String {
        switch outcome { case .ok: "OK"; case .warning: "Check"; case .failed: "Failed" }
    }

    /// A database name as a file name: "my-db" stays, "a/b" becomes "a_b".
    private static func fileName(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return safe.hasPrefix(".") ? "_" + safe.dropFirst() : safe
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: Date())
    }
}
