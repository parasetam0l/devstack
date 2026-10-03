import Foundation

public enum HostnameValidationError: LocalizedError, Equatable, Sendable {
    case empty
    case tooLong
    case malformedLabel(String)
    case ipLiteral
    case wildcard
    case nonASCII
    case duplicate
    case reserved

    public var errorDescription: String? {
        switch self {
        case .empty: "Hostname cannot be empty."
        case .tooLong: "Hostname exceeds 253 characters."
        case .malformedLabel(let label): "Invalid hostname label: \(label)"
        case .ipLiteral: "IP literals are not valid site hostnames."
        case .wildcard: "Wildcard hostnames are not supported."
        case .nonASCII: "Hostnames must use ASCII characters."
        case .duplicate: "A site already uses this hostname."
        case .reserved: "This hostname is reserved for DevStack's built-in tools."
        }
    }
}

public enum HostnameValidator {
    /// Hostnames of the built-in tool vhosts. They always get host mappings,
    /// certificates and DNS answers, so no site may claim them.
    public static let managementHostnames = ["phpmyadmin.localhost", "mailpit.localhost", "adminer.localhost", "postgresql.localhost"]

    /// Validates a site hostname: the general rules, plus the management
    /// hostnames that belong to DevStack itself.
    public static func validateSite(_ input: String, existing: some Sequence<String> = []) throws -> String {
        let hostname = try validate(input, existing: existing)
        guard !managementHostnames.contains(hostname) else { throw HostnameValidationError.reserved }
        return hostname
    }

    public static func normalize(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    public static func validate(_ input: String, existing: some Sequence<String> = []) throws -> String {
        let hostname = normalize(input)
        guard !hostname.isEmpty else { throw HostnameValidationError.empty }
        guard hostname.utf8.count <= 253 else { throw HostnameValidationError.tooLong }
        guard hostname.unicodeScalars.allSatisfy(\.isASCII) else { throw HostnameValidationError.nonASCII }
        guard !hostname.contains("*") else { throw HostnameValidationError.wildcard }
        guard !hostname.contains(":") && !isIPv4(hostname) else { throw HostnameValidationError.ipLiteral }

        for label in hostname.split(separator: ".", omittingEmptySubsequences: false) {
            let text = String(label)
            guard !text.isEmpty,
                  text.utf8.count <= 63,
                  text.first?.isLetter == true || text.first?.isNumber == true,
                  text.last?.isLetter == true || text.last?.isNumber == true,
                  text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
            else { throw HostnameValidationError.malformedLabel(text) }
        }

        let normalizedExisting = Set(existing.map(normalize))
        guard !normalizedExisting.contains(hostname) else { throw HostnameValidationError.duplicate }
        return hostname
    }

    public static func shadowsPublicDomain(_ hostname: String) -> Bool {
        let normalized = normalize(hostname)
        return normalized != "test" && !normalized.hasSuffix(".test") && normalized != "localhost" && !normalized.hasSuffix(".localhost")
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }
}

