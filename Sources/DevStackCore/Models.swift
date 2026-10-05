import Foundation

public enum RuntimeKind: String, Codable, CaseIterable, Sendable {
    case apache
    case nginx
    case php
    case mysql
    case postgresql
    case mailpit
    case phpMyAdmin = "phpmyadmin"
    case adminer
    case composer
    case openssl
    case phpExtension = "php-extension"
    case library
}

public enum RuntimeSupportState: String, Codable, Sendable {
    case supported
    case legacy
    case endOfLife = "end-of-life"
    case conditional
}

public struct SourceProvenance: Codable, Hashable, Sendable {
    public var url: URL
    public var sha256: String
    public var revision: String?
    public var patches: [String]

    public init(url: URL, sha256: String, revision: String? = nil, patches: [String] = []) {
        self.url = url
        self.sha256 = sha256
        self.revision = revision
        self.patches = patches
    }
}

public struct RuntimeExtension: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var version: String?
    public var enabledByDefault: Bool
    public var zendExtension: Bool

    public init(name: String, version: String? = nil, enabledByDefault: Bool = true, zendExtension: Bool = false) {
        self.name = name
        self.version = version
        self.enabledByDefault = enabledByDefault
        self.zendExtension = zendExtension
    }
}

public struct RuntimeManifest: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: RuntimeKind
    public var version: String
    public var abi: String?
    public var architecture: String
    public var minimumMacOS: String
    public var entryPoints: [String: String]
    public var extensions: [RuntimeExtension]
    public var hashes: [String: String]
    public var license: String
    public var source: SourceProvenance
    public var supportState: RuntimeSupportState
    public var dependencyPaths: [String]
    public var build: RuntimeBuildMetadata?

    public init(
        id: String,
        kind: RuntimeKind,
        version: String,
        abi: String? = nil,
        architecture: String = "arm64",
        minimumMacOS: String = "15.0",
        entryPoints: [String: String],
        extensions: [RuntimeExtension] = [],
        hashes: [String: String] = [:],
        license: String,
        source: SourceProvenance,
        supportState: RuntimeSupportState,
        dependencyPaths: [String] = [],
        build: RuntimeBuildMetadata? = nil
    ) {
        self.id = id
        self.kind = kind
        self.version = version
        self.abi = abi
        self.architecture = architecture
        self.minimumMacOS = minimumMacOS
        self.entryPoints = entryPoints
        self.extensions = extensions
        self.hashes = hashes
        self.license = license
        self.source = source
        self.supportState = supportState
        self.dependencyPaths = dependencyPaths
        self.build = build
    }
}

public struct RuntimeBuildMetadata: Codable, Hashable, Sendable {
    public var buildSystem: String
    public var flags: [String]
    public var environment: [String: String]
    public var dependencies: [String]
    public var patchSources: [SourceProvenance]
    public var feasibilityGate: String?

    public init(
        buildSystem: String,
        flags: [String],
        environment: [String: String] = [:],
        dependencies: [String] = [],
        patchSources: [SourceProvenance] = [],
        feasibilityGate: String? = nil
    ) {
        self.buildSystem = buildSystem
        self.flags = flags
        self.environment = environment
        self.dependencies = dependencies
        self.patchSources = patchSources
        self.feasibilityGate = feasibilityGate
    }
}

public struct RuntimePackCompatibility: Codable, Hashable, Sendable {
    public var minimumMacOS: String
    public var architectures: [String]
    public var devStackSchema: Int

    public init(minimumMacOS: String = "15.0", architectures: [String] = ["arm64"], devStackSchema: Int = 1) {
        self.minimumMacOS = minimumMacOS
        self.architectures = architectures
        self.devStackSchema = devStackSchema
    }
}

public struct RuntimePackFile: Codable, Hashable, Sendable {
    public var path: String
    public var sha256: String
    public var executable: Bool

    public init(path: String, sha256: String, executable: Bool = false) {
        self.path = path
        self.sha256 = sha256
        self.executable = executable
    }
}

public struct RuntimePackSignature: Codable, Hashable, Sendable {
    public var keyID: String
    public var algorithm: String
    public var value: String

    public init(keyID: String, algorithm: String = "ed25519", value: String) {
        self.keyID = keyID
        self.algorithm = algorithm
        self.value = value
    }
}

/// A symbolic link the importer creates after verification. The archive holds
/// no links, so nothing in it can point outside the runtime while it is being
/// unpacked; each link must resolve to a verified file of the same pack.
public struct RuntimePackLink: Codable, Hashable, Sendable {
    public var path: String
    public var target: String

    public init(path: String, target: String) {
        self.path = path
        self.target = target
    }
}

public struct RuntimePackManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var runtime: RuntimeManifest
    public var payload: [RuntimePackFile]
    public var links: [RuntimePackLink]
    public var compatibility: RuntimePackCompatibility
    public var signingIdentity: String
    public var sbomPath: String
    public var signature: RuntimePackSignature?

    public init(
        schemaVersion: Int = 1,
        runtime: RuntimeManifest,
        payload: [RuntimePackFile],
        links: [RuntimePackLink] = [],
        compatibility: RuntimePackCompatibility = .init(),
        signingIdentity: String,
        sbomPath: String,
        signature: RuntimePackSignature? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runtime = runtime
        self.payload = payload
        self.links = links
        self.compatibility = compatibility
        self.signingIdentity = signingIdentity
        self.sbomPath = sbomPath
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, runtime, payload, links, compatibility, signingIdentity, sbomPath, signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        runtime = try container.decode(RuntimeManifest.self, forKey: .runtime)
        payload = try container.decode([RuntimePackFile].self, forKey: .payload)
        links = try container.decodeIfPresent([RuntimePackLink].self, forKey: .links) ?? []
        compatibility = try container.decode(RuntimePackCompatibility.self, forKey: .compatibility)
        signingIdentity = try container.decode(String.self, forKey: .signingIdentity)
        sbomPath = try container.decode(String.self, forKey: .sbomPath)
        signature = try container.decodeIfPresent(RuntimePackSignature.self, forKey: .signature)
    }
}

public struct PHPSiteOverrides: Codable, Hashable, Sendable {
    public var displayErrors: Bool
    public var memoryLimit: String
    public var maxExecutionTime: Int
    public var uploadMaxFilesize: String
    public var postMaxSize: String
    public var maxInputVars: Int

    public init(
        displayErrors: Bool = true,
        memoryLimit: String = "256M",
        maxExecutionTime: Int = 120,
        uploadMaxFilesize: String = "64M",
        postMaxSize: String = "64M",
        maxInputVars: Int = 2_000
    ) {
        self.displayErrors = displayErrors
        self.memoryLimit = memoryLimit
        self.maxExecutionTime = maxExecutionTime
        self.uploadMaxFilesize = uploadMaxFilesize
        self.postMaxSize = postMaxSize
        self.maxInputVars = maxInputVars
    }
}

public struct SiteLogPaths: Codable, Hashable, Sendable {
    public var access: String
    public var error: String

    public init(access: String, error: String) {
        self.access = access
        self.error = error
    }
}

public struct SiteDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var documentRoot: String
    public var tlsEnabled: Bool
    public var phpRuntimeID: String
    public var phpOverrides: PHPSiteOverrides
    public var extensionProfile: String
    public var logs: SiteLogPaths
    /// Writes a starter index.php into the document root when the folder has no
    /// index file yet. Existing files are never overwritten and the default
    /// site always keeps its placeholder.
    public var createPlaceholderIndex: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        documentRoot: String,
        tlsEnabled: Bool = true,
        phpRuntimeID: String = "php-8.5",
        phpOverrides: PHPSiteOverrides = .init(),
        extensionProfile: String = "default",
        createPlaceholderIndex: Bool = true,
        logs: SiteLogPaths
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.documentRoot = documentRoot
        self.tlsEnabled = tlsEnabled
        self.phpRuntimeID = phpRuntimeID
        self.phpOverrides = phpOverrides
        self.extensionProfile = extensionProfile
        self.createPlaceholderIndex = createPlaceholderIndex
        self.logs = logs
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, documentRoot, tlsEnabled, phpRuntimeID
        case phpOverrides, extensionProfile, logs, createPlaceholderIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        documentRoot = try container.decode(String.self, forKey: .documentRoot)
        tlsEnabled = try container.decode(Bool.self, forKey: .tlsEnabled)
        phpRuntimeID = try container.decode(String.self, forKey: .phpRuntimeID)
        phpOverrides = try container.decode(PHPSiteOverrides.self, forKey: .phpOverrides)
        extensionProfile = try container.decode(String.self, forKey: .extensionProfile)
        logs = try container.decode(SiteLogPaths.self, forKey: .logs)
        createPlaceholderIndex = try container.decodeIfPresent(Bool.self, forKey: .createPlaceholderIndex) ?? true
    }
}

public enum DatabaseEngine: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case mysql57 = "mysql-5.7"
    case mysql84 = "mysql-8.4"

    public var displayName: String {
        switch self {
        case .none: "No MySQL"
        case .mysql57: "MySQL 5.7.44"
        case .mysql84: "MySQL 8.4.11 LTS"
        }
    }

    public var isLegacy: Bool { self == .mysql57 }
    public var service: ServiceKind? { self == .none ? nil : ServiceKind(rawValue: rawValue) }
}

public enum PostgreSQLEngine: String, Codable, CaseIterable, Sendable {
    case none = "none"
    case postgresql18 = "postgresql-18"
    public var displayName: String { self == .none ? "No PostgreSQL" : "PostgreSQL 18.6" }
    public var service: ServiceKind? { self == .none ? nil : .postgresql18 }
}

public enum WebServer: String, Codable, CaseIterable, Identifiable, Sendable {
    case apache, nginx
    public var id: String { rawValue }
    public var displayName: String { self == .apache ? "Apache" : "Nginx" }
    public var service: ServiceKind { self == .apache ? .apache : .nginx }
}

public struct AppConfiguration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var sites: [SiteDefinition]
    public var selectedDatabase: DatabaseEngine
    public var selectedPostgreSQL: PostgreSQLEngine
    public var enabledExtensions: [String: Set<String>]
    public var startAtLogin: Bool
    public var importedRuntimeIDs: [String]
    public var selectedWebServer: WebServer
    public var defaultPHPRuntimeID: String
    public var ports: ServicePorts
    public var helperNoticeDismissed: Bool
    public var localNetworkAccess: Bool
    /// Set once the first-run setup wizard has been completed or skipped.
    public var setupWizardCompleted: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sites: [SiteDefinition] = [],
        selectedDatabase: DatabaseEngine = .mysql84,
        selectedPostgreSQL: PostgreSQLEngine = .none,
        enabledExtensions: [String: Set<String>] = [
            "php-7.4": ["redis", "imagick"],
            "php-8.5": ["redis", "imagick", "pgsql", "pdo_pgsql"],
            "php-8.4": ["redis", "imagick", "pgsql", "pdo_pgsql"]
        ],
        startAtLogin: Bool = false,
        importedRuntimeIDs: [String] = [],
        selectedWebServer: WebServer = .apache,
        defaultPHPRuntimeID: String = "php-8.5",
        ports: ServicePorts = ServicePorts(),
        helperNoticeDismissed: Bool = false,
        localNetworkAccess: Bool = false,
        setupWizardCompleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.sites = sites
        self.selectedDatabase = selectedDatabase
        self.selectedPostgreSQL = selectedPostgreSQL
        self.enabledExtensions = enabledExtensions
        self.startAtLogin = startAtLogin
        self.importedRuntimeIDs = importedRuntimeIDs
        self.selectedWebServer = selectedWebServer
        self.defaultPHPRuntimeID = defaultPHPRuntimeID
        self.ports = ports
        self.helperNoticeDismissed = helperNoticeDismissed
        self.localNetworkAccess = localNetworkAccess
        self.setupWizardCompleted = setupWizardCompleted
    }

    public var selectedDatabaseServices: [ServiceKind] {
        [selectedDatabase.service, selectedPostgreSQL.service].compactMap { $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sites, selectedDatabase, selectedPostgreSQL, enabledExtensions, startAtLogin, importedRuntimeIDs, selectedWebServer, defaultPHPRuntimeID, ports, helperNoticeDismissed, localNetworkAccess, setupWizardCompleted
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            sites: try values.decodeIfPresent([SiteDefinition].self, forKey: .sites) ?? [],
            selectedDatabase: try values.decodeIfPresent(DatabaseEngine.self, forKey: .selectedDatabase) ?? .mysql84,
            selectedPostgreSQL: try values.decodeIfPresent(PostgreSQLEngine.self, forKey: .selectedPostgreSQL) ?? .none,
            enabledExtensions: try values.decodeIfPresent([String: Set<String>].self, forKey: .enabledExtensions) ?? [:],
            startAtLogin: try values.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false,
            importedRuntimeIDs: try values.decodeIfPresent([String].self, forKey: .importedRuntimeIDs) ?? [],
            selectedWebServer: try values.decodeIfPresent(WebServer.self, forKey: .selectedWebServer) ?? .apache,
            defaultPHPRuntimeID: try values.decodeIfPresent(String.self, forKey: .defaultPHPRuntimeID) ?? "php-8.5",
            ports: try values.decodeIfPresent(ServicePorts.self, forKey: .ports) ?? ServicePorts(),
            helperNoticeDismissed: try values.decodeIfPresent(Bool.self, forKey: .helperNoticeDismissed) ?? false,
            localNetworkAccess: try values.decodeIfPresent(Bool.self, forKey: .localNetworkAccess) ?? false,
            setupWizardCompleted: try values.decodeIfPresent(Bool.self, forKey: .setupWizardCompleted) ?? false
        )
        if schemaVersion < 2 {
            for id in ["php-8.4", "php-8.5"] { enabledExtensions[id, default: []].formUnion(["pgsql", "pdo_pgsql"]) }
        }
        if schemaVersion < Self.currentSchemaVersion { schemaVersion = Self.currentSchemaVersion }
    }

}

public enum ServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apache
    case nginx
    case php74 = "php-7.4"
    case php84 = "php-8.4"
    case php85 = "php-8.5"
    case mysql57 = "mysql-5.7"
    case mysql84 = "mysql-8.4"
    case postgresql18 = "postgresql-18"
    case mailpit

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .apache: "Apache"
        case .nginx: "Nginx"
        case .php74: "PHP 7.4"
        case .php84: "PHP 8.4"
        case .php85: "PHP 8.5"
        case .mysql57: "MySQL 5.7"
        case .mysql84: "MySQL 8.4"
        case .postgresql18: "PostgreSQL 18"
        case .mailpit: "Mailpit"
        }
    }
    public var phpRuntimeID: String? {
        switch self { case .php74, .php84, .php85: rawValue; default: nil }
    }
    public var runtimeID: String {
        switch self {
        case .apache: "apache-2.4"
        case .nginx: "nginx-1.30"
        case .mailpit: "mailpit-1.31.1"
        default: rawValue
        }
    }
}

public enum ServicePhase: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed
}

public struct ServiceFailure: Codable, Hashable, LocalizedError, Sendable {
    public var errorDescription: String? { message + (logExcerpt.map { "\n" + $0 } ?? "") }
    public var message: String
    public var exitCode: Int32?
    public var failedProbe: String?
    public var logExcerpt: String?
    public var recoveryAction: String?

    public init(message: String, exitCode: Int32? = nil, failedProbe: String? = nil, logExcerpt: String? = nil, recoveryAction: String? = nil) {
        self.message = message
        self.exitCode = exitCode
        self.failedProbe = failedProbe
        self.logExcerpt = logExcerpt
        self.recoveryAction = recoveryAction
    }
}

public struct ServiceState: Codable, Hashable, Identifiable, Sendable {
    public var id: ServiceKind { service }
    public var service: ServiceKind
    public var phase: ServicePhase
    public var pid: Int32?
    public var changedAt: Date
    public var failure: ServiceFailure?

    public init(service: ServiceKind, phase: ServicePhase = .stopped, pid: Int32? = nil, changedAt: Date = Date(), failure: ServiceFailure? = nil) {
        self.service = service
        self.phase = phase
        self.pid = pid
        self.changedAt = changedAt
        self.failure = failure
    }
}

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
}

/// An action that resolves a diagnostic result, offered next to it in Doctor.
public enum DiagnosticFix: Codable, Hashable, Sendable {
    /// Stops the helper running from another DevStack copy, moves that copy
    /// to the Trash and sets up this copy's helper.
    case removeOtherHelper(executable: String)
    /// Sets up the helper, or registers it again when it does not respond.
    case repairHelper
    /// Trusts the DevStack CA for this user.
    case trustCertificate
    /// Installs a runtime pack and what it needs.
    case installRuntime(String)
}

public struct DiagnosticResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var severity: DiagnosticSeverity
    public var evidence: String
    public var remediation: String?
    public var containsSensitiveData: Bool
    public var fix: DiagnosticFix?

    public init(id: String, title: String, severity: DiagnosticSeverity, evidence: String, remediation: String? = nil,
                containsSensitiveData: Bool = false, fix: DiagnosticFix? = nil) {
        self.id = id
        self.title = title
        self.severity = severity
        self.evidence = evidence
        self.remediation = remediation
        self.containsSensitiveData = containsSensitiveData
        self.fix = fix
    }
}

public struct DiagnosticReport: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var results: [DiagnosticResult]

    public init(generatedAt: Date = Date(), appVersion: String, results: [DiagnosticResult]) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.results = results
    }
}

public struct HostMapping: Codable, Hashable, Sendable {
    public var hostname: String
    public var ipv4: String
    public var ipv6: String

    public init(hostname: String, ipv4: String = "127.0.0.1", ipv6: String = "::1") {
        self.hostname = hostname
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

public struct PortForwardingEntry: Codable, Hashable, Sendable {
    public var publicPort: UInt16
    public var upstreamPort: UInt16
    /// When true the forwarder prefixes each connection with a PROXY protocol
    /// header so the web server can recover the real client address instead of
    /// seeing the loopback forwarder.
    public var proxyProtocol: Bool

    public init(publicPort: UInt16, upstreamPort: UInt16, proxyProtocol: Bool = false) {
        self.publicPort = publicPort
        self.upstreamPort = upstreamPort
        self.proxyProtocol = proxyProtocol
    }

    private enum CodingKeys: String, CodingKey {
        case publicPort, upstreamPort, proxyProtocol
    }

    // Older helpers simply ignore the key; accepting its absence keeps the
    // payload decodable in both directions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.publicPort = try container.decode(UInt16.self, forKey: .publicPort)
        self.upstreamPort = try container.decode(UInt16.self, forKey: .upstreamPort)
        self.proxyProtocol = try container.decodeIfPresent(Bool.self, forKey: .proxyProtocol) ?? false
    }
}

public struct PortForwardingConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var entries: [PortForwardingEntry]
    public var lanEntries: [PortForwardingEntry]

    public init(enabled: Bool, entries: [PortForwardingEntry] = [], lanEntries: [PortForwardingEntry] = []) {
        self.enabled = enabled
        self.entries = entries
        self.lanEntries = lanEntries
    }
}

/// User-configurable ports for every stack service.
///
/// Ports below 1024 cannot be bound by the unprivileged service processes. When one is
/// requested, the service keeps listening on its unprivileged fallback port and the
/// privileged helper forwards the requested public port to it on the loopback interface.
public struct ServicePorts: Codable, Hashable, Sendable {
    public var webHTTP: UInt16
    public var webHTTPS: UInt16
    public var mysql: UInt16
    public var postgresql: UInt16
    public var mailpitSMTP: UInt16
    public var mailpitInbox: UInt16

    public init(
        webHTTP: UInt16 = ServicePorts.webHTTPFallback,
        webHTTPS: UInt16 = ServicePorts.webHTTPSFallback,
        mysql: UInt16 = ServicePorts.mysqlFallback,
        postgresql: UInt16 = ServicePorts.postgresqlFallback,
        mailpitSMTP: UInt16 = ServicePorts.mailpitSMTPFallback,
        mailpitInbox: UInt16 = ServicePorts.mailpitInboxFallback
    ) {
        self.webHTTP = webHTTP
        self.webHTTPS = webHTTPS
        self.mysql = mysql
        self.postgresql = postgresql
        self.mailpitSMTP = mailpitSMTP
        self.mailpitInbox = mailpitInbox
    }

    public static let webHTTPFallback: UInt16 = 8080
    public static let webHTTPSFallback: UInt16 = 8443
    public static let mysqlFallback: UInt16 = 3306
    public static let postgresqlFallback: UInt16 = 5432
    public static let mailpitSMTPFallback: UInt16 = 1025
    public static let mailpitInboxFallback: UInt16 = 8025
    /// Loopback listeners that accept the helper's PROXY protocol connections.
    /// They exist only while the corresponding public port is forwarded.
    public static let proxyHTTPFallback: UInt16 = 8082
    public static let proxyHTTPSFallback: UInt16 = 8444

    /// The port the web server actually listens on.
    public var webHTTPListen: UInt16 { webHTTP < 1024 ? Self.webHTTPFallback : webHTTP }
    public var webHTTPSListen: UInt16 { webHTTPS < 1024 ? Self.webHTTPSFallback : webHTTPS }
    public var mysqlListen: UInt16 { mysql < 1024 ? Self.mysqlFallback : mysql }
    public var postgresqlListen: UInt16 { postgresql < 1024 ? Self.postgresqlFallback : postgresql }
    public var mailpitSMTPListen: UInt16 { mailpitSMTP < 1024 ? Self.mailpitSMTPFallback : mailpitSMTP }
    public var mailpitInboxListen: UInt16 { mailpitInbox < 1024 ? Self.mailpitInboxFallback : mailpitInbox }

    /// PROXY-protocol listener for forwarded HTTP, when the public port needs
    /// the helper. The helper sends the client address ahead of the request.
    public var proxyHTTPListen: UInt16? { webHTTP < 1024 ? Self.proxyHTTPFallback : nil }
    public var proxyHTTPSListen: UInt16? { webHTTPS < 1024 ? Self.proxyHTTPSFallback : nil }

    /// Public ports the helper must forward to the unprivileged listener. When
    /// the helper supports the PROXY protocol, web traffic is forwarded to the
    /// dedicated listeners so the web server learns the real client address.
    public func forwardingEntries(proxyProtocol: Bool) -> [PortForwardingEntry] {
        var entries: [PortForwardingEntry] = []
        func append(_ publicPort: UInt16, direct: UInt16, proxy: UInt16? = nil, web: Bool = false) {
            guard publicPort < 1024, publicPort != direct else { return }
            if web, proxyProtocol, let proxy {
                entries.append(PortForwardingEntry(publicPort: publicPort, upstreamPort: proxy, proxyProtocol: true))
            } else {
                entries.append(PortForwardingEntry(publicPort: publicPort, upstreamPort: direct))
            }
        }
        append(webHTTP, direct: webHTTPListen, proxy: proxyHTTPListen, web: true)
        append(webHTTPS, direct: webHTTPSListen, proxy: proxyHTTPSListen, web: true)
        append(mysql, direct: mysqlListen)
        append(postgresql, direct: postgresqlListen)
        append(mailpitSMTP, direct: mailpitSMTPListen)
        append(mailpitInbox, direct: mailpitInboxListen)
        return entries
    }

    public var forwardings: [PortForwardingEntry] { forwardingEntries(proxyProtocol: false) }

    public var requiresHelper: Bool { !forwardings.isEmpty }

    /// Ports the helper refuses to bind even when requested.
    public static let reservedPorts: Set<UInt16> = [22]

    /// Ports that are privileged but not forwardable.
    public var reservedRequests: [UInt16] {
        [webHTTP, webHTTPS, mysql, postgresql, mailpitSMTP, mailpitInbox].filter { Self.reservedPorts.contains($0) }
    }

    /// Listener conflicts that make the stack unable to start.
    public var collisions: [UInt16] {
        var listeners: [UInt16] = [webHTTPListen, webHTTPSListen, mysqlListen, postgresqlListen, mailpitSMTPListen, mailpitInboxListen]
        if let proxyHTTPListen { listeners.append(proxyHTTPListen) }
        if let proxyHTTPSListen { listeners.append(proxyHTTPSListen) }
        var seen = Set<UInt16>()
        var duplicates = Set<UInt16>()
        for port in listeners where !seen.insert(port).inserted { duplicates.insert(port) }
        let publics: [UInt16] = [webHTTP, webHTTPS, mysql, postgresql, mailpitSMTP, mailpitInbox].filter { $0 < 1024 }
        var publicSeen = Set<UInt16>()
        for port in publics where !publicSeen.insert(port).inserted { duplicates.insert(port) }
        return duplicates.sorted()
    }

    public var privilegedPorts: [UInt16] {
        [webHTTP, webHTTPS, mysql, postgresql, mailpitSMTP, mailpitInbox].filter { $0 < 1024 && !Self.reservedPorts.contains($0) }
    }

    public var isValid: Bool { collisions.isEmpty && reservedRequests.isEmpty }
}
