import AppKit
import Combine
import DevStackCore
import Foundation

enum NavigationSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case sites = "Sites"
    case php = "PHP"
    case database = "Database"
    case mailpit = "Mailpit"
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
    @Published var configuration = AppConfiguration()
    @Published var serviceStates = ServiceKind.allCases.map { ServiceState(service: $0) }
    @Published var runtimeManifests: [RuntimeManifest] = []
    @Published var diagnosticReport: DiagnosticReport?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var helperInstalled = false
    @Published var helperStatus: PrivilegedHelperStatus?

    let paths: DevStackPaths
    private let store: AppConfigurationStore
    private let supervisor = ServiceSupervisor()
    private let runner = ProcessRunner()
    private let helper = PrivilegedHelperClient()

    init(paths: DevStackPaths = DevStackPaths()) {
        self.paths = paths
        self.store = AppConfigurationStore(url: paths.configurationFile)
        Task { await load() }
    }

    var menuBarSymbol: String {
        serviceStates.contains(where: { $0.phase == .failed }) ? "exclamationmark.triangle.fill" : "server.rack"
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
            if helper.isRegistered {
                helperStatus = try? await helper.status()
                helperInstalled = helperStatus != nil
            }
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
            let database = DatabaseManager(paths: paths, runtimeRoot: paths.builtInRuntimes)
            let initializedDatabase = try database.initializeIfNeeded(configuration.selectedDatabase)
            try await startDatabase(configuration.selectedDatabase)
            if initializedDatabase { try database.configureDevelopmentRootPassword(configuration.selectedDatabase) }
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
        diagnosticReport = await Task.detached {
            DevStackDoctor().run(context: context, appVersion: appVersion)
        }.value
    }

    func installHelper() async {
        do {
            try helper.register()
            helperStatus = try? await helper.status()
            helperInstalled = helperStatus != nil
        } catch {
            errorMessage = "Could not install the privileged helper: \(error.localizedDescription)"
        }
    }

    func removeHelper() async {
        do {
            if helper.isRegistered { try await helper.removeManagedState() }
            try await helper.unregister()
            helperStatus = nil
            helperInstalled = false
        } catch {
            errorMessage = "Could not remove the privileged helper: \(error.localizedDescription)"
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

    func openManagedShell() {
        do {
            let php = paths.builtInRuntimes.appendingPathComponent("php-8.5/bin")
            let mysql = paths.builtInRuntimes.appendingPathComponent("\(configuration.selectedDatabase.rawValue)/bin")
            let composer = paths.builtInRuntimes.appendingPathComponent("composer-2.10.3/bin")
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("DevStack-\(UUID().uuidString).command")
            let managedPath = [php.path, mysql.path, composer.path].joined(separator: ":")
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

    func logContents(for service: ServiceKind) -> String {
        let url = paths.logs.appendingPathComponent("\(service.rawValue).log")
        guard let data = try? Data(contentsOf: url) else { return "No log output yet." }
        return String(decoding: data.suffix(200_000), as: UTF8.self)
    }

    private func persistConfiguration() async {
        do { try await store.save(configuration) } catch { errorMessage = error.localizedDescription }
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
        guard let url = Bundle.module.url(forResource: "runtime-lock", withExtension: "json") else { return [] }
        return try JSONDecoder().decode(RuntimeLock.self, from: Data(contentsOf: url)).runtimes
    }

    private func loadTrustedRuntimeKeys() throws -> [String: Data] {
        guard let url = Bundle.module.url(forResource: "trusted-runtime-keys", withExtension: "json") else {
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
