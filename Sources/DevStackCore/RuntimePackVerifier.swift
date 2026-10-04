import CryptoKit
import Foundation

public enum RuntimePackVerificationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case unsupportedArchitecture(String)
    case incompatibleMacOS(required: String, current: String)
    case unsafePath(String)
    case missingFile(String)
    case unexpectedSymbolicLink(String)
    case checksumMismatch(String)
    case unknownSigningKey(String)
    case unsupportedSignatureAlgorithm(String)
    case missingSignature
    case invalidSignature
    case forbiddenDependency(String)
    case invalidCodeSignature(String)
    case unexpectedFile(String)
    case invalidRuntimeID(String)
    case unsafeLink(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema): "Unsupported runtime-pack schema: \(schema)."
        case .unsupportedArchitecture(let architecture): "Unsupported architecture: \(architecture)."
        case .incompatibleMacOS(let required, let current): "Runtime requires macOS \(required); this Mac runs \(current)."
        case .unsafePath(let path): "Runtime pack contains an unsafe path: \(path)."
        case .missingFile(let path): "Runtime pack is missing: \(path)."
        case .unexpectedSymbolicLink(let path): "Runtime pack contains a symbolic link: \(path)."
        case .checksumMismatch(let path): "Runtime pack checksum does not match: \(path)."
        case .unknownSigningKey(let key): "Runtime pack uses an unknown signing key: \(key)."
        case .unsupportedSignatureAlgorithm(let algorithm): "Unsupported signature algorithm: \(algorithm)."
        case .missingSignature: "Runtime pack has no signature."
        case .invalidSignature: "Runtime-pack manifest signature is invalid."
        case .forbiddenDependency(let path): "Runtime contains a forbidden dependency path: \(path)."
        case .invalidCodeSignature(let path): "Executable code signature is invalid: \(path)."
        case .unexpectedFile(let path): "Runtime pack contains a file its signed manifest does not list: \(path)."
        case .invalidRuntimeID(let id): "Runtime pack has an invalid runtime identifier: \(id)."
        case .unsafeLink(let path): "Runtime pack link does not resolve to one of its files: \(path)."
        }
    }
}

public struct RuntimePackVerifier: Sendable {
    public let trustedPublicKeys: [String: Data]
    public let requireSignature: Bool
    /// When set, every executable must be signed with a Developer ID of this
    /// team, as the running app is. Nil (an unsigned development build)
    /// accepts any valid signature, ad-hoc included.
    public let requiredTeamID: String?
    private let runner: ProcessRunner

    public init(trustedPublicKeys: [String: Data], requireSignature: Bool = true, requiredTeamID: String? = nil, runner: ProcessRunner = .init()) {
        self.trustedPublicKeys = trustedPublicKeys
        self.requireSignature = requireSignature
        self.requiredTeamID = requiredTeamID
        self.runner = runner
    }

    public func verify(
        manifest: RuntimePackManifest,
        root: URL,
        verifyCodeSignatures: Bool = true,
        currentMacOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws {
        guard manifest.schemaVersion == 1 else {
            throw RuntimePackVerificationError.unsupportedSchema(manifest.schemaVersion)
        }
        guard manifest.compatibility.architectures.contains("arm64"), manifest.runtime.architecture == "arm64" else {
            throw RuntimePackVerificationError.unsupportedArchitecture(manifest.runtime.architecture)
        }
        let current = "\(currentMacOS.majorVersion).\(currentMacOS.minorVersion).\(currentMacOS.patchVersion)"
        guard compareVersions(current, manifest.compatibility.minimumMacOS) != .orderedAscending else {
            throw RuntimePackVerificationError.incompatibleMacOS(required: manifest.compatibility.minimumMacOS, current: current)
        }

        if requireSignature { try verifyManifestSignature(manifest) }
        // The identifier becomes a directory name under Application Support.
        guard manifest.runtime.id.range(of: "^[a-z0-9][a-z0-9.+-]{0,63}$", options: .regularExpression) != nil,
              !manifest.runtime.id.contains("..") else {
            throw RuntimePackVerificationError.invalidRuntimeID(manifest.runtime.id)
        }
        try validateDependencyPaths(manifest.runtime.dependencyPaths)

        for file in manifest.payload {
            let relativePath = try validateRelativePath(file.path)
            let url = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RuntimePackVerificationError.missingFile(file.path)
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else {
                throw RuntimePackVerificationError.unexpectedSymbolicLink(file.path)
            }
            guard values.isRegularFile == true else {
                throw RuntimePackVerificationError.missingFile(file.path)
            }
            guard try sha256(url) == file.sha256.lowercased() else {
                throw RuntimePackVerificationError.checksumMismatch(file.path)
            }
            if file.executable {
                try verifyMachO(url, relativePath: file.path, verifyCodeSignature: verifyCodeSignatures)
            }
        }

        _ = try validateRelativePath(manifest.sbomPath)
        guard manifest.payload.contains(where: { $0.path == manifest.sbomPath }) else {
            throw RuntimePackVerificationError.missingFile(manifest.sbomPath)
        }
        try verifyLinks(manifest)
        try verifyInventory(manifest: manifest, root: root)
    }

    /// Every link must sit at an unused relative path and resolve, following
    /// other links of the pack, to one of its verified files. Links to
    /// folders, absolute paths and anything outside the pack are rejected.
    public func verifyLinks(_ manifest: RuntimePackManifest) throws {
        let files = Set(manifest.payload.map(\.path))
        var targets: [String: String] = [:]
        for link in manifest.links {
            let path = try validateRelativePath(link.path)
            guard !files.contains(path), targets[path] == nil,
                  !link.target.isEmpty, !link.target.hasPrefix("/"), !link.target.contains("\0") else {
                throw RuntimePackVerificationError.unsafeLink(link.path)
            }
            targets[path] = link.target
        }
        for path in files.union(targets.keys) {
            // A link may not stand in for a folder that holds other entries.
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard targets[parent] == nil else { throw RuntimePackVerificationError.unsafeLink(parent) }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for path in targets.keys {
            var current = path
            for _ in 0..<8 {
                guard let target = targets[current] else { break }
                guard let next = Self.resolve(target, from: (current as NSString).deletingLastPathComponent) else {
                    throw RuntimePackVerificationError.unsafeLink(path)
                }
                current = next
            }
            guard files.contains(current) else { throw RuntimePackVerificationError.unsafeLink(path) }
        }
    }

    /// Joins a relative link target to its folder; nil when it climbs out of the pack.
    private static func resolve(_ target: String, from folder: String) -> String? {
        var parts = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The signature covers only the files the manifest lists, so the pack may
    /// contain nothing else: an unlisted library or extension would be
    /// installed without any integrity check.
    private func verifyInventory(manifest: RuntimePackManifest, root: URL) throws {
        let listed = Set(manifest.payload.map(\.path))
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw RuntimePackVerificationError.missingFile(root.path)
        }
        while let relative = enumerator.nextObject() as? String {
            switch enumerator.fileAttributes?[.type] as? FileAttributeType {
            case .typeDirectory?:
                continue
            case .typeRegular?:
                guard relative == "manifest.json" || listed.contains(relative) else {
                    throw RuntimePackVerificationError.unexpectedFile(relative)
                }
            case .typeSymbolicLink?:
                throw RuntimePackVerificationError.unexpectedSymbolicLink(relative)
            default:
                throw RuntimePackVerificationError.unexpectedFile(relative)
            }
        }
    }

    public func canonicalManifestData(_ manifest: RuntimePackManifest) throws -> Data {
        var unsigned = manifest
        unsigned.signature = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(unsigned)
    }

    public func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func validateRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.contains("\0")
        else { throw RuntimePackVerificationError.unsafePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimePackVerificationError.unsafePath(path)
        }
        return path
    }

    private func verifyManifestSignature(_ manifest: RuntimePackManifest) throws {
        guard let signature = manifest.signature else { throw RuntimePackVerificationError.missingSignature }
        guard signature.algorithm.lowercased() == "ed25519" else {
            throw RuntimePackVerificationError.unsupportedSignatureAlgorithm(signature.algorithm)
        }
        guard let keyData = trustedPublicKeys[signature.keyID] else {
            throw RuntimePackVerificationError.unknownSigningKey(signature.keyID)
        }
        guard let signatureData = Data(base64Encoded: signature.value) else {
            throw RuntimePackVerificationError.invalidSignature
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        guard key.isValidSignature(signatureData, for: try canonicalManifestData(manifest)) else {
            throw RuntimePackVerificationError.invalidSignature
        }
    }

    private func validateDependencyPaths(_ paths: [String]) throws {
        let forbidden = ["/opt/homebrew", "/usr/local/Cellar", "/opt/local", "/Users/"]
        for path in paths where forbidden.contains(where: path.hasPrefix) {
            throw RuntimePackVerificationError.forbiddenDependency(path)
        }
    }

    func verifyMachO(_ url: URL, relativePath: String, verifyCodeSignature: Bool = true) throws {
        let architectureResult = try runner.runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/lipo"),
            arguments: ["-archs", url.path],
            timeout: 30
        )
        let architectures = architectureResult.standardOutput.split(whereSeparator: \.isWhitespace).map(String.init)
        guard architectures == ["arm64"] else {
            throw RuntimePackVerificationError.unsupportedArchitecture(architectures.joined(separator: ","))
        }

        let dependencyResult = try runner.runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/otool"),
            arguments: ["-L", url.path],
            timeout: 30
        )
        for line in dependencyResult.standardOutput.split(whereSeparator: \.isNewline).dropFirst() {
            guard let dependency = line.split(whereSeparator: \.isWhitespace).first.map(String.init) else { continue }
            try validateMachODependency(dependency)
        }
        let loadCommands = try runner.runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/otool"),
            arguments: ["-l", url.path],
            timeout: 30
        ).standardOutput
        let lines = loadCommands.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for index in lines.indices where lines[index] == "cmd LC_RPATH" {
            let pathIndex = lines.index(index, offsetBy: 2, limitedBy: lines.endIndex)
            if let pathIndex, pathIndex < lines.endIndex, lines[pathIndex].hasPrefix("path ") {
                let path = lines[pathIndex].dropFirst(5).split(separator: " ").first.map(String.init) ?? ""
                guard path == "@loader_path" || path.hasPrefix("@loader_path/") ||
                    path == "@executable_path" || path.hasPrefix("@executable_path/") else {
                    throw RuntimePackVerificationError.forbiddenDependency(path)
                }
            }
        }

        if verifyCodeSignature {
            var arguments = ["--verify", "--strict", "--verbose=2"]
            if let requiredTeamID {
                // Interpolated into a code requirement, so only a well-formed
                // Team ID is accepted.
                guard requiredTeamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
                    throw RuntimePackVerificationError.invalidCodeSignature(relativePath)
                }
                arguments.append("-R=anchor apple generic and certificate leaf[subject.OU] = \"\(requiredTeamID)\"")
            }
            do {
                _ = try runner.runChecked(
                    executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: arguments + [url.path],
                    timeout: 30
                )
            } catch {
                throw RuntimePackVerificationError.invalidCodeSignature(relativePath)
            }
        }
    }

    private func validateMachODependency(_ path: String) throws {
        if path.hasPrefix("@rpath/") || path.hasPrefix("@loader_path/") || path.hasPrefix("@executable_path/") ||
            path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/") {
            return
        }
        throw RuntimePackVerificationError.forbiddenDependency(path)
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

public struct RuntimePackImporter: Sendable {
    public let verifier: RuntimePackVerifier
    private let runner: ProcessRunner

    public init(verifier: RuntimePackVerifier, runner: ProcessRunner = .init()) {
        self.verifier = verifier
        self.runner = runner
    }

    public func importArchive(_ archive: URL, into runtimeDirectory: URL) throws -> RuntimeManifest {
        let listing = try runner.runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", archive.path],
            timeout: 30
        )
        for entry in listing.standardOutput.split(whereSeparator: \.isNewline) {
            _ = try verifier.validateRelativePath(String(entry).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("devstack-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try runner.runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, temporary.path],
            timeout: 120
        )

        let manifestURL = temporary.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(RuntimePackManifest.self, from: Data(contentsOf: manifestURL))
        try verifier.verify(manifest: manifest, root: temporary)

        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let destination = runtimeDirectory.appendingPathComponent(manifest.runtime.id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let staging = runtimeDirectory.appendingPathComponent(".\(manifest.runtime.id).\(UUID().uuidString).staging", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: temporary, to: staging)
            // Links come only from the verified manifest, never from the archive.
            for link in manifest.links {
                let url = staging.appendingPathComponent(link.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: link.target)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return manifest.runtime
    }
}
