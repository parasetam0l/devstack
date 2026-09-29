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
        }
    }
}

public struct RuntimePackVerifier: Sendable {
    public let trustedPublicKeys: [String: Data]
    public let requireSignature: Bool
    private let runner: ProcessRunner

    public init(trustedPublicKeys: [String: Data], requireSignature: Bool = true, runner: ProcessRunner = .init()) {
        self.trustedPublicKeys = trustedPublicKeys
        self.requireSignature = requireSignature
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
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(manifest.sbomPath).path) else {
            throw RuntimePackVerificationError.missingFile(manifest.sbomPath)
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
            do {
                _ = try runner.runChecked(
                    executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--verify", "--strict", "--verbose=2", url.path],
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
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return manifest.runtime
    }
}
