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

public struct PrivilegedHelperStatus: Codable, Hashable, Sendable {
    public var hostMappingsInstalled: Bool
    public var portForwardingEnabled: Bool
    public var localCATrusted: Bool
    public var version: String

    public init(hostMappingsInstalled: Bool, portForwardingEnabled: Bool, localCATrusted: Bool, version: String) {
        self.hostMappingsInstalled = hostMappingsInstalled
        self.portForwardingEnabled = portForwardingEnabled
        self.localCATrusted = localCATrusted
        self.version = version
    }
}

@objc public protocol PrivilegedHelperXPCProtocol {
    func applyHostMappings(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func setPortForwarding(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func trustLocalCA(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func removeManagedState(withReply reply: @escaping (Data?, NSError?) -> Void)
    func status(withReply reply: @escaping (Data?, NSError?) -> Void)
}

public enum PrivilegedRequestValidationError: LocalizedError, Equatable, Sendable {
    case tooManyHostnames
    case nonLoopbackMapping
    case invalidPortForwarding
    case invalidCertificate

    public var errorDescription: String? {
        switch self {
        case .tooManyHostnames: "A maximum of 256 host mappings is allowed."
        case .nonLoopbackMapping: "Host mappings must point only to the IPv4 and IPv6 loopback addresses."
        case .invalidPortForwarding: "Only loopback forwarding from 80 to 8080 and 443 to 8443 is allowed."
        case .invalidCertificate: "The CA certificate payload is empty or too large."
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
        guard configuration.httpUpstreamPort == 8080, configuration.httpsUpstreamPort == 8443 else {
            throw PrivilegedRequestValidationError.invalidPortForwarding
        }
        return configuration
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
