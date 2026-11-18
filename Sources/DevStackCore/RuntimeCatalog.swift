import CryptoKit
import Foundation

/// The signed catalog devstack-runtimes publishes so DevStack learns about
/// newer pack revisions without an app release. The envelope carries the
/// catalog JSON as base64 plus an Ed25519 signature over those exact bytes.
public struct RuntimeCatalogEnvelope: Codable, Hashable, Sendable {
    public var payload: String
    public var signature: RuntimePackSignature

    public init(payload: String, signature: RuntimePackSignature) {
        self.payload = payload
        self.signature = signature
    }
}

/// One catalog entry: a pin exactly as in runtime-packs.json, plus the
/// oldest DevStack version that may install it.
public struct RuntimeCatalogPack: Codable, Hashable, Sendable {
    public var pin: RuntimePackPin
    public var minimumAppVersion: String?

    public init(pin: RuntimePackPin, minimumAppVersion: String? = nil) {
        self.pin = pin
        self.minimumAppVersion = minimumAppVersion
    }

    private enum CodingKeys: String, CodingKey { case minimumAppVersion }

    public init(from decoder: Decoder) throws {
        pin = try RuntimePackPin(from: decoder)
        minimumAppVersion = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .minimumAppVersion)
    }

    public func encode(to encoder: Encoder) throws {
        try pin.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(minimumAppVersion, forKey: .minimumAppVersion)
    }
}

public enum RuntimeCatalogError: LocalizedError, Equatable, Sendable {
    case malformedEnvelope
    case unsupportedSignatureAlgorithm(String)
    case unknownSigningKey(String)
    case invalidSignature
    case unsupportedSchema(Int)
    case olderSequence(received: Int64, accepted: Int64)
    case malformedCatalog(String)

    public var errorDescription: String? {
        switch self {
        case .malformedEnvelope: "The runtime catalog is not a signed catalog envelope."
        case .unsupportedSignatureAlgorithm(let algorithm): "The runtime catalog uses an unsupported signature algorithm: \(algorithm)."
        case .unknownSigningKey(let keyID): "The runtime catalog is signed with an unknown key: \(keyID)."
        case .invalidSignature: "The runtime catalog signature is not valid."
        case .unsupportedSchema(let version): "The runtime catalog uses schema \(version), which this DevStack does not read."
        case .olderSequence(let received, let accepted): "The runtime catalog is older (\(received)) than one already accepted (\(accepted))."
        case .malformedCatalog(let reason): "The runtime catalog is malformed: \(reason)"
        }
    }
}

/// Encodable for tools that write catalogs; read one with `decode(payload:)`
/// or `verify(envelope:trustedKeys:acceptedSequence:)`, which also validate it.
public struct RuntimeCatalog: Encodable, Hashable, Sendable {
    public static let schemaVersion = 1
    /// Where the app looks for the current catalog.
    public static let defaultURL = URL(string: "https://github.com/parasetam0l/devstack-runtimes/releases/download/runtime-catalog/runtime-catalog.json")!
    /// Envelopes larger than this are refused before decoding.
    public static let maximumSize = 1_048_576

    public var schemaVersion: Int
    public var sequence: Int64
    public var issued: String
    public var packs: [RuntimeCatalogPack]

    public init(sequence: Int64, issued: String, packs: [RuntimeCatalogPack]) {
        self.schemaVersion = Self.schemaVersion
        self.sequence = sequence
        self.issued = issued
        self.packs = packs
    }

    // MARK: Decoding and signing

    /// Decodes and validates the catalog JSON (the envelope's payload).
    public static func decode(payload data: Data) throws -> RuntimeCatalog {
        struct Header: Decodable { var schemaVersion: Int }
        struct Body: Decodable { var schemaVersion: Int; var sequence: Int64; var issued: String; var packs: [RuntimeCatalogPack] }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw RuntimeCatalogError.malformedCatalog("schemaVersion is missing")
        }
        guard header.schemaVersion == schemaVersion else { throw RuntimeCatalogError.unsupportedSchema(header.schemaVersion) }
        let body: Body
        do { body = try JSONDecoder().decode(Body.self, from: data) }
        catch { throw RuntimeCatalogError.malformedCatalog(String(describing: error)) }
        guard body.sequence > 0 else { throw RuntimeCatalogError.malformedCatalog("sequence must be positive") }
        let dates = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        guard dates.date(from: body.issued) ?? fractional.date(from: body.issued) != nil else {
            throw RuntimeCatalogError.malformedCatalog("issued is not an ISO 8601 date")
        }
        var seen: Set<String> = []
        for pack in body.packs {
            try validate(pack)
            guard seen.insert(pack.pin.id).inserted else { throw RuntimeCatalogError.malformedCatalog("\(pack.pin.id) is listed twice") }
        }
        return RuntimeCatalog(sequence: body.sequence, issued: body.issued, packs: body.packs)
    }

    private static func validate(_ pack: RuntimeCatalogPack) throws {
        let pin = pack.pin
        func fail(_ reason: String) -> RuntimeCatalogError { .malformedCatalog("\(pin.id.isEmpty ? "a pack" : pin.id): \(reason)") }
        let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard !pin.id.isEmpty, pin.id.unicodeScalars.allSatisfy(idCharacters.contains) else { throw fail("invalid id") }
        guard !pin.version.isEmpty, !pin.name.isEmpty else { throw fail("missing version or name") }
        guard pin.packRevision >= 1 else { throw fail("packRevision must be at least 1") }
        guard pin.url.scheme == "https", pin.url.host != nil else { throw fail("url must be https") }
        guard pin.sha256.count == 64, pin.sha256.allSatisfy(\.isHexDigit) else { throw fail("sha256 must be 64 hex digits") }
        guard pin.size > 0 else { throw fail("size must be positive") }
        guard parseVersion(pin.minimumMacOS) != nil else { throw fail("minimumMacOS is not a version") }
        if let minimum = pack.minimumAppVersion, parseVersion(minimum) == nil { throw fail("minimumAppVersion is not a version") }
    }

    /// Signs the catalog bytes as they are and returns the envelope JSON.
    /// Refuses bytes that are not a valid catalog.
    public static func sign(payload data: Data, privateKey: Curve25519.Signing.PrivateKey, keyID: String) throws -> Data {
        _ = try decode(payload: data)
        let signature = try privateKey.signature(for: data)
        let envelope = RuntimeCatalogEnvelope(
            payload: data.base64EncodedString(),
            signature: RuntimePackSignature(keyID: keyID, algorithm: "ed25519", value: signature.base64EncodedString())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    /// Verifies an envelope against trusted keys and returns its catalog.
    /// `acceptedSequence` is the highest sequence this install has accepted;
    /// an older catalog is refused, the same one again is not.
    public static func verify(envelope data: Data, trustedKeys: [String: Data], acceptedSequence: Int64? = nil) throws -> RuntimeCatalog {
        guard data.count <= maximumSize,
              let envelope = try? JSONDecoder().decode(RuntimeCatalogEnvelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payload)
        else { throw RuntimeCatalogError.malformedEnvelope }
        guard envelope.signature.algorithm.lowercased() == "ed25519" else {
            throw RuntimeCatalogError.unsupportedSignatureAlgorithm(envelope.signature.algorithm)
        }
        guard let keyData = trustedKeys[envelope.signature.keyID] else {
            throw RuntimeCatalogError.unknownSigningKey(envelope.signature.keyID)
        }
        guard let signature = Data(base64Encoded: envelope.signature.value),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signature, for: payload)
        else { throw RuntimeCatalogError.invalidSignature }
        let catalog = try decode(payload: payload)
        if let acceptedSequence, catalog.sequence < acceptedSequence {
            throw RuntimeCatalogError.olderSequence(received: catalog.sequence, accepted: acceptedSequence)
        }
        return catalog
    }

    // MARK: Merging

    /// The bundled catalog with each pin replaced by this catalog's entry for
    /// the same id when that entry is newer and this Mac and app can use it.
    /// Ids the bundled catalog doesn't know are ignored.
    public func merged(into bundled: RuntimePackCatalog, macOSVersion: String, appVersion: String?) -> RuntimePackCatalog {
        let known = Set(bundled.packs.map(\.id)).union(bundled.packs.flatMap(\.contents))
        var result = bundled
        for pack in packs {
            guard let index = result.packs.firstIndex(where: { $0.id == pack.pin.id }) else { continue }
            let current = result.packs[index]
            guard Self.isNewer(pack.pin, than: current),
                  Self.compareVersions(pack.pin.minimumMacOS, macOSVersion) != .orderedDescending,
                  Set(pack.pin.requires).union(pack.pin.contents).isSubset(of: known)
            else { continue }
            if let minimum = pack.minimumAppVersion {
                // Development builds without a version accept any minimum.
                if let appVersion, Self.parseVersion(appVersion) != nil,
                   Self.compareVersions(minimum, appVersion) == .orderedDescending { continue }
            }
            result.packs[index] = pack.pin
        }
        return result
    }

    /// Newer means a higher version, or the same version with a higher pack revision.
    public static func isNewer(_ candidate: RuntimePackPin, than current: RuntimePackPin) -> Bool {
        switch compareVersions(candidate.version, current.version) {
        case .orderedDescending: true
        case .orderedAscending: false
        case .orderedSame: candidate.packRevision > current.packRevision
        }
    }

    /// Compares dotted versions numerically ("7.1.2-34" < "7.1.2-35",
    /// "15" == "15.0"). Unparseable versions compare as strings.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = parseVersion(lhs), let right = parseVersion(rhs) else { return lhs.compare(rhs, options: .numeric) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func parseVersion(_ version: String) -> [Int]? {
        let parts = version.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }
}

/// What this install remembers about the runtime catalog, next to the
/// accepted envelope in Application Support.
public struct RuntimeCatalogState: Codable, Hashable, Sendable {
    public var highestSequence: Int64?
    public var lastChecked: Date?

    public init(highestSequence: Int64? = nil, lastChecked: Date? = nil) {
        self.highestSequence = highestSequence
        self.lastChecked = lastChecked
    }
}
