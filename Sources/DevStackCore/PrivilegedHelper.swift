import Foundation

public enum PrivilegedHelperConstants {
    public static let machServiceName = "app.devstack.desktop.helper"
    public static let applicationBundleIdentifier = "app.devstack.desktop"
    public static let hostsBeginMarker = "# BEGIN DEVSTACK MANAGED — DO NOT EDIT"
    public static let hostsEndMarker = "# END DEVSTACK MANAGED"
}

public struct LocalCARequest: Codable, Hashable, Sendable {
    public var certificateDER: Data

    public init(certificateDER: Data) {
        self.certificateDER = certificateDER
    }
}

/// The helper's local DNS service: it answers the listed hostnames with the
/// Mac's LAN address and forwards every other query to the system resolvers.
public struct DNSConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var hostnames: [String]
    public var answerAddress: String

    public init(enabled: Bool, hostnames: [String] = [], answerAddress: String = "") {
        self.enabled = enabled
        self.hostnames = hostnames
        self.answerAddress = answerAddress
    }
}

public struct PrivilegedHelperStatus: Codable, Hashable, Sendable {
    public var hostMappingsInstalled: Bool
    public var portForwardingEnabled: Bool
    public var version: String
    /// App build the running helper was started with. When this differs from
    /// the installed app's build, the helper predates an app update and the
    /// app retires it so launchd starts the current binary.
    public var build: String
    public var dnsEnabled: Bool
    public var dnsAnswerAddress: String?
    public var dnsFailure: String?

    public init(hostMappingsInstalled: Bool, portForwardingEnabled: Bool, version: String, build: String = "", dnsEnabled: Bool = false, dnsAnswerAddress: String? = nil, dnsFailure: String? = nil) {
        self.hostMappingsInstalled = hostMappingsInstalled
        self.portForwardingEnabled = portForwardingEnabled
        self.version = version
        self.build = build
        self.dnsEnabled = dnsEnabled
        self.dnsAnswerAddress = dnsAnswerAddress
        self.dnsFailure = dnsFailure
    }

    private enum CodingKeys: String, CodingKey {
        case hostMappingsInstalled, portForwardingEnabled, version, build
        case dnsEnabled, dnsAnswerAddress, dnsFailure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hostMappingsInstalled = try c.decode(Bool.self, forKey: .hostMappingsInstalled)
        self.portForwardingEnabled = try c.decode(Bool.self, forKey: .portForwardingEnabled)
        self.version = try c.decode(String.self, forKey: .version)
        self.build = try c.decodeIfPresent(String.self, forKey: .build) ?? ""
        self.dnsEnabled = try c.decodeIfPresent(Bool.self, forKey: .dnsEnabled) ?? false
        self.dnsAnswerAddress = try c.decodeIfPresent(String.self, forKey: .dnsAnswerAddress)
        self.dnsFailure = try c.decodeIfPresent(String.self, forKey: .dnsFailure)
    }
}

@objc public protocol PrivilegedHelperXPCProtocol {
    func applyHostMappings(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func setPortForwarding(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func setDNSConfiguration(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func removeManagedState(withReply reply: @escaping (Data?, NSError?) -> Void)
    func status(withReply reply: @escaping (Data?, NSError?) -> Void)
    /// Exits after replying so launchd starts the helper binary that is now on
    /// disk. The app calls this when the running helper's build is outdated.
    func retire(withReply reply: @escaping (Data?, NSError?) -> Void)
}

public enum PrivilegedRequestValidationError: LocalizedError, Equatable, Sendable {
    case tooManyHostnames
    case nonLoopbackMapping
    case invalidPortForwarding
    case invalidCertificate
    case invalidDNSAddress

    public var errorDescription: String? {
        switch self {
        case .tooManyHostnames: "A maximum of 256 host mappings is allowed."
        case .nonLoopbackMapping: "Host mappings must point only to the IPv4 and IPv6 loopback addresses."
        case .invalidPortForwarding: "Only loopback forwarding from a privileged port to an unprivileged DevStack listener is allowed."
        case .invalidCertificate: "The CA certificate payload is empty or too large."
        case .invalidDNSAddress: "The DNS answer address must be a private LAN IPv4 address."
        }
    }
}

public enum PrivilegedRequestValidator {
    public static func hostMappings(_ mappings: [HostMapping]) throws -> [HostMapping] {
        guard mappings.count <= 256 else { throw PrivilegedRequestValidationError.tooManyHostnames }
        var hostnames = Set<String>()
        return try mappings.map { mapping in
            guard mapping.ipv4 == "127.0.0.1", mapping.ipv6 == "::1" else {
                throw PrivilegedRequestValidationError.nonLoopbackMapping
            }
            let hostname = try HostnameValidator.validate(mapping.hostname, existing: hostnames)
            hostnames.insert(hostname)
            return HostMapping(hostname: hostname)
        }.sorted { $0.hostname < $1.hostname }
    }

    public static func portForwarding(_ configuration: PortForwardingConfiguration) throws -> PortForwardingConfiguration {
        guard configuration.entries.count <= 8 else {
            throw PrivilegedRequestValidationError.invalidPortForwarding
        }
        var publicPorts = Set<UInt16>()
        for entry in configuration.entries {
            guard entry.publicPort >= 1, entry.publicPort < 1024,
                  entry.upstreamPort >= 1024, entry.upstreamPort != entry.publicPort,
                  !ServicePorts.reservedPorts.contains(entry.publicPort),
                  publicPorts.insert(entry.publicPort).inserted else {
                throw PrivilegedRequestValidationError.invalidPortForwarding
            }
        }
        guard configuration.lanEntries.count <= 8 else {
            throw PrivilegedRequestValidationError.invalidPortForwarding
        }
        var lanPorts = Set<UInt16>()
        for entry in configuration.lanEntries {
            guard entry.publicPort >= 1, entry.upstreamPort >= 1024,
                  !ServicePorts.reservedPorts.contains(entry.publicPort),
                  lanPorts.insert(entry.publicPort).inserted else {
                throw PrivilegedRequestValidationError.invalidPortForwarding
            }
        }
        return configuration
    }

    public static func dnsConfiguration(_ configuration: DNSConfiguration) throws -> DNSConfiguration {
        guard configuration.hostnames.count <= 256 else { throw PrivilegedRequestValidationError.tooManyHostnames }
        var hostnames = Set<String>()
        let normalized = try configuration.hostnames.map { name -> String in
            let hostname = try HostnameValidator.validate(name, existing: hostnames)
            hostnames.insert(hostname)
            return hostname
        }
        if configuration.enabled {
            guard LocalNetwork.isPrivateIPv4(configuration.answerAddress),
                  !configuration.answerAddress.hasPrefix("127."),
                  !configuration.answerAddress.hasPrefix("169.254.") else {
                throw PrivilegedRequestValidationError.invalidDNSAddress
            }
        }
        return DNSConfiguration(enabled: configuration.enabled, hostnames: normalized.sorted(), answerAddress: configuration.answerAddress)
    }

    public static func localCA(_ request: LocalCARequest) throws -> LocalCARequest {
        guard !request.certificateDER.isEmpty, request.certificateDER.count <= 64 * 1_024 else {
            throw PrivilegedRequestValidationError.invalidCertificate
        }
        return request
    }
}

public enum HostsFileEditor {
    public static func replacingManagedSection(in original: String, mappings: [HostMapping]) throws -> String {
        let mappings = try PrivilegedRequestValidator.hostMappings(mappings)
        let cleaned = removingManagedSection(from: original)
        guard !mappings.isEmpty else { return normalizedTrailingNewline(cleaned) }
        let entries = mappings.flatMap { mapping in
            ["127.0.0.1\t\(mapping.hostname)", "::1\t\(mapping.hostname)"]
        }
        let section = ([PrivilegedHelperConstants.hostsBeginMarker] + entries + [PrivilegedHelperConstants.hostsEndMarker]).joined(separator: "\n")
        return normalizedTrailingNewline(cleaned) + section + "\n"
    }

    public static func removingManagedSection(from original: String) -> String {
        var output: [Substring] = []
        var insideManagedSection = false
        for line in original.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == Substring(PrivilegedHelperConstants.hostsBeginMarker) {
                insideManagedSection = true
                continue
            }
            if line == Substring(PrivilegedHelperConstants.hostsEndMarker) {
                insideManagedSection = false
                continue
            }
            if !insideManagedSection { output.append(line) }
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    private static func normalizedTrailingNewline(_ value: String) -> String {
        value.isEmpty ? "" : value.trimmingCharacters(in: .newlines) + "\n"
    }
}
