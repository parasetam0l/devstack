import AppKit
import Combine
import DevStackCore
import Foundation
import ServiceManagement
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum HelperSetupState: Equatable {
    case notInstalled, requiresApproval, connecting, ready
    case unavailable(String)

    var message: String {
        switch self {
        case .notInstalled: "Administrator approval enables local domains and standard web ports."
        case .requiresApproval: "Approve DevStack in System Settings → General → Login Items & Extensions."
        case .connecting: "Connecting to the helper…"
        case .ready: "Authorized and responding."
        case .unavailable(let message): message
        }
    }
    var actionTitle: String {
        switch self {
        case .requiresApproval: "Approve in Settings…"
        case .unavailable: "Retry Setup…"
        default: "Set Up…"
        }
    }
}

enum NavigationSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case sites = "Sites"
    case php = "PHP"
    case database = "Database"
    case mailpit = "Mail Inbox"
    case logs = "Logs"
    case doctor = "Doctor"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .sites: "network"
        case .php: "chevron.left.forwardslash.chevron.right"
        case .database: "cylinder.split.1x2"
        case .mailpit: "envelope"
        case .logs: "doc.text.magnifyingglass"
        case .doctor: "stethoscope"
        case .settings: "gearshape"
        }
    }
}

private struct RuntimeLock: Codable {
    var schemaVersion: Int
    var runtimes: [RuntimeManifest]
}

private struct TrustedRuntimeKeys: Codable {
    var keys: [String: String]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: NavigationSection? = .dashboard
    @Published var selectedLogService: ServiceKind = .apache
    @Published var configuration = AppConfiguration()
    @Published var serviceStates = ServiceKind.allCases.map { ServiceState(service: $0) }
    @Published var runtimeManifests: [RuntimeManifest] = []
    @Published var diagnosticReport: DiagnosticReport?
    @Published var isBusy = false
    @Published var isRunningDoctor = false
    @Published var diagnosticProgress: String?
    @Published var errorMessage: String?
    @Published var helperInstalled = false
    @Published var helperStatus: PrivilegedHelperStatus?
    @Published var helperSetupState: HelperSetupState = .notInstalled
    @Published var lastDatabaseBackup: URL?
    @Published var isPresentingNewSite = false
    @Published var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "DevStackAppearance") ?? "") ?? .system {
        didSet { if !isReviewMode { UserDefaults.standard.set(appearance.rawValue, forKey: "DevStackAppearance") } }
    }

    let paths: DevStackPaths
    let isReviewMode: Bool
    private let store: AppConfigurationStore
    private let supervisor = ServiceSupervisor()
    private let runner = ProcessRunner()
    private let helper = PrivilegedHelperClient()

    init(paths: DevStackPaths = DevStackPaths(), automaticallyLoad: Bool = true) {
        self.paths = paths
        self.isReviewMode = !automaticallyLoad
        self.store = AppConfigurationStore(url: paths.configurationFile)
        if automaticallyLoad { Task { await load() } }
    }

    static func makeForLaunch() -> AppModel {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-review") { return UIReview.makeModel() }
        #endif
        return AppModel()
    }

    func requestNewSite() {
        selectedSection = .sites
        isPresentingNewSite = true
    }

    func runtimeIsAvailable(_ id: String) -> Bool {
        guard let manifest = runtimeManifests.first(where: { $0.id == id }), !manifest.entryPoints.isEmpty else { return false }
        return manifest.entryPoints.values.allSatisfy {
            FileManager.default.fileExists(atPath: paths.builtInRuntimes.appendingPathComponent(id).appendingPathComponent($0).path)
        }
    }

    func extensionIsAvailable(_ name: String, runtimeID: String) -> Bool {
        FileManager.default.fileExists(atPath: paths.builtInRuntimes.appendingPathComponent("\(runtimeID)/lib/php/extensions/\(name).so").path)
    }

    func serviceIsRunning(_ service: ServiceKind) -> Bool {
        serviceStates.first(where: { $0.service == service })?.phase == .running
    }

    var hasRunningServices: Bool {
        serviceStates.contains { $0.phase == .running || $0.phase == .starting }
    }

    var visibleServiceStates: [ServiceState] {
        serviceStates.filter {
            switch $0.service {
            case .php74: configuration.sites.contains { $0.phpRuntimeID == "php-7.4" } || $0.phase != .stopped
            case .mysql57: configuration.selectedDatabase == .mysql57 || $0.phase != .stopped
            case .mysql84: configuration.selectedDatabase == .mysql84 || $0.phase != .stopped
            default: true
            }
        }
    }

    var selectedDatabaseBinding: DatabaseEngine {
        get { configuration.selectedDatabase }
        set {
            configuration.selectedDatabase = newValue
            Task {
                await persistConfiguration()
                await switchDatabaseIfRunning()
            }
        }
    }

    func load() async {
        do {
            try paths.createRequiredDirectories()
            configuration = try await store.load()
            runtimeManifests = try loadRuntimeLock()
            let loginItemEnabled = SMAppService.mainApp.status == .enabled
            if configuration.startAtLogin != loginItemEnabled {
                configuration.startAtLogin = loginItemEnabled
                try await store.save(configuration)
            }
            await refreshHelperStatus()
            await refreshServiceStates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSite(_ site: SiteDefinition) async throws {
        let previous = configuration
        var site = site
        site.hostname = try HostnameValidator.validate(
            site.hostname,
            existing: configuration.sites.filter { $0.id != site.id }.map(\.hostname)
        )
        guard FileManager.default.fileExists(atPath: site.documentRoot) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: site.documentRoot])
        }
        if let index = configuration.sites.firstIndex(where: { $0.id == site.id }) {
            configuration.sites[index] = site
        } else {
            configuration.sites.append(site)
        }
        do {
            try await store.save(configuration)
            try generateConfiguration()
            let apacheState = await supervisor.state(for: .apache)
            if apacheState.phase == .running {
                try await prepareCertificatesAndPrivilegedState()
                try validateWebConfigurations()
                try reloadApache()
            }
        } catch {
            configuration = previous
            try? await store.save(previous)
            try? generateConfiguration()
            throw error
        }
    }

    func deleteSite(_ site: SiteDefinition) async {
        configuration.sites.removeAll { $0.id == site.id }
        await persistConfiguration()
        do { try generateConfiguration() } catch { errorMessage = error.localizedDescription }
    }

    func setExtension(_ name: String, enabled: Bool, runtimeID: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var extensions = configuration.enabledExtensions[runtimeID] ?? []
        if enabled { extensions.insert(name) } else { extensions.remove(name) }
        configuration.enabledExtensions[runtimeID] = extensions
        await persistConfiguration()
        do {
            try generateConfiguration()
            let service: ServiceKind = runtimeID == "php-7.4" ? .php74 : .php85
            let state = await supervisor.state(for: service)
            if state.phase == .running {
                await supervisor.stop(service)
                try await startPHP(runtimeID: runtimeID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startAll() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try generateConfiguration()
            try validateRequiredRuntimes()
            try await prepareCertificatesAndPrivilegedState()
            try await startMailpit()
            let initializedDatabase = try databaseManager.initializeIfNeeded(configuration.selectedDatabase)
            try await startDatabase(configuration.selectedDatabase)
            if initializedDatabase { try databaseManager.configureDevelopmentRootPassword(configuration.selectedDatabase) }
            let phpRuntimes = Set(configuration.sites.map(\.phpRuntimeID)).union(["php-8.5"])
            for runtimeID in phpRuntimes.sorted() { try await startPHP(runtimeID: runtimeID) }
            try verifyLegacyDatabaseCompatibilityIfNeeded()
            try validateWebConfigurations()
            try await startApache()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshServiceStates()
    }

    func stopAll() async {
        guard !isBusy else { return }
        isBusy = true
        await supervisor.stopAll()
        await refreshServiceStates()
        isBusy = false
    }

    func refreshServiceStates() async {
        serviceStates = await supervisor.allStates()
    }

    func runDoctor() async {
        guard !isRunningDoctor else { return }
        isRunningDoctor = true
        diagnosticProgress = "Preparing checks…"
        defer { isRunningDoctor = false; diagnosticProgress = nil }
        await refreshServiceStates()
        if helper.isRegistered { helperStatus = try? await helper.status() }
        let context = DiagnosticContext(
            paths: paths,
            runtimeManifests: runtimeManifests,
            applicationURL: Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil,
            helperInstalled: helperInstalled,
            helperStatus: helperStatus,
            expectedHostnames: configuration.sites.map(\.hostname) + ["phpmyadmin.devstack.test", "mailpit.devstack.test"],
            serviceStates: serviceStates,
            selectedDatabase: configuration.selectedDatabase
        )
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let progressModel = self
        diagnosticReport = await Task.detached {
            DevStackDoctor().run(context: context, appVersion: appVersion) { step in
                Task { @MainActor in progressModel.diagnosticProgress = step }
            }
        }.value
    }

    func installHelper() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try helper.register()
            await refreshHelperStatus()
            if helperSetupState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            helperInstalled = false
            helperSetupState = .unavailable("Setup failed: \(error.localizedDescription)")
        }
    }

    func refreshHelperStatus() async {
        guard !isReviewMode else { return }
        switch helper.registrationStatus {
        case .requiresApproval:
            helperInstalled = false; helperStatus = nil; helperSetupState = .requiresApproval
        case .enabled:
            helperSetupState = .connecting
            do {
                helperStatus = try await helper.status()
                helperInstalled = true
                helperSetupState = .ready
            } catch {
                helperInstalled = false; helperStatus = nil
                helperSetupState = .unavailable("The registered helper did not respond: \(error.localizedDescription)")
            }
        case .notRegistered:
            helperInstalled = false; helperStatus = nil; helperSetupState = .notInstalled
        case .notFound:
            helperInstalled = false; helperStatus = nil
            helperSetupState = .unavailable("macOS could not find the helper. Reinstall the signed DevStack app in Applications.")
        @unknown default:
            helperInstalled = false; helperStatus = nil
            helperSetupState = .unavailable("macOS reported an unknown helper registration state.")
        }
    }

    func removeHelper() async {
        guard !isBusy, !hasRunningServices else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if helper.isRegistered { try await helper.removeManagedState() }
            try await helper.unregister()
            helperStatus = nil
            helperInstalled = false
            helperSetupState = .notInstalled
        } catch {
            errorMessage = "Could not remove the privileged helper: \(error.localizedDescription)"
        }
    }

    func setStartAtLogin(_ enabled: Bool) async {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try await service.unregister()
            }
            configuration.startAtLogin = SMAppService.mainApp.status == .enabled
            try await store.save(configuration)
        } catch {
            errorMessage = "Could not update the login item: \(error.localizedDescription)"
            configuration.startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func importRuntimePack(from archive: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let keyData = try loadTrustedRuntimeKeys()
            let destination = paths.importedRuntimes
            let manifest = try await Task.detached {
                let verifier = RuntimePackVerifier(trustedPublicKeys: keyData)
                return try RuntimePackImporter(verifier: verifier).importArchive(archive, into: destination)
            }.value
            if !configuration.importedRuntimeIDs.contains(manifest.id) {
                configuration.importedRuntimeIDs.append(manifest.id)
                configuration.importedRuntimeIDs.sort()
                try await store.save(configuration)
            }
            runtimeManifests.removeAll { $0.id == manifest.id }
            runtimeManifests.append(manifest)
        } catch {
            errorMessage = "Runtime pack was rejected: \(error.localizedDescription)"
        }
    }

    func exportSupportBundle(to destination: URL) {
        guard let diagnosticReport else { return }
        do {
            try SupportBundleExporter().export(report: diagnosticReport, paths: paths, to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    func clearMailpit() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let url = URL(string: "http://127.0.0.1:8025/api/v1/messages") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        } catch {
            errorMessage = "Could not clear Mailpit: \(error.localizedDescription)"
        }
    }

    func databaseBackupFilename() -> String {
        databaseManager.backupFilename(engine: configuration.selectedDatabase, database: nil)
    }

    func exportDatabase(to destination: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            await refreshServiceStates()
            let engine = configuration.selectedDatabase
            try requireRunningDatabase(engine)
            lastDatabaseBackup = try databaseManager.exportSQL(engine, destination: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importDatabase(from source: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            await refreshServiceStates()
            let engine = configuration.selectedDatabase
            try requireRunningDatabase(engine)
            lastDatabaseBackup = try databaseManager.exportSQL(engine)
            try databaseManager.importSQL(engine, source: source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetDatabase() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let engine = configuration.selectedDatabase
        let kind: ServiceKind = engine == .mysql57 ? .mysql57 : .mysql84
        do {
            await refreshServiceStates()
            if serviceStates.first(where: { $0.service == kind })?.phase == .running {
                lastDatabaseBackup = try databaseManager.exportSQL(engine)
            }
            await supervisor.stop(kind)
            if FileManager.default.fileExists(atPath: databaseManager.dataDirectoryURL(engine).path) {
                let archived = try databaseManager.archiveDataDirectory(engine)
                if lastDatabaseBackup == nil { lastDatabaseBackup = archived }
            }
            let initialized = try databaseManager.initializeIfNeeded(engine)
            if initialized { try databaseManager.configureDevelopmentRootPassword(engine) }
            try await startDatabase(engine)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshServiceStates()
    }

    func openManagedShell() {
        do {
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("DevStack-\(UUID().uuidString).command")
            let contents = """
            #!/bin/zsh
            export PATH=\(shellQuote(managedPath)):$PATH
            export PHPRC=\(shellQuote(paths.generatedPHP.appendingPathComponent("php-8.5.ini").path))
            export MYSQL_UNIX_PORT=\(shellQuote(paths.sockets.appendingPathComponent("mysql.sock").path))
            rm -f -- "$0"
            exec /bin/zsh -l
            """
            try AtomicFileWriter.write(contents, to: script, permissions: 0o700)
            NSWorkspace.shared.open(script)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyManagedEnvironmentCommand() {
        let command = "export PATH=\(shellQuote(managedPath)):\"$PATH\"\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func logContents(for service: ServiceKind) -> String {
        let url = paths.logs.appendingPathComponent("\(service.rawValue).log")
        guard let data = try? Data(contentsOf: url) else { return "No log output yet." }
        return String(decoding: data.suffix(200_000), as: UTF8.self)
    }

    private func persistConfiguration() async {
        do { try await store.save(configuration) } catch { errorMessage = error.localizedDescription }
    }

    private var databaseManager: DatabaseManager {
        DatabaseManager(paths: paths, runtimeRoot: paths.builtInRuntimes)
    }

    private var managedPath: String {
        [
            paths.builtInRuntimes.appendingPathComponent("php-8.5/bin").path,
            paths.builtInRuntimes.appendingPathComponent("\(configuration.selectedDatabase.rawValue)/bin").path,
            paths.generated.appendingPathComponent("bin").path
        ].joined(separator: ":")
    }

    private func requireRunningDatabase(_ engine: DatabaseEngine) throws {
        let kind: ServiceKind = engine == .mysql57 ? .mysql57 : .mysql84
        guard serviceStates.first(where: { $0.service == kind })?.phase == .running else {
            throw CocoaError(.executableNotLoadable, userInfo: [NSLocalizedDescriptionKey: "Start \(engine.displayName) before exporting, importing, or resetting the database."])
        }
    }

    private func generateConfiguration() throws {
        try paths.createRequiredDirectories()
        let renderer = ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes)
        let mailpit = paths.builtInRuntimes.appendingPathComponent("mailpit-1.31.1/mailpit")
        try AtomicFileWriter.write(try renderer.apacheConfiguration(sites: configuration.sites), to: paths.generatedApache.appendingPathComponent("httpd.conf"), permissions: 0o644)
        for runtimeID in ["php-7.4", "php-8.5"] {
            try AtomicFileWriter.write(
                try renderer.phpFPMConfiguration(runtimeID: runtimeID, sites: configuration.sites, includeManagementPool: runtimeID == "php-8.5"),
                to: paths.generatedPHP.appendingPathComponent("\(runtimeID)-fpm.conf"),
                permissions: 0o600
            )
            try AtomicFileWriter.write(
                try renderer.phpINI(runtimeID: runtimeID, enabledExtensions: configuration.enabledExtensions[runtimeID] ?? [], mailpitBinary: mailpit),
                to: paths.generatedPHP.appendingPathComponent("\(runtimeID).ini"),
                permissions: 0o600
            )
        }
        for engine in DatabaseEngine.allCases {
            let base = paths.builtInRuntimes.appendingPathComponent(engine.rawValue)
            try AtomicFileWriter.write(renderer.mysqlConfiguration(engine: engine, baseDirectory: base), to: paths.generated.appendingPathComponent("\(engine.rawValue).cnf"), permissions: 0o600)
        }
        try AtomicFileWriter.write(renderer.composerWrapperScript(), to: paths.generated.appendingPathComponent("bin/composer"), permissions: 0o755)
    }

    private func validateRequiredRuntimes() throws {
        var required = ["apache-2.4", "php-8.5", configuration.selectedDatabase.rawValue, "mailpit-1.31.1", "phpmyadmin-5.2.3", "openssl-3.5"]
        if configuration.sites.contains(where: { $0.phpRuntimeID == "php-7.4" }) { required.append("php-7.4") }
        let missing = required.filter { !FileManager.default.fileExists(atPath: paths.builtInRuntimes.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Runtime payloads are not installed: \(missing.joined(separator: ", ")). Build or import signed runtime packs first."])
        }
    }

    private func validateWebConfigurations() throws {
        let apache = paths.builtInRuntimes.appendingPathComponent("apache-2.4/bin/httpd")
        _ = try runner.runChecked(executable: apache, arguments: ["-t", "-f", paths.generatedApache.appendingPathComponent("httpd.conf").path])
        for runtimeID in Set(configuration.sites.map(\.phpRuntimeID)).union(["php-8.5"]) {
            let fpm = paths.builtInRuntimes.appendingPathComponent("\(runtimeID)/sbin/php-fpm")
            _ = try runner.runChecked(executable: fpm, arguments: ["-t", "-y", paths.generatedPHP.appendingPathComponent("\(runtimeID)-fpm.conf").path, "-c", paths.generatedPHP.appendingPathComponent("\(runtimeID).ini").path])
        }
    }

    private func reloadApache() throws {
        let apache = paths.builtInRuntimes.appendingPathComponent("apache-2.4/bin/httpd")
        _ = try runner.runChecked(executable: apache, arguments: ["-k", "graceful", "-f", paths.generatedApache.appendingPathComponent("httpd.conf").path])
    }

    private func prepareCertificatesAndPrivilegedState() async throws {
        guard helper.isRegistered else {
            throw CocoaError(.executableNotLoadable, userInfo: [NSLocalizedDescriptionKey: "Install the DevStack privileged helper in Settings before starting services."])
        }
        let certificates = CertificateManager(
            paths: paths,
            openssl: paths.builtInRuntimes.appendingPathComponent("openssl-3.5/bin/openssl")
        )
        let managementHosts = ["phpmyadmin.devstack.test", "mailpit.devstack.test"]
        let TLSHosts = configuration.sites.filter(\.tlsEnabled).map(\.hostname) + managementHosts
        try certificates.ensureCertificates(for: TLSHosts)
        let hostnames = configuration.sites.map(\.hostname) + managementHosts
        try await helper.applyHostMappings(hostnames.map { HostMapping(hostname: $0) })
        try await helper.setPortForwarding(.init(enabled: true))
        var status = try await helper.status()
        if !status.localCATrusted {
            try await helper.trustLocalCA(certificates.caCertificateDER())
            status.localCATrusted = true
        }
        helperStatus = status
        helperInstalled = true
    }

    private func verifyLegacyDatabaseCompatibilityIfNeeded() throws {
        guard configuration.selectedDatabase == .mysql84,
              configuration.sites.contains(where: { $0.phpRuntimeID == "php-7.4" }) else { return }
        let php = paths.builtInRuntimes.appendingPathComponent("php-7.4/bin/php")
        let code = #"mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT); $db = new mysqli('127.0.0.1', 'root', 'root', '', 3306); $db->query('SELECT 1');"#
        _ = try runner.runChecked(
            executable: php,
            arguments: ["-c", paths.generatedPHP.appendingPathComponent("php-7.4.ini").path, "-r", code],
            timeout: 30
        )
    }

    private func startApache() async throws {
        try await supervisor.start(ServiceSpecification(
            kind: .apache,
            executable: paths.builtInRuntimes.appendingPathComponent("apache-2.4/bin/httpd"),
            arguments: ["-D", "FOREGROUND", "-f", paths.generatedApache.appendingPathComponent("httpd.conf").path],
            logFile: paths.logs.appendingPathComponent("apache.log"),
            readinessProbe: .tcpLoopback(port: 8080)
        ))
    }

    private func startPHP(runtimeID: String) async throws {
        let kind: ServiceKind = runtimeID == "php-7.4" ? .php74 : .php85
        let sites = configuration.sites.filter { $0.phpRuntimeID == runtimeID }
        let probe: ReadinessProbe = sites.first.map { .fileExists(paths.phpSocket(runtimeID: runtimeID, siteID: $0.id)) }
            ?? .fileExists(paths.sockets.appendingPathComponent("php-8.5-management.sock"))
        try await supervisor.start(ServiceSpecification(
            kind: kind,
            executable: paths.builtInRuntimes.appendingPathComponent("\(runtimeID)/sbin/php-fpm"),
            arguments: ["--nodaemonize", "--fpm-config", paths.generatedPHP.appendingPathComponent("\(runtimeID)-fpm.conf").path, "--php-ini", paths.generatedPHP.appendingPathComponent("\(runtimeID).ini").path],
            logFile: paths.logs.appendingPathComponent("\(runtimeID).log"),
            readinessProbe: probe
        ))
    }

    private func startDatabase(_ engine: DatabaseEngine) async throws {
        let kind: ServiceKind = engine == .mysql57 ? .mysql57 : .mysql84
        try await supervisor.start(ServiceSpecification(
            kind: kind,
            executable: paths.builtInRuntimes.appendingPathComponent("\(engine.rawValue)/bin/mysqld"),
            arguments: ["--defaults-file=\(paths.generated.appendingPathComponent("\(engine.rawValue).cnf").path)"],
            logFile: paths.logs.appendingPathComponent("\(engine.rawValue).log"),
            readinessProbe: .tcpLoopback(port: 3306),
            readinessTimeout: 30
        ))
    }

    private func startMailpit() async throws {
        let renderer = ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes)
        try await supervisor.start(ServiceSpecification(
            kind: .mailpit,
            executable: paths.builtInRuntimes.appendingPathComponent("mailpit-1.31.1/mailpit"),
            arguments: renderer.mailpitArguments(),
            logFile: paths.logs.appendingPathComponent("mailpit.log"),
            readinessProbe: .tcpLoopback(port: 8025)
        ))
    }

    private func switchDatabaseIfRunning() async {
        let old: ServiceKind = configuration.selectedDatabase == .mysql84 ? .mysql57 : .mysql84
        let oldState = await supervisor.state(for: old)
        let selectedKind: ServiceKind = configuration.selectedDatabase == .mysql57 ? .mysql57 : .mysql84
        let selectedState = await supervisor.state(for: selectedKind)
        if oldState.phase == .running || selectedState.phase == .running {
            await supervisor.stop(old)
            if selectedState.phase != .running {
                do { try await startDatabase(configuration.selectedDatabase) } catch { errorMessage = error.localizedDescription }
            }
        }
        await refreshServiceStates()
    }

    private func loadRuntimeLock() throws -> [RuntimeManifest] {
        guard let url = DevStackResources.bundle.url(forResource: "runtime-lock", withExtension: "json") else { return [] }
        var manifests = try JSONDecoder().decode(RuntimeLock.self, from: Data(contentsOf: url)).runtimes
        for id in configuration.importedRuntimeIDs {
            let manifestURL = paths.importedRuntimes.appendingPathComponent(id).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let pack = try? JSONDecoder().decode(RuntimePackManifest.self, from: data) else { continue }
            manifests.removeAll { $0.id == pack.runtime.id }
            manifests.append(pack.runtime)
        }
        return manifests
    }

    private func loadTrustedRuntimeKeys() throws -> [String: Data] {
        guard let url = DevStackResources.bundle.url(forResource: "trusted-runtime-keys", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let document = try JSONDecoder().decode(TrustedRuntimeKeys.self, from: Data(contentsOf: url))
        return try document.keys.mapValues { encoded in
            guard let data = Data(base64Encoded: encoded), data.count == 32 else {
                throw CocoaError(.coderReadCorrupt)
            }
            return data
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
