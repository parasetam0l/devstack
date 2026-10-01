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
        case .notInstalled: "Optional for 8080/8443 and .localhost. Required for custom domains and ports 80/443."
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

enum HelperNotice: Equatable {
    case welcome
    case startBlocked

    var isBlocking: Bool { self == .startBlocked }
}

enum NavigationSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case sites = "Sites"
    case php = "PHP"
    case database = "Database"
    case ssl = "SSL"
    case mailpit = "Mail Inbox"
    case localDNS = "Local DNS"
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
        case .ssl: "lock.shield"
        case .mailpit: "envelope"
        case .localDNS: "wifi.router"
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
    @Published var certificateSummaries: [CertificateSummary] = []
    @Published var caSummary: CertificateSummary?
    @Published var localCATrusted = false
    @Published var helperInstalled = false
    @Published var helperStatus: PrivilegedHelperStatus?
    @Published var helperSetupState: HelperSetupState = .notInstalled
    @Published var helperNotice: HelperNotice?
    @Published var lastDatabaseBackup: URL?
    @Published var isPresentingNewSite = false
    @Published var isPresentingSetupWizard = false
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
         .mailpit] + configuration.selectedDatabaseServices
    }

    var selectedDatabaseBinding: DatabaseEngine {
        get { configuration.selectedDatabase }
        set { Task { await selectDatabase(newValue) } }
    }

    func load() async {
        do {
            try paths.createRequiredDirectories()
            configuration = try await store.load()
            // The default site document root lives at ~/DevStack/localhost;
            // migrate earlier roots (Application Support/DefaultSite and the
            // short-lived ~/DevStack root) in place.
            if let index = configuration.sites.firstIndex(where: { $0.hostname == "localhost" }) {
                let currentRoot = configuration.sites[index].documentRoot
                let legacyRoots = [
                    paths.applicationSupport.appendingPathComponent("DefaultSite", isDirectory: true).path,
                    paths.defaultSiteRoot.deletingLastPathComponent().path
                ]
                if legacyRoots.contains(currentRoot), currentRoot != paths.defaultSiteRoot.path {
                    migrateDefaultSiteContents(from: URL(fileURLWithPath: currentRoot), to: paths.defaultSiteRoot)
                    configuration.sites[index].documentRoot = paths.defaultSiteRoot.path
                    try await store.save(configuration)
                    DefaultSiteContent.refreshPlaceholderIndex(in: paths.defaultSiteRoot, hostname: "localhost", isDefaultSite: true)
                    try? generateConfiguration()
                }
            }
            // Keep the generated default placeholder in sync with its document
            // root without ever touching user-edited files.
            if let defaultSite = configuration.sites.first(where: { $0.hostname == "localhost" }) {
                DefaultSiteContent.refreshPlaceholderIndex(
                    in: URL(fileURLWithPath: defaultSite.documentRoot),
                    hostname: defaultSite.hostname,
                    isDefaultSite: true
                )
            }
            // The default site always exists so localhost/127.0.0.1 have a
            // working page and unmatched hostnames never hit phpMyAdmin.
            if !configuration.sites.contains(where: { $0.hostname == "localhost" }) {
                let defaultSite = SiteDefinition.defaultSite(paths: paths, phpRuntimeID: configuration.defaultPHPRuntimeID)
                configuration.sites.append(defaultSite)
                try await store.save(configuration)
                DefaultSiteContent.ensurePlaceholderIndex(
                    in: URL(fileURLWithPath: defaultSite.documentRoot),
                    hostname: defaultSite.hostname,
                    isDefaultSite: true
                )
                try? generateConfiguration()
            }
            runtimeManifests = try loadRuntimeLock()
            let loginItemEnabled = SMAppService.mainApp.status == .enabled
            if configuration.startAtLogin != loginItemEnabled {
                configuration.startAtLogin = loginItemEnabled
                try await store.save(configuration)
            }
            await refreshHelperStatus()
            localCATrusted = certificateManager.isTrusted()
            await refreshServiceStates()
            // Fresh installs get the setup wizard; an already healthy install
            // (helper answering and CA trusted) is marked complete silently so
            // the wizard never appears after an update.
            if !configuration.setupWizardCompleted, !isReviewMode {
                if helperInstalled, localCATrusted {
                    configuration.setupWizardCompleted = true
                    try? await store.save(configuration)
                } else {
                    isPresentingSetupWizard = true
                }
            }
            if !helperInstalled, !configuration.helperNoticeDismissed, !isReviewMode, !isPresentingSetupWizard {
                helperNotice = .welcome
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves the contents of an earlier default-site root into the current one,
    /// preserving user files. The legacy folder is removed only when empty.
    private func migrateDefaultSiteContents(from legacy: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard legacy.standardizedFileURL != destination.standardizedFileURL,
              fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? [] {
            let source = legacy.appendingPathComponent(entry)
            let target = destination.appendingPathComponent(entry)
            guard source.standardizedFileURL != destination.standardizedFileURL,
                  !fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.moveItem(at: source, to: target)
        }
        if (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
            try? fileManager.removeItem(at: legacy)
        }
    }

    func saveSite(_ site: SiteDefinition) async throws {
        var site = site
        // The default site keeps its hostname; only its folder and settings
        // can change.
        if configuration.sites.contains(where: { $0.id == site.id && $0.hostname == "localhost" }) {
            site.hostname = "localhost"
        }
        site.hostname = try HostnameValidator.validate(site.hostname, existing: configuration.sites.filter { $0.id != site.id }.map(\.hostname))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: site.documentRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: site.documentRoot])
        }
        if site.hostname == "localhost" || site.createPlaceholderIndex {
            DefaultSiteContent.ensurePlaceholderIndex(
                in: URL(fileURLWithPath: site.documentRoot),
                hostname: site.hostname,
                isDefaultSite: site.hostname == "localhost"
            )
        }
        var sites = configuration.sites
        if let index = sites.firstIndex(where: { $0.id == site.id }) { sites[index] = site }
        else { sites.append(site) }
        try await applySites(sites)
    }

    func deleteSite(_ site: SiteDefinition) async {
        guard site.hostname != "localhost" else { return }
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
        await refreshHelperStatus()
        // High ports + .localhost run without the helper. Only block when
        // privileged ports or custom hostnames actually need it.
        if !helperInstalled, requiresHelperForCurrentConfig {
            helperNotice = .startBlocked
            return
        }
        let previouslyRunning = Set((await supervisor.allStates()).filter { $0.phase == .running }.map(\.service))
        do {
            try generateConfiguration()
            try validateRequiredRuntimes()
            try await prepareCertificatesAndPrivilegedState()
            try await validateWebConfigurations()
            try await startMailpit()
            if configuration.selectedDatabase != .none {
                let manager = databaseManager
                let engine = configuration.selectedDatabase
                let initializedDatabase = try await Task.detached { try manager.initializeIfNeeded(engine) }.value
                try await startDatabase(engine)
                if initializedDatabase { try await Task.detached { try manager.configureDevelopmentRootPassword(engine) }.value }
            }
            if configuration.selectedPostgreSQL != .none { try await prepareAndStartPostgreSQL() }
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
            certificateTrusted: localCATrusted,
            expectedHostnames: configuration.sites.map(\.hostname) + ["phpmyadmin.localhost", "mailpit.localhost", "adminer.localhost"],
            serviceStates: serviceStates,
            requiredRuntimeIDs: Set(configuration.sites.map(\.phpRuntimeID)).union(configuration.selectedDatabaseServices.map(\.runtimeID)).union(["php-8.5"]),
            selectedDatabase: configuration.selectedDatabase, selectedPostgreSQL: configuration.selectedPostgreSQL,
            ports: configuration.ports, localNetworkAccess: configuration.localNetworkAccess
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
            // A registered helper that no longer responds usually means the app bundle
            // was replaced after registration, which makes launchd's bundle record
            // stale. Rebuild the registration against the current bundle.
            if case .unavailable = helperSetupState, helper.registrationStatus == .enabled {
                try await helper.unregister()
            }
            try helper.register()
            await refreshHelperStatus()
            if helperSetupState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            helperInstalled = false
            helperSetupState = .unavailable("Setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Setup wizard

    /// Registers the helper once and waits for the system approval, updating the
    /// helper state as it changes. No unregister/re-register cycles, so macOS
    /// shows at most one approval prompt.
    func setUpHelperForWizard() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if helper.registrationStatus == .notRegistered {
                try helper.register()
            }
            await refreshHelperStatus()
            if helperSetupState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            // Wait for the user to approve in System Settings, then for the
            // daemon to answer. Bounded so the wizard never polls forever.
            for _ in 0..<60 {
                if helperInstalled { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshHelperStatus()
            }
        } catch {
            helperInstalled = false
            helperSetupState = .unavailable("Setup failed: \(error.localizedDescription)")
        }
    }

    /// Installs the DevStack CA into the system trust store (one administrator
    /// prompt). Returns nil on success or a message to show inline.
    func installSystemCertificate() async -> String? {
        guard !isBusy else { return "Another setup step is still running." }
        isBusy = true
        defer { isBusy = false }
        let certificates = certificateManager
        do {
            try await Task.detached { try certificates.trustForSystem() }.value
            localCATrusted = certificates.isTrusted()
            return localCATrusted ? nil : "The CA is still not trusted."
        } catch {
            localCATrusted = certificates.isTrusted()
            return error.localizedDescription
        }
    }

    /// Applies the web ports chosen in the wizard. Returns nil on success or a
    /// message to show inline.
    func applyWizardPorts(http: UInt16, https: UInt16) async -> String? {
        guard !isBusy else { return "Another setup step is still running." }
        guard !hasRunningServices else { return "Stop the stack before changing ports." }
        isBusy = true
        defer { isBusy = false }
        var ports = configuration.ports
        ports.webHTTP = http
        ports.webHTTPS = https
        guard ports.isValid else {
            if ports.collisions.isEmpty { return "Port 22 is reserved and cannot be assigned to a DevStack service." }
            return "These ports conflict: \(ports.collisions.map(String.init).joined(separator: ", "))."
        }
        let previous = configuration.ports
        configuration.ports = ports
        do {
            try generateConfiguration()
            try await store.save(configuration)
            if helperInstalled {
                try await applyPrivilegedNetworking(hostnames: configuration.sites.map(\.hostname) + Self.managementHostnames)
            }
            return nil
        } catch {
            configuration.ports = previous
            try? generateConfiguration()
            return error.localizedDescription
        }
    }

    /// Marks the wizard complete and closes it.
    func completeSetupWizard() async {
        configuration.setupWizardCompleted = true
        try? await store.save(configuration)
        isPresentingSetupWizard = false
    }

    func presentSetupWizard() {
        helperNotice = nil
        isPresentingSetupWizard = true
    }

    var helperIsRegistered: Bool { helper.registrationStatus == .enabled || helper.registrationStatus == .requiresApproval }

    /// Which build the user actually launched. The helper only works from the
    /// Developer ID signed /Applications install; preview / DerivedData builds
    /// are ad-hoc by design and stay fail-closed.
    var runningBundlePath: String { helper.runningBundlePath }
    var runningTeamID: String? { helper.teamIdentifier }
    var isRunningSignedRelease: Bool { helper.canAuthenticate && helper.isRunningFromApplications }
    var isPreviewBuild: Bool { !helper.isRunningFromApplications }

    func openApplicationsBuild() {
        let url = URL(fileURLWithPath: "/Applications/DevStack.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            errorMessage = "No signed install found at /Applications/DevStack.app. Install it from the release DMG first."
        }
    }

    func dismissHelperNotice() async {
        helperNotice = nil
        guard !configuration.helperNoticeDismissed else { return }
        configuration.helperNoticeDismissed = true
        await persistConfiguration()
    }

    func updatePorts(_ ports: ServicePorts) async {
        guard !isBusy else { return }
        guard !hasRunningServices else {
            errorMessage = "Stop the stack before changing ports."
            return
        }
        guard ports.isValid else {
            if ports.collisions.isEmpty {
                errorMessage = "Port 22 is reserved and cannot be assigned to a DevStack service."
            } else {
                errorMessage = "Conflicting listener ports: \(ports.collisions.map(String.init).joined(separator: ", "))."
            }
            return
        }
        let previous = configuration.ports
        configuration.ports = ports
        do {
            try generateConfiguration()
            try await store.save(configuration)
            if helperInstalled {
                try await applyPrivilegedNetworking(hostnames: configuration.sites.map(\.hostname) + Self.managementHostnames)
            }
        } catch {
            configuration.ports = previous
            try? generateConfiguration()
            errorMessage = error.localizedDescription
        }
    }

    static let managementHostnames = ["phpmyadmin.localhost", "mailpit.localhost", "adminer.localhost", "postgresql.localhost"]

    /// Hostnames that need /etc/hosts entries (.localhost resolves without edits).
    var hostnamesNeedingHostsFile: [String] {
        (configuration.sites.map(\.hostname) + Self.managementHostnames).filter { $0 != "localhost" && !$0.hasSuffix(".localhost") }
    }

    /// True when the current ports or hostnames need the privileged helper.
    /// High ports with .localhost domains run without it.
    var requiresHelperForCurrentConfig: Bool {
        configuration.ports.requiresHelper || !hostnamesNeedingHostsFile.isEmpty
    }

    /// Hostnames the local DNS responder answers (deduplicated, sorted).
    var localNetworkHostnames: [String] {
        Array(Set(configuration.sites.map(\.hostname) + Self.managementHostnames)).sorted()
    }

    var localNetworkAddress: String? { LocalNetwork.primaryIPv4Address() }

    /// Ports the helper forwards to the web server for local-network clients.
    /// Unprivileged ports are bound directly by the web server, so only
    /// privileged public ports need forwarding.
    var localNetworkLanEntries: [PortForwardingEntry] {
        guard configuration.localNetworkAccess else { return [] }
        let candidates = [
            PortForwardingEntry(publicPort: configuration.ports.webHTTP, upstreamPort: configuration.ports.webHTTPListen),
            PortForwardingEntry(publicPort: configuration.ports.webHTTPS, upstreamPort: configuration.ports.webHTTPSListen)
        ]
        return candidates.filter { $0.publicPort < 1024 && $0.publicPort != $0.upstreamPort }
    }

    /// Keeps the helper's host mappings, loopback/LAN forwarding and local DNS in
    /// sync with the current configuration.
    private func applyPrivilegedNetworking(hostnames: [String]) async throws {
        let forwardings = configuration.ports.forwardings
        let lan = localNetworkLanEntries
        // Don't report forwarding as enabled when there is nothing to forward.
        let forwardingEnabled = !forwardings.isEmpty || !lan.isEmpty
        try await helper.setPortForwarding(PortForwardingConfiguration(
            enabled: forwardingEnabled,
            entries: forwardings,
            lanEntries: lan))
        let answerAddress = localNetworkAddress ?? ""
        try await helper.setDNSConfiguration(DNSConfiguration(
            enabled: configuration.localNetworkAccess && !answerAddress.isEmpty,
            hostnames: hostnames,
            answerAddress: answerAddress))
    }

    func setLocalNetworkAccess(_ enabled: Bool) async {
        guard !isBusy else { return }
        guard helperInstalled else {
            errorMessage = "Local network access requires the helper. Set it up in Settings first."
            return
        }
        if enabled, localNetworkAddress == nil {
            errorMessage = "No active Wi-Fi or Ethernet connection was found. Connect to a network first."
            return
        }
        let previous = configuration.localNetworkAccess
        configuration.localNetworkAccess = enabled
        do {
            try await store.save(configuration)
            // The web server binds every interface when local access is on.
            try generateConfiguration()
            try await reloadWebServerIfRunning()
            if enabled { exportCACertificateForLocalNetwork() }
            try await applyPrivilegedNetworking(hostnames: configuration.sites.map(\.hostname) + Self.managementHostnames)
            await refreshHelperStatus()
        } catch {
            configuration.localNetworkAccess = previous
            try? await store.save(configuration)
            try? generateConfiguration()
            try? await reloadWebServerIfRunning()
            errorMessage = error.localizedDescription
        }
    }

    /// Reloads the running web server after a configuration change.
    private func reloadWebServerIfRunning() async throws {
        if serviceIsRunning(.apache) {
            try await validateWebConfigurations()
            try await reloadApache()
        }
        if serviceIsRunning(.nginx) {
            try await validateWebConfigurations()
            let executable = runtimeDirectory("nginx-1.30").appendingPathComponent("sbin/nginx")
            let arguments = ["-p", paths.generatedNginx.path + "/", "-c", paths.generatedNginx.appendingPathComponent("nginx.conf").path, "-s", "reload"]
            let environment = runtimeEnvironment
            let runner = runner
            try await Task.detached { _ = try runner.runChecked(executable: executable, arguments: arguments, environment: environment) }.value
        }
    }

    /// Copies the public CA next to the default site so phones can download it
    /// over the local network and trust HTTPS.
    private func exportCACertificateForLocalNetwork() {
        let caCertificate = certificateManager.caCertificate
        guard let data = try? Data(contentsOf: caCertificate) else { return }
        try? AtomicFileWriter.write(data, to: paths.defaultSiteRoot.appendingPathComponent("devstack-ca.crt"), permissions: 0o644)
    }

    func refreshHelperStatus() async {
        guard !isReviewMode else { return }
        guard helper.canAuthenticate else {
            helperInstalled = false; helperStatus = nil
            // Path-aware: most "helper unavailable" reports are just the user
            // running the ad-hoc preview instead of the signed install.
            helperSetupState = .unavailable("This build cannot drive the helper. Open the signed DevStack build in Applications for custom domains and ports 80/443; high ports with .localhost work here without it.")
            return
        }
        switch helper.registrationStatus {
        case .requiresApproval:
            helperInstalled = false; helperStatus = nil; helperSetupState = .requiresApproval
        case .enabled:
            if helperSetupState != .ready { helperSetupState = .connecting }
            do {
                helperStatus = try await helper.status()
                helperInstalled = true
                helperSetupState = .ready
                if configuration.localNetworkAccess {
                    try? await applyPrivilegedNetworking(hostnames: configuration.sites.map(\.hostname) + Self.managementHostnames)
                    // Re-read after applying so the UI reflects listeners that
                    // were started by this refresh instead of the pre-apply state.
                    helperStatus = try? await helper.status()
                }
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
            // Managed state can only be cleared while the helper responds; the
            // registration must be removed even when it is already dead.
            if helperInstalled, helper.isRegistered, helper.canAuthenticate {
                try await helper.removeManagedState()
            }
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
        guard let url = URL(string: "http://127.0.0.1:\(configuration.ports.mailpitInboxListen)/api/v1/messages") else { return }
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

    func databaseBackupFilename(postgreSQL: Bool = false) -> String {
        if postgreSQL { return postgreSQLManager.backupFilename() }
        return databaseManager.backupFilename(engine: configuration.selectedDatabase, database: nil)
    }

    func exportDatabase(to destination: URL, postgreSQL: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        do {
            await refreshServiceStates()
            if postgreSQL {
                guard serviceIsRunning(.postgresql18) else { throw CocoaError(.executableNotLoadable) }
                let manager = postgreSQLManager
                lastDatabaseBackup = try await Task.detached { try manager.exportSQL(destination: destination) }.value
                return
            }
            let engine = configuration.selectedDatabase
            try requireRunningDatabase(engine)
            let manager = databaseManager
            lastDatabaseBackup = try await Task.detached { try manager.exportSQL(engine, destination: destination) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importDatabase(from source: URL, postgreSQL: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        do {
            await refreshServiceStates()
            if postgreSQL {
                guard serviceIsRunning(.postgresql18) else { throw CocoaError(.executableNotLoadable) }
                let manager = postgreSQLManager
                lastDatabaseBackup = try await Task.detached { try manager.exportSQL() }.value
                try await Task.detached { try manager.importSQL(source: source) }.value
                return
            }
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
        guard configuration.selectedDatabase != .none, !isBusy else { return }
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
            opensslRuntime: runtimeDirectory("openssl-3.5"), port: configuration.ports.mysqlListen)
    }

    private var managedPath: String {
        [
            paths.generated.appendingPathComponent("bin").path,
            runtimeDirectory(configuration.defaultPHPRuntimeID).appendingPathComponent("bin").path,
            runtimeDirectory(configuration.selectedDatabase == .none ? "mysql-8.4" : configuration.selectedDatabase.rawValue).appendingPathComponent("bin").path,
            runtimeDirectory("postgresql-18").appendingPathComponent("bin").path
        ].joined(separator: ":")
    }

    private var managedRuntimeEnvironmentCommand: String {
        runtimeEnvironment.map { "export \($0.key)=\(shellQuote($0.value))" }.sorted().joined(separator: "\n")
    }

    private func requireRunningDatabase(_ engine: DatabaseEngine) throws {
        guard let kind = engine.service else { throw CocoaError(.executableNotLoadable) }
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
        try AtomicFileWriter.write(
            renderer.adminerWrapperPHP(adminerIndex: runtimeDirectory("adminer-6.1.1").appendingPathComponent("index.php")),
            to: paths.generatedAdminer.appendingPathComponent("index.php"),
            permissions: 0o644
        )
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
        for engine in DatabaseEngine.allCases where engine != .none {
            let base = runtimeDirectory(engine.rawValue)
            try AtomicFileWriter.write(renderer.mysqlConfiguration(engine: engine, baseDirectory: base), to: paths.generated.appendingPathComponent("\(engine.rawValue).cnf"), permissions: 0o600)
        }
        try AtomicFileWriter.write(renderer.composerWrapperScript(runtimeID: configuration.defaultPHPRuntimeID), to: paths.generated.appendingPathComponent("bin/composer"), permissions: 0o755)
        for client in ["mysql", "mysqldump", "mysqladmin"] {
            try AtomicFileWriter.write(try renderer.databaseClientWrapperScript(engine: configuration.selectedDatabase == .none ? .mysql84 : configuration.selectedDatabase, client: client),
                to: paths.generated.appendingPathComponent("bin/\(client)"), permissions: 0o755)
        }
        try postgreSQLManager.writeConfiguration()
        let pgEnvironment = postgreSQLManager.environment.filter { $0.key != "PGPASSWORD" }
            .map { "export \($0.key)=\(shellQuote($0.value))" }.sorted().joined(separator: "\n")
        for client in ["psql", "pg_dump", "pg_dumpall", "pg_restore", "createdb", "dropdb", "pg_isready"] {
            let executable = runtimeDirectory("postgresql-18").appendingPathComponent("bin/\(client)")
            let arguments = client == "psql" ? " -X" : ""
            let script = "#!/bin/sh\n\(pgEnvironment)\nexec \(shellQuote(executable.path))\(arguments) \"$@\"\n"
            try AtomicFileWriter.write(script, to: paths.generated.appendingPathComponent("bin/\(client)"), permissions: 0o755)
        }

    }

    private func validateRequiredRuntimes() throws {
        var required = [configuration.selectedWebServer.service.runtimeID, "php-8.5", "mailpit-1.31.1", "phpmyadmin-5.2.3", "adminer-6.1.1", "openssl-3.5"]
        required.append(contentsOf: configuration.selectedDatabaseServices.map(\.runtimeID))
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
        let managementHosts = Self.managementHostnames
        let TLSHosts = configuration.sites.filter { $0.tlsEnabled || $0.hostname == "localhost" }.map(\.hostname) + managementHosts
        try await Task.detached {
            try certificates.ensureCertificates(for: TLSHosts)
            try certificates.refreshTrustBundle()
        }.value
        exportCACertificateForLocalNetwork()
        // Trust is only installed from explicit user actions (the setup wizard
        // or the SSL tab) so macOS never asks for credentials repeatedly.
        localCATrusted = certificates.isTrusted()
        guard helperInstalled else { return }
        let hostnames = (configuration.sites.map(\.hostname) + managementHosts).filter { $0 != "localhost" }
        try await helper.applyHostMappings(hostnames.map { HostMapping(hostname: $0) })
        try await applyPrivilegedNetworking(hostnames: hostnames)
        helperStatus = try await helper.status()
        helperInstalled = true
    }

    private func verifyLegacyDatabaseCompatibilityIfNeeded() throws {
        guard configuration.selectedDatabase == .mysql84,
              configuration.sites.contains(where: { $0.phpRuntimeID == "php-7.4" }) else { return }
        let php = runtimeDirectory("php-7.4").appendingPathComponent("bin/php")
        let code = #"mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT); $db = new mysqli('127.0.0.1', 'root', 'root', '', \#(configuration.ports.mysqlListen)); $db->query('SELECT 1');"#
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
            readinessProbe: .tcpLoopback(port: configuration.ports.webHTTPListen)
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
            readinessProbe: .tcpLoopback(port: configuration.ports.mysqlListen),
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
            readinessProbe: .tcpLoopback(port: configuration.ports.mailpitInboxListen)
        ))
    }

    func runtimeDirectory(_ id: String) -> URL {
        (configuration.importedRuntimeIDs.contains(id) ? paths.importedRuntimes : paths.builtInRuntimes).appendingPathComponent(id)
    }

    private var configurationRenderer: ConfigurationRenderer {
        ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes,
            runtimeDirectories: Dictionary(uniqueKeysWithValues: configuration.importedRuntimeIDs.map { ($0, runtimeDirectory($0)) }),
            ports: configuration.ports,
            localNetworkAccess: configuration.localNetworkAccess)
    }

    func siteURL(_ site: SiteDefinition) -> String {
        let scheme = site.tlsEnabled ? "https" : "http"
        let port = site.tlsEnabled ? configuration.ports.webHTTPS : configuration.ports.webHTTP
        let defaultPort: UInt16 = site.tlsEnabled ? 443 : 80
        return "\(scheme)://\(site.hostname)\(port == defaultPort ? "" : ":\(port)")"
    }

    func toolURL(_ name: String) -> String {
        let port = configuration.ports.webHTTPS
        return "https://\(name).localhost\(port == 443 ? "" : ":\(port)")"
    }

    func selectWebServer(_ server: WebServer) async {
        guard !isBusy, server != configuration.selectedWebServer,
              !serviceIsRunning(configuration.selectedWebServer.service) else { return }
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
        guard !isBusy, runtimeIsAvailable(runtimeID), runtimeID != configuration.defaultPHPRuntimeID,
              !serviceIsRunning(ServiceKind(rawValue: configuration.defaultPHPRuntimeID) ?? .php85) else { return }
        let previous = configuration.defaultPHPRuntimeID
        configuration.defaultPHPRuntimeID = runtimeID
        do { try generateConfiguration(); try await store.save(configuration) }
        catch { configuration.defaultPHPRuntimeID = previous; try? generateConfiguration(); errorMessage = error.localizedDescription }
    }

    func startService(_ service: ServiceKind) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await refreshHelperStatus()
        if !helperInstalled, requiresHelperForCurrentConfig {
            helperNotice = .startBlocked
            return
        }
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
            case .postgresql18:
                configuration.selectedPostgreSQL = .postgresql18
                try await store.save(configuration)
                try await prepareAndStartPostgreSQL()
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
            logFile: paths.logs.appendingPathComponent("nginx.log"), readinessProbe: .tcpLoopback(port: configuration.ports.webHTTPSListen)))
    }

    private func selectDatabase(_ engine: DatabaseEngine) async {
        guard !isBusy, engine != configuration.selectedDatabase,
              engine == .none || runtimeIsAvailable(engine.rawValue),
              !(configuration.selectedDatabase.service.map { serviceIsRunning($0) } ?? false) else { return }
        isBusy = true
        defer { isBusy = false }
        let previous = configuration.selectedDatabase
        let wasRunning = previous.service.map(serviceIsRunning) ?? false
        configuration.selectedDatabase = engine
        do {
            try generateConfiguration()
            if let old = previous.service { await supervisor.stop(old) }
            if wasRunning, engine != .none {
                let manager = databaseManager
                let initialized = try await Task.detached { try manager.initializeIfNeeded(engine) }.value
                try await startDatabase(engine)
                if initialized { try await Task.detached { try manager.configureDevelopmentRootPassword(engine) }.value }
            }
            try await store.save(configuration)
        } catch {
            configuration.selectedDatabase = previous
            try? generateConfiguration()
            if let next = engine.service { await supervisor.stop(next) }
            if wasRunning { try? await startDatabase(previous) }
            errorMessage = "Could not change MySQL selection: \(error.localizedDescription)"
        }
        await refreshServiceStates()
    }

    func selectPostgreSQL(_ engine: PostgreSQLEngine) async {
        guard !isBusy, engine != configuration.selectedPostgreSQL,
              engine == .none || runtimeIsAvailable(engine.rawValue),
              !serviceIsRunning(.postgresql18) else { return }
        isBusy = true
        defer { isBusy = false }
        let previous = configuration.selectedPostgreSQL
        let wasRunning = serviceIsRunning(.postgresql18)
        configuration.selectedPostgreSQL = engine
        do {
            if engine == .none { await supervisor.stop(.postgresql18) }
            try await store.save(configuration)
        } catch {
            configuration.selectedPostgreSQL = previous
            if wasRunning { try? await prepareAndStartPostgreSQL() }
            errorMessage = error.localizedDescription
        }
        await refreshServiceStates()
    }

    var postgreSQLManager: PostgreSQLManager {
        PostgreSQLManager(paths: paths, runtime: runtimeDirectory("postgresql-18"), opensslRuntime: runtimeDirectory("openssl-3.5"), port: configuration.ports.postgresqlListen)
    }
    private func prepareAndStartPostgreSQL() async throws {
        let manager = postgreSQLManager
        let certificates = certificateManager
        try await Task.detached {
            try certificates.ensureLeafCertificate(for: "postgresql.localhost")
            _ = try manager.initializeIfNeeded()
            try manager.writeConfiguration()
        }.value
        try await supervisor.start(manager.specification)
        // The supervisor's TCP probe succeeds as soon as PostgreSQL binds its
        // socket, which is before it accepts connections. Retry briefly so a
        // server that is still starting up is not reported as a credential
        // failure.
        var ready = false
        for _ in 0..<40 {
            if await Task.detached(operation: { manager.ping() }).value { ready = true; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard ready else {
            await supervisor.stop(.postgresql18)
            throw ServiceFailure(message: "PostgreSQL did not accept the managed credentials.")
        }
    }

    var managedTLSHostnames: Set<String> {
        Set(configuration.sites.filter { $0.tlsEnabled || $0.hostname == "localhost" }.map(\.hostname) + ["localhost", "phpmyadmin.localhost", "adminer.localhost", "mailpit.localhost", "postgresql.localhost"])
    }

    func refreshCertificates() async {
        let manager = certificateManager
        do {
            let summaries = try await Task.detached { try manager.leafSummaries() }.value
            certificateSummaries = summaries
            caSummary = FileManager.default.fileExists(atPath: manager.caCertificate.path)
                ? await Task.detached { manager.summary(of: manager.caCertificate, hostname: "DevStack Local CA") }.value : nil
            localCATrusted = manager.isTrusted()
        } catch { errorMessage = error.localizedDescription }
    }

    func issueCertificate(for rawHostname: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let manager = certificateManager
        do {
            let hostname = try HostnameValidator.validate(rawHostname)
            try await Task.detached { try manager.ensureLeafCertificate(for: hostname, force: true); try manager.refreshTrustBundle() }.value
            if managedTLSHostnames.contains(hostname) {
                if serviceIsRunning(.apache) { try await validateWebConfigurations(); try await reloadApache() }
                if serviceIsRunning(.nginx) {
                    try await validateWebConfigurations()
                    let executable = runtimeDirectory("nginx-1.30").appendingPathComponent("sbin/nginx")
                    let arguments = ["-p", paths.generatedNginx.path + "/", "-c", paths.generatedNginx.appendingPathComponent("nginx.conf").path, "-s", "reload"]
                    let environment = runtimeEnvironment; let runner = runner
                    try await Task.detached { _ = try runner.runChecked(executable: executable, arguments: arguments, environment: environment) }.value
                }
                if hostname == "postgresql.localhost", serviceIsRunning(.postgresql18) { try await supervisor.reload(.postgresql18) }
            }
        } catch { errorMessage = error.localizedDescription }
        await refreshCertificates()
    }

    func deleteCertificate(_ certificate: CertificateSummary) async {
        guard !isBusy, !managedTLSHostnames.contains(certificate.hostname) else { return }
        isBusy = true
        defer { isBusy = false }
        let manager = certificateManager
        do { try await Task.detached { try manager.deleteLeafCertificate(for: certificate.hostname) }.value }
        catch { errorMessage = error.localizedDescription }
        await refreshCertificates()
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
