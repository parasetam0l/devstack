import Foundation

public enum RuntimeKind: String, Codable, CaseIterable, Sendable {
    case apache
    case php
    case mysql
    case mailpit
    case phpMyAdmin = "phpmyadmin"
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
        minimumMacOS: String = "27.0",
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

    public init(minimumMacOS: String = "27.0", architectures: [String] = ["arm64"], devStackSchema: Int = 1) {
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

public struct RuntimePackManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var runtime: RuntimeManifest
    public var payload: [RuntimePackFile]
    public var compatibility: RuntimePackCompatibility
    public var signingIdentity: String
    public var sbomPath: String
    public var signature: RuntimePackSignature?

    public init(
        schemaVersion: Int = 1,
        runtime: RuntimeManifest,
        payload: [RuntimePackFile],
        compatibility: RuntimePackCompatibility = .init(),
        signingIdentity: String,
        sbomPath: String,
        signature: RuntimePackSignature? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runtime = runtime
        self.payload = payload
        self.compatibility = compatibility
        self.signingIdentity = signingIdentity
        self.sbomPath = sbomPath
        self.signature = signature
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

    public init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        documentRoot: String,
        tlsEnabled: Bool = true,
        phpRuntimeID: String = "php-8.5",
        phpOverrides: PHPSiteOverrides = .init(),
        extensionProfile: String = "default",
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
        self.logs = logs
    }
}

public enum DatabaseEngine: String, Codable, CaseIterable, Sendable {
    case mysql57 = "mysql-5.7"
    case mysql84 = "mysql-8.4"

    public var displayName: String {
        switch self {
        case .mysql57: "MySQL 5.7.44"
        case .mysql84: "MySQL 8.4.11 LTS"
        }
    }

    public var isLegacy: Bool { self == .mysql57 }
}

public struct AppConfiguration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sites: [SiteDefinition]
    public var selectedDatabase: DatabaseEngine
    public var enabledExtensions: [String: Set<String>]
    public var startAtLogin: Bool
    public var importedRuntimeIDs: [String]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sites: [SiteDefinition] = [],
        selectedDatabase: DatabaseEngine = .mysql84,
        enabledExtensions: [String: Set<String>] = [
            "php-7.4": ["redis", "imagick"],
            "php-8.5": ["redis", "imagick"]
        ],
        startAtLogin: Bool = false,
        importedRuntimeIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sites = sites
        self.selectedDatabase = selectedDatabase
        self.enabledExtensions = enabledExtensions
        self.startAtLogin = startAtLogin
        self.importedRuntimeIDs = importedRuntimeIDs
    }
}

public enum ServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apache
    case php74 = "php-7.4"
    case php85 = "php-8.5"
    case mysql57 = "mysql-5.7"
    case mysql84 = "mysql-8.4"
    case mailpit

    public var id: String { rawValue }
}

public enum ServicePhase: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed
}

public struct ServiceFailure: Codable, Hashable, Error, Sendable {
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

public struct DiagnosticResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var severity: DiagnosticSeverity
    public var evidence: String
    public var remediation: String?
    public var containsSensitiveData: Bool

    public init(id: String, title: String, severity: DiagnosticSeverity, evidence: String, remediation: String? = nil, containsSensitiveData: Bool = false) {
        self.id = id
        self.title = title
        self.severity = severity
        self.evidence = evidence
        self.remediation = remediation
        self.containsSensitiveData = containsSensitiveData
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

public struct PortForwardingConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var httpUpstreamPort: UInt16
    public var httpsUpstreamPort: UInt16

    public init(enabled: Bool, httpUpstreamPort: UInt16 = 8080, httpsUpstreamPort: UInt16 = 8443) {
        self.enabled = enabled
        self.httpUpstreamPort = httpUpstreamPort
        self.httpsUpstreamPort = httpsUpstreamPort
    }
}
