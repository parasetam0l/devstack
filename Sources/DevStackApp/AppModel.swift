import AppKit
import Combine
import CryptoKit
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
        case .notInstalled: "Administrator approval enables custom domains and standard web ports."
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
    @Published var localCATrusted = false
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
    private let supervisor: ServiceSupervisor
    private let runner = ProcessRunner()
    private let helper = PrivilegedHelperClient()
    private var runtimeEnvironment: [String: String] {
        RuntimeEnvironment.services(openssl: runtimeDirectory("openssl-3.5"), imageMagick: runtimeDirectory("imagemagick-7.1"), phpConfiguration: paths.generatedPHP)
    }

    init(paths: DevStackPaths = DevStackPaths(), automaticallyLoad: Bool = true) {
        self.paths = paths
        self.supervisor = ServiceSupervisor(recordsURL: paths.generated.appendingPathComponent("processes.json"))
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

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        for window in NSApp.windows { window.appearance = NSApp.appearance }
    }

    func requestNewSite() {
        selectedSection = .sites
        isPresentingNewSite = true
    }

    func runtimeIsAvailable(_ id: String) -> Bool {
        guard let manifest = runtimeManifests.first(where: { $0.id == id }), !manifest.entryPoints.isEmpty else { return false }
        return manifest.entryPoints.values.allSatisfy {
            FileManager.default.fileExists(atPath: runtimeDirectory(id).appendingPathComponent($0).path)
        }
    }

    func extensionIsAvailable(_ name: String, runtimeID: String) -> Bool {
        FileManager.default.fileExists(atPath: runtimeDirectory(runtimeID).appendingPathComponent("lib/php/extensions/\(name).so").path)
    }

    func serviceIsRunning(_ service: ServiceKind) -> Bool {
        serviceStates.first(where: { $0.service == service })?.phase == .running
    }

    var hasRunningServices: Bool {
        serviceStates.contains { $0.phase == .running || $0.phase == .starting }
    }

    var stackIsRunning: Bool {
        dashboardServices.allSatisfy(serviceIsRunning)
            && requiredPHPRuntimes.allSatisfy { id in ServiceKind(rawValue: id).map(serviceIsRunning) == true }
    }

    var availablePHPRuntimes: [RuntimeManifest] {
        runtimeManifests.filter { $0.kind == .php && runtimeIsAvailable($0.id) }.sorted { $0.version > $1.version }
    }

    func serviceState(_ service: ServiceKind) -> ServiceState {
        serviceStates.first { $0.service == service } ?? ServiceState(service: service)
    }

    private var requiredPHPRuntimes: Set<String> {
        Set(configuration.sites.map(\.phpRuntimeID)).union(["php-8.5", configuration.defaultPHPRuntimeID])
    }

    var dashboardServices: [ServiceKind] {
        [configuration.selectedWebServer.service, ServiceKind(rawValue: configuration.defaultPHPRuntimeID) ?? .php85,
         configuration.selectedDatabase == .mysql84 ? .mysql84 : .mysql57, .mailpit]
    }

    var selectedDatabaseBinding: DatabaseEngine {
        get { configuration.selectedDatabase }
        set { Task { await selectDatabase(newValue) } }
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
            localCATrusted = certificateManager.isTrusted()
            await refreshServiceStates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSite(_ site: SiteDefinition) async throws {
        var site = site
        site.hostname = try HostnameValidator.validate(site.hostname, existing: configuration.sites.filter { $0.id != site.id }.map(\.hostname))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: site.documentRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: site.documentRoot])
        }
        var sites = configuration.sites
        if let index = sites.firstIndex(where: { $0.id == site.id }) { sites[index] = site }
        else { sites.append(site) }
        try await applySites(sites)
    }

    func deleteSite(_ site: SiteDefinition) async {
        do { try await applySites(configuration.sites.filter { $0.id != site.id }) }
        catch { errorMessage = error.localizedDescription }
    }

    private func applySites(_ sites: [SiteDefinition]) async throws {
        guard !isBusy else { throw CocoaError(.userCancelled) }
        isBusy = true
        defer { isBusy = false }
        let previous = configuration
        let webRunning = (await supervisor.allStates()).contains { ($0.service == .apache || $0.service == .nginx) && $0.phase == .running }
        configuration.sites = sites
        do {
            try generateConfiguration()
            if webRunning {
                try await prepareCertificatesAndPrivilegedState()
                try await validateWebConfigurations()
                try await refreshWebServices()
            }
            try await store.save(configuration)
        } catch {
            configuration = previous
            try? generateConfiguration()
            if webRunning {
                try? await prepareCertificatesAndPrivilegedState()
                try? await refreshWebServices()
            }
            await refreshServiceStates()
            throw error
        }
        await refreshServiceStates()
    }

    private func refreshWebServices() async throws {
        let states = await supervisor.allStates()
        let requiredPHP = requiredPHPRuntimes
        for state in states where state.service.phpRuntimeID != nil && state.phase == .running {
            await supervisor.stop(state.service)
        }
        for id in requiredPHP.sorted() { try await startPHP(runtimeID: id) }
        if states.contains(where: { $0.service == .apache && $0.phase == .running }) { try await reloadApache() }
        if states.contains(where: { $0.service == .nginx && $0.phase == .running }) { try await supervisor.reload(.nginx) }
    }

    func setExtension(_ name: String, enabled: Bool, runtimeID: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var extensions = (configuration.enabledExtensions[runtimeID] ?? []).filter { extensionIsAvailable($0, runtimeID: runtimeID) }
        if enabled { extensions.insert(name) } else { extensions.remove(name) }
        configuration.enabledExtensions[runtimeID] = extensions
        await persistConfiguration()
        do {
            try generateConfiguration()
            let service = ServiceKind(rawValue: runtimeID)!
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
        let previouslyRunning = Set((await supervisor.allStates()).filter { $0.phase == .running }.map(\.service))
        do {
            try generateConfiguration()
            try validateRequiredRuntimes()
            try await prepareCertificatesAndPrivilegedState()
            try await validateWebConfigurations()
            try await startMailpit()
            let manager = databaseManager
            let engine = configuration.selectedDatabase
            let initializedDatabase = try await Task.detached { try manager.initializeIfNeeded(engine) }.value
            try await startDatabase(engine)
            if initializedDatabase { try await Task.detached { try manager.configureDevelopmentRootPassword(engine) }.value }
            let phpRuntimes = requiredPHPRuntimes
            for runtimeID in phpRuntimes.sorted() { try await startPHP(runtimeID: runtimeID) }
            try verifyLegacyDatabaseCompatibilityIfNeeded()
            try await validateWebConfigurations()
            await supervisor.stop(configuration.selectedWebServer == .apache ? .nginx : .apache)
            if configuration.selectedWebServer == .apache { try await startApache() }
            else { try await startNginx() }
        } catch {
            for state in await supervisor.allStates() where state.phase == .running && !previouslyRunning.contains(state.service) {
                await supervisor.stop(state.service)
            }
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
        await refreshHelperStatus()
        let context = DiagnosticContext(
            paths: paths,
            runtimeManifests: runtimeManifests,
            applicationURL: Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil,
            helperInstalled: helperInstalled,
            helperStatus: helperStatus,
            expectedHostnames: configuration.sites.map(\.hostname) + ["phpmyadmin.localhost", "mailpit.localhost", "adminer.localhost"],
            serviceStates: serviceStates,
            requiredRuntimeIDs: Set(configuration.sites.map(\.phpRuntimeID)).union([configuration.selectedDatabase.rawValue, "php-8.5"]),
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

    var helperIsRegistered: Bool { helper.registrationStatus == .enabled || helper.registrationStatus == .requiresApproval }

    func refreshHelperStatus() async {
        guard !isReviewMode else { return }
        guard helper.canAuthenticate else {
            helperInstalled = false; helperStatus = nil
            helperSetupState = .unavailable("Standard ports require a Developer ID signed release. This development build uses ports 8080 and 8443.")
            return
        }
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

    private var certificateManager: CertificateManager {
        CertificateManager(paths: paths, openssl: runtimeDirectory("openssl-3.5").appendingPathComponent("bin/openssl"))
    }

    func trustHTTPS() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let certificates = certificateManager
        do {
            try await Task.detached { try certificates.trustForCurrentUser() }.value
            localCATrusted = certificates.isTrusted()
        } catch { errorMessage = "HTTPS trust: \(error.localizedDescription)" }
    }

    func removeHelper() async {
        guard !isBusy, !hasRunningServices else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if helper.isRegistered && helper.canAuthenticate { try await helper.removeManagedState() }
            try await helper.unregister()
            helperStatus = nil
            helperInstalled = false
            await refreshHelperStatus()
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
            let manager = databaseManager
            lastDatabaseBackup = try await Task.detached { try manager.exportSQL(engine, destination: destination) }.value
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
            let manager = databaseManager
            lastDatabaseBackup = try await Task.detached { try manager.exportSQL(engine) }.value
            try await Task.detached { try manager.importSQL(engine, source: source) }.value
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
        let manager = databaseManager
        do {
            await refreshServiceStates()
            if serviceStates.first(where: { $0.service == kind })?.phase == .running {
                lastDatabaseBackup = try await Task.detached { try manager.exportSQL(engine) }.value
            }
            await supervisor.stop(kind)
            if FileManager.default.fileExists(atPath: databaseManager.dataDirectoryURL(engine).path) {
                let archived = try databaseManager.archiveDataDirectory(engine)
                if lastDatabaseBackup == nil { lastDatabaseBackup = archived }
            }
            let initialized = try await Task.detached { try manager.initializeIfNeeded(engine) }.value
            try await startDatabase(engine)
            if initialized { try await Task.detached { try manager.configureDevelopmentRootPassword(engine) }.value }
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
            \(managedRuntimeEnvironmentCommand)
            export PHPRC=\(shellQuote(paths.generatedPHP.appendingPathComponent("\(configuration.defaultPHPRuntimeID).ini").path))
            export MYSQL_UNIX_PORT=\(shellQuote(paths.sockets.appendingPathComponent("mysql.sock").path))
            rm -f -- "$0"
            exec /bin/zsh -i
            """
            try AtomicFileWriter.write(contents, to: script, permissions: 0o700)
            NSWorkspace.shared.open(script)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyManagedEnvironmentCommand() {
        let command = "export PATH=\(shellQuote(managedPath)):\"$PATH\"\n\(managedRuntimeEnvironmentCommand)\nexport PHPRC=\(shellQuote(paths.generatedPHP.appendingPathComponent("\(configuration.defaultPHPRuntimeID).ini").path))\nexport MYSQL_UNIX_PORT=\(shellQuote(paths.sockets.appendingPathComponent("mysql.sock").path))\n"
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
        DatabaseManager(paths: paths, runtimeRoot: configuration.importedRuntimeIDs.contains(configuration.selectedDatabase.rawValue) ? paths.importedRuntimes : paths.builtInRuntimes,
            opensslRuntime: runtimeDirectory("openssl-3.5"))
    }

    private var managedPath: String {
        [
            paths.generated.appendingPathComponent("bin").path,
            runtimeDirectory(configuration.defaultPHPRuntimeID).appendingPathComponent("bin").path,
            runtimeDirectory(configuration.selectedDatabase.rawValue).appendingPathComponent("bin").path
        ].joined(separator: ":")
    }

    private var managedRuntimeEnvironmentCommand: String {
        runtimeEnvironment.map { "export \($0.key)=\(shellQuote($0.value))" }.sorted().joined(separator: "\n")
    }

    private func requireRunningDatabase(_ engine: DatabaseEngine) throws {
        let kind: ServiceKind = engine == .mysql57 ? .mysql57 : .mysql84
        guard serviceStates.first(where: { $0.service == kind })?.phase == .running else {
            throw CocoaError(.executableNotLoadable, userInfo: [NSLocalizedDescriptionKey: "Start \(engine.displayName) before exporting, importing, or resetting the database."])
        }
    }

    private func generateConfiguration() throws {
        try paths.createRequiredDirectories()
        let renderer = configurationRenderer
        let mailpit = runtimeDirectory("mailpit-1.31.1").appendingPathComponent("mailpit")
        let cookieSecretURL = paths.phpMyAdmin.appendingPathComponent("cookie-secret")
        let cookieSecret: String
        if FileManager.default.fileExists(atPath: cookieSecretURL.path) {
            cookieSecret = try String(contentsOf: cookieSecretURL, encoding: .utf8)
        } else {
            cookieSecret = SymmetricKey(size: .bits256).withUnsafeBytes { String(Data($0).base64EncodedString().prefix(32)) }
            try AtomicFileWriter.write(cookieSecret, to: cookieSecretURL, permissions: 0o600)
        }
        try AtomicFileWriter.write(try renderer.phpMyAdminConfiguration(cookieSecret: cookieSecret),
            to: paths.phpMyAdmin.appendingPathComponent("config.inc.php"), permissions: 0o600)
        try AtomicFileWriter.write(try renderer.apacheConfiguration(sites: configuration.sites), to: paths.generatedApache.appendingPathComponent("httpd.conf"), permissions: 0o644)
        for runtimeID in ["php-7.4", "php-8.4", "php-8.5"] {
            try AtomicFileWriter.write(
                try renderer.phpFPMConfiguration(runtimeID: runtimeID, sites: configuration.sites, includeManagementPool: runtimeID == "php-8.5"),
                to: paths.generatedPHP.appendingPathComponent("\(runtimeID)-fpm.conf"),
                permissions: 0o600
            )
            try AtomicFileWriter.write(
                try renderer.phpINI(runtimeID: runtimeID, enabledExtensions: (configuration.enabledExtensions[runtimeID] ?? []).filter { extensionIsAvailable($0, runtimeID: runtimeID) }, mailpitBinary: mailpit),
                to: paths.generatedPHP.appendingPathComponent("\(runtimeID).ini"),
                permissions: 0o600
            )
        }
        try AtomicFileWriter.write(try renderer.nginxConfiguration(sites: configuration.sites), to: paths.generatedNginx.appendingPathComponent("nginx.conf"), permissions: 0o600)
        for engine in DatabaseEngine.allCases {
            let base = runtimeDirectory(engine.rawValue)
            try AtomicFileWriter.write(renderer.mysqlConfiguration(engine: engine, baseDirectory: base), to: paths.generated.appendingPathComponent("\(engine.rawValue).cnf"), permissions: 0o600)
        }
        try AtomicFileWriter.write(renderer.composerWrapperScript(runtimeID: configuration.defaultPHPRuntimeID), to: paths.generated.appendingPathComponent("bin/composer"), permissions: 0o755)
        for client in ["mysql", "mysqldump", "mysqladmin"] {
            try AtomicFileWriter.write(try renderer.databaseClientWrapperScript(engine: configuration.selectedDatabase, client: client),
                to: paths.generated.appendingPathComponent("bin/\(client)"), permissions: 0o755)
        }
    }

    private func validateRequiredRuntimes() throws {
        var required = [configuration.selectedWebServer.service.runtimeID, "php-8.5", configuration.selectedDatabase.rawValue, "mailpit-1.31.1", "phpmyadmin-5.2.3", "adminer-6.1.1", "openssl-3.5"]
        required.append(contentsOf: requiredPHPRuntimes)
        let missing = required.filter { !runtimeIsAvailable($0) }
        guard missing.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Runtime payloads are not installed: \(missing.joined(separator: ", ")). Build or import signed runtime packs first."])
        }
    }

    private func validateWebConfigurations() async throws {
        var checks: [(URL, [String])] = []
        if configuration.selectedWebServer == .apache {
            checks.append((runtimeDirectory("apache-2.4").appendingPathComponent("bin/httpd"),
                ["-t", "-f", paths.generatedApache.appendingPathComponent("httpd.conf").path]))
        } else {
            checks.append((runtimeDirectory("nginx-1.30").appendingPathComponent("sbin/nginx"),
                ["-t", "-p", paths.generatedNginx.path + "/", "-c", paths.generatedNginx.appendingPathComponent("nginx.conf").path]))
        }
        for id in requiredPHPRuntimes {
            checks.append((runtimeDirectory(id).appendingPathComponent("sbin/php-fpm"),
                ["-t", "-y", paths.generatedPHP.appendingPathComponent("\(id)-fpm.conf").path, "-c", paths.generatedPHP.appendingPathComponent("\(id).ini").path]))
        }
        let commands = checks
        let environment = runtimeEnvironment
        let runner = runner
        try await Task.detached {
            for (executable, arguments) in commands {
                _ = try runner.runChecked(executable: executable, arguments: arguments, environment: environment)
            }
        }.value
    }

    private func reloadApache() async throws {
        let executable = runtimeDirectory("apache-2.4").appendingPathComponent("bin/httpd")
        let arguments = ["-k", "graceful", "-f", paths.generatedApache.appendingPathComponent("httpd.conf").path]
        let environment = runtimeEnvironment
        let runner = runner
        try await Task.detached { _ = try runner.runChecked(executable: executable, arguments: arguments, environment: environment) }.value
    }

    private func prepareCertificatesAndPrivilegedState() async throws {
        let certificates = CertificateManager(
            paths: paths,
            openssl: runtimeDirectory("openssl-3.5").appendingPathComponent("bin/openssl")
        )
        let managementHosts = ["phpmyadmin.localhost", "mailpit.localhost", "adminer.localhost"]
        let TLSHosts = configuration.sites.filter(\.tlsEnabled).map(\.hostname) + managementHosts
        try await Task.detached {
            try certificates.ensureCertificates(for: TLSHosts)
            try certificates.refreshTrustBundle()
        }.value
        localCATrusted = certificates.isTrusted()
        guard helperInstalled else { return }
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
        let php = runtimeDirectory("php-7.4").appendingPathComponent("bin/php")
        let code = #"mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT); $db = new mysqli('127.0.0.1', 'root', 'root', '', 3306); $db->query('SELECT 1');"#
        _ = try runner.runChecked(
            executable: php,
            arguments: ["-c", paths.generatedPHP.appendingPathComponent("php-7.4.ini").path, "-r", code],
            environment: runtimeEnvironment,
            timeout: 30
        )
    }

    private func startApache() async throws {
        try await supervisor.start(ServiceSpecification(
            kind: .apache,
            executable: runtimeDirectory("apache-2.4").appendingPathComponent("bin/httpd"),
            arguments: ["-D", "FOREGROUND", "-f", paths.generatedApache.appendingPathComponent("httpd.conf").path],
            environment: runtimeEnvironment,
            logFile: paths.logs.appendingPathComponent("apache.log"),
            readinessProbe: .tcpLoopback(port: 8080)
        ))
    }

    private func startPHP(runtimeID: String) async throws {
        let kind = ServiceKind(rawValue: runtimeID)!
        if await supervisor.state(for: kind).phase == .running { return }
        try CertificateManager(paths: paths, openssl: runtimeDirectory("openssl-3.5").appendingPathComponent("bin/openssl")).refreshTrustBundle()
        let sites = configuration.sites.filter { $0.phpRuntimeID == runtimeID }
        let probe: ReadinessProbe = sites.first.map { .fileExists(paths.phpSocket(runtimeID: runtimeID, siteID: $0.id)) }
            ?? .fileExists(paths.sockets.appendingPathComponent(runtimeID == "php-8.5" ? "php-8.5-management.sock" : "\(runtimeID)-default.sock"))
        let sockets = sites.map { paths.phpSocket(runtimeID: runtimeID, siteID: $0.id) }
            + [paths.sockets.appendingPathComponent(runtimeID == "php-8.5" ? "php-8.5-management.sock" : "\(runtimeID)-default.sock")]
            + (runtimeID == "php-8.5" ? [paths.sockets.appendingPathComponent("php-8.5-adminer.sock")] : [])
        for socket in sockets where FileManager.default.fileExists(atPath: socket.path) { try FileManager.default.removeItem(at: socket) }
        try await supervisor.start(ServiceSpecification(
            kind: kind,
            executable: runtimeDirectory(runtimeID).appendingPathComponent("sbin/php-fpm"),
            arguments: ["--nodaemonize", "--fpm-config", paths.generatedPHP.appendingPathComponent("\(runtimeID)-fpm.conf").path, "--php-ini", paths.generatedPHP.appendingPathComponent("\(runtimeID).ini").path],
            environment: runtimeEnvironment,
            logFile: paths.logs.appendingPathComponent("\(runtimeID).log"),
            readinessProbe: probe
        ))
    }

    private func startDatabase(_ engine: DatabaseEngine) async throws {
        let kind: ServiceKind = engine == .mysql57 ? .mysql57 : .mysql84
        try await supervisor.start(ServiceSpecification(
            kind: kind,
            executable: runtimeDirectory(engine.rawValue).appendingPathComponent("bin/mysqld"),
            arguments: ["--defaults-file=\(paths.generated.appendingPathComponent("\(engine.rawValue).cnf").path)"],
            environment: runtimeEnvironment,
            logFile: paths.logs.appendingPathComponent("\(engine.rawValue).log"),
            readinessProbe: .tcpLoopback(port: 3306),
            readinessTimeout: 30
        ))
    }

    private func startMailpit() async throws {
        let renderer = configurationRenderer
        try await supervisor.start(ServiceSpecification(
            kind: .mailpit,
            executable: runtimeDirectory("mailpit-1.31.1").appendingPathComponent("mailpit"),
            arguments: renderer.mailpitArguments(),
            logFile: paths.logs.appendingPathComponent("mailpit.log"),
            readinessProbe: .tcpLoopback(port: 8025)
        ))
    }

    func runtimeDirectory(_ id: String) -> URL {
        (configuration.importedRuntimeIDs.contains(id) ? paths.importedRuntimes : paths.builtInRuntimes).appendingPathComponent(id)
    }

    private var configurationRenderer: ConfigurationRenderer {
        ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes,
            runtimeDirectories: Dictionary(uniqueKeysWithValues: configuration.importedRuntimeIDs.map { ($0, runtimeDirectory($0)) }),
            standardPortsEnabled: helperInstalled)
    }

    func siteURL(_ site: SiteDefinition) -> String {
        let scheme = site.tlsEnabled ? "https" : "http"
        let port = site.tlsEnabled ? 8443 : 8080
        return "\(scheme)://\(site.hostname)\(helperInstalled ? "" : ":\(port)")"
    }

    func toolURL(_ name: String) -> String {
        return "https://\(name).localhost\(helperInstalled ? "" : ":8443")"
    }

    func selectWebServer(_ server: WebServer) async {
        guard !isBusy, server != configuration.selectedWebServer else { return }
        isBusy = true
        defer { isBusy = false }
        let previous = configuration.selectedWebServer
        let wasRunning = serviceIsRunning(previous.service)
        do {
            guard runtimeIsAvailable(server.service.runtimeID) else { throw CocoaError(.fileNoSuchFile) }
            configuration.selectedWebServer = server
            try generateConfiguration()
            if wasRunning {
                try await validateWebConfigurations()
                await supervisor.stop(previous.service)
                if server == .apache { try await startApache() } else { try await startNginx() }
            }
            try await store.save(configuration)
        } catch {
            configuration.selectedWebServer = previous
            if wasRunning {
                await supervisor.stop(server.service)
                if previous == .apache { try? await startApache() } else { try? await startNginx() }
            }
            errorMessage = "Could not switch to \(server.displayName): \(error.localizedDescription)"
        }
        await refreshServiceStates()
    }

    func selectPHP(_ runtimeID: String) async {
        guard !isBusy, runtimeIsAvailable(runtimeID), runtimeID != configuration.defaultPHPRuntimeID else { return }
        let previous = configuration.defaultPHPRuntimeID
        configuration.defaultPHPRuntimeID = runtimeID
        do { try generateConfiguration(); try await store.save(configuration) }
        catch { configuration.defaultPHPRuntimeID = previous; try? generateConfiguration(); errorMessage = error.localizedDescription }
    }

    func startService(_ service: ServiceKind) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard runtimeIsAvailable(service.runtimeID) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(service.displayName) is not installed."])
            }
            try generateConfiguration()
            switch service {
            case .apache, .nginx:
                try await prepareCertificatesAndPrivilegedState()
                for id in requiredPHPRuntimes.sorted() {
                    try await startPHP(runtimeID: id)
                }
                await supervisor.stop(service == .apache ? .nginx : .apache)
                if service == .apache { try await validateWebConfigurations(); try await startApache() }
                else { try await startNginx() }
            case .php74, .php84, .php85: try await startPHP(runtimeID: service.rawValue)
            case .mysql57, .mysql84:
                let engine: DatabaseEngine = service == .mysql57 ? .mysql57 : .mysql84
                await supervisor.stop(engine == .mysql57 ? .mysql84 : .mysql57)
                configuration.selectedDatabase = engine
                try await store.save(configuration)
                let manager = databaseManager
                let initialized = try await Task.detached { try manager.initializeIfNeeded(engine) }.value
                try await startDatabase(engine)
                if initialized { try await Task.detached { try manager.configureDevelopmentRootPassword(engine) }.value }
            case .mailpit: try await startMailpit()
            }
        } catch { errorMessage = "\(service.displayName): \(error.localizedDescription)" }
        await refreshServiceStates()
    }

    func stopService(_ service: ServiceKind) async {
        guard !isBusy else { return }
        isBusy = true
        await supervisor.stop(service)
        await refreshServiceStates()
        isBusy = false
    }

    func restartService(_ service: ServiceKind) async {
        await stopService(service)
        await startService(service)
    }

    private func startNginx() async throws {
        let executable = runtimeDirectory("nginx-1.30").appendingPathComponent("sbin/nginx")
        let arguments = ["-p", paths.generatedNginx.path + "/", "-c", paths.generatedNginx.appendingPathComponent("nginx.conf").path]
        _ = try runner.runChecked(executable: executable, arguments: ["-t"] + arguments, environment: runtimeEnvironment)
        try await supervisor.start(ServiceSpecification(kind: .nginx, executable: executable, arguments: arguments, environment: runtimeEnvironment,
            logFile: paths.logs.appendingPathComponent("nginx.log"), readinessProbe: .tcpLoopback(port: 8443)))
    }

    private func selectDatabase(_ engine: DatabaseEngine) async {
        guard !isBusy, engine != configuration.selectedDatabase, runtimeIsAvailable(engine.rawValue) else { return }
        isBusy = true
        defer { isBusy = false }
        let previous = configuration.selectedDatabase
        let old: ServiceKind = previous == .mysql84 ? .mysql84 : .mysql57
        let next: ServiceKind = engine == .mysql84 ? .mysql84 : .mysql57
        let wasRunning = await supervisor.state(for: old).phase == .running
        configuration.selectedDatabase = engine
        do {
            try generateConfiguration()
            if wasRunning {
                let manager = databaseManager
                let initialized = try await Task.detached { try manager.initializeIfNeeded(engine) }.value
                await supervisor.stop(old)
                try await startDatabase(engine)
                if initialized { try await Task.detached { try manager.configureDevelopmentRootPassword(engine) }.value }
            }
            try await store.save(configuration)
        } catch {
            configuration.selectedDatabase = previous
            if wasRunning { await supervisor.stop(next); try? await startDatabase(previous) }
            errorMessage = "Could not switch database: \(error.localizedDescription)"
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
