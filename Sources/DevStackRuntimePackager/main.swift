import CryptoKit
import Darwin
import DevStackCore
import Foundation

private enum PackagerError: LocalizedError {
    case usage
    case invalidPrivateKey
    case unsafePayload(String)
    case invalidTrustedKeys

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            Usage: DevStackRuntimePackager PAYLOAD RUNTIME_MANIFEST SBOM LICENSES KEY_ID RAW_ED25519_KEY OUTPUT.devstack-runtime
                   DevStackRuntimePackager verify PACK.devstack-runtime TRUSTED_KEYS.json [TEAM_ID]
                   DevStackRuntimePackager install PACK.devstack-runtime TRUSTED_KEYS.json RUNTIMES_DIRECTORY [TEAM_ID]
                   DevStackRuntimePackager generate-key KEY_ID PRIVATE_KEY_OUTPUT PUBLIC_KEYS_OUTPUT.json
            """
        case .invalidTrustedKeys:
            "The trusted keys file must map key IDs to 32-byte base64 Ed25519 public keys under \"keys\"."
        case .invalidPrivateKey:
            "The signing key must contain exactly 32 raw Ed25519 private-key bytes."
        case .unsafePayload(let path):
            "The payload contains an unsupported symbolic link or non-file entry: \(path)"
        }
    }
}

@main
enum DevStackRuntimePackager {
    static func main() throws {
        if (4...5).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "verify" {
            try verify(
                pack: URL(fileURLWithPath: CommandLine.arguments[2]),
                trustedKeys: URL(fileURLWithPath: CommandLine.arguments[3]),
                teamID: CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : nil
            )
            return
        }
        if (5...6).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "install" {
            // Installs a pack the way the app does, for build hosts that use
            // published packs as inputs to other runtimes.
            try verify(
                pack: URL(fileURLWithPath: CommandLine.arguments[2]),
                trustedKeys: URL(fileURLWithPath: CommandLine.arguments[3]),
                teamID: CommandLine.arguments.count == 6 ? CommandLine.arguments[5] : nil,
                into: URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
            )
            return
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "generate-key" {
            try generateKey(
                keyID: CommandLine.arguments[2],
                privateKeyURL: URL(fileURLWithPath: CommandLine.arguments[3]),
                publicKeyURL: URL(fileURLWithPath: CommandLine.arguments[4])
            )
            return
        }
        guard CommandLine.arguments.count == 8 else { throw PackagerError.usage }
        let payload = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let runtimeManifestURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let sbom = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
        let licenses = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true).standardizedFileURL
        let keyID = CommandLine.arguments[5]
        let keyURL = URL(fileURLWithPath: CommandLine.arguments[6]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[7]).standardizedFileURL

        let keyData = try Data(contentsOf: keyURL)
        guard keyData.count == 32 else { throw PackagerError.invalidPrivateKey }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let runtime = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: runtimeManifestURL))
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("devstack-pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Links travel in the signed manifest; the importer recreates them.
        let links = try copyPayload(payload, to: staging)
        try FileManager.default.copyItem(at: sbom, to: staging.appendingPathComponent("sbom.cdx.json"))
        let licenseDestination = staging.appendingPathComponent("licenses", isDirectory: true)
        try FileManager.default.createDirectory(at: licenseDestination, withIntermediateDirectories: true)
        guard try copyPayload(licenses, to: licenseDestination).isEmpty else { throw PackagerError.unsafePayload(licenses.path) }

        let unsignedVerifier = RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false)
        var files: [RuntimePackFile] = []
        // Relative paths straight from the enumerator: deriving them from
        // absolute URLs breaks when the temporary folder is reported as
        // /var in one place and /private/var in another.
        guard let enumerator = FileManager.default.enumerator(atPath: staging.path) else {
            throw PackagerError.unsafePayload(staging.path)
        }
        while let relative = enumerator.nextObject() as? String {
            switch enumerator.fileAttributes?[.type] as? FileAttributeType {
            case .typeRegular?:
                // Every file in the archive is listed, hidden ones included:
                // the importer rejects anything the signed manifest does not cover.
                let file = staging.appendingPathComponent(relative)
                files.append(RuntimePackFile(path: relative, sha256: try unsignedVerifier.sha256(file), executable: try isMachO(file)))
            case .typeDirectory?:
                continue
            default:
                throw PackagerError.unsafePayload(relative)
            }
        }
        files.sort { $0.path < $1.path }

        var manifest = RuntimePackManifest(
            runtime: runtime,
            payload: files,
            links: links,
            compatibility: RuntimePackCompatibility(minimumMacOS: runtime.minimumMacOS),
            signingIdentity: keyID,
            sbomPath: "sbom.cdx.json"
        )
        // The same checks the app runs on import, minus Apple code signatures,
        // which the release workflow verifies separately.
        try RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false).verifyLinks(manifest)
        let signature = try privateKey.signature(for: unsignedVerifier.canonicalManifestData(manifest))
        manifest.signature = RuntimePackSignature(keyID: keyID, value: signature.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFileWriter.write(try encoder.encode(manifest), to: staging.appendingPathComponent("manifest.json"), permissions: 0o644)

        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        _ = try ProcessRunner().runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--sequesterRsrc", staging.path, output.path],
            timeout: 600
        )
        print(output.path)
    }

    private static func generateKey(keyID: String, privateKeyURL: URL, publicKeyURL: URL) throws {
        let key = Curve25519.Signing.PrivateKey()
        try AtomicFileWriter.write(key.rawRepresentation, to: privateKeyURL, permissions: 0o600)
        let document = ["keys": [keyID: key.publicKey.rawRepresentation.base64EncodedString()]]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(try encoder.encode(document), to: publicKeyURL, permissions: 0o644)
        print(publicKeyURL.path)
    }

    /// Copies regular files and folders; returns the links instead of copying
    /// them. Anything else (sockets, devices) is refused.
    private static func copyPayload(_ source: URL, to destination: URL) throws -> [RuntimePackLink] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: source.path) else { throw PackagerError.unsafePayload(source.path) }
        var links: [RuntimePackLink] = []
        while let relative = enumerator.nextObject() as? String {
            let item = source.appendingPathComponent(relative)
            let target = destination.appendingPathComponent(relative)
            switch enumerator.fileAttributes?[.type] as? FileAttributeType {
            case .typeDirectory?:
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            case .typeRegular?:
                try fileManager.copyItem(at: item, to: target)
            case .typeSymbolicLink?:
                links.append(RuntimePackLink(path: relative, target: try fileManager.destinationOfSymbolicLink(atPath: item.path)))
            default:
                throw PackagerError.unsafePayload(item.path)
            }
        }
        return links.sorted { $0.path < $1.path }
    }

    private static func verify(pack: URL, trustedKeys: URL, teamID: String?, into installation: URL? = nil) throws {
        struct TrustedKeys: Decodable { var keys: [String: String] }
        let document = try JSONDecoder().decode(TrustedKeys.self, from: Data(contentsOf: trustedKeys))
        let keys = try document.keys.mapValues { encoded -> Data in
            guard let data = Data(base64Encoded: encoded), data.count == 32 else { throw PackagerError.invalidTrustedKeys }
            return data
        }
        let destination = installation ?? FileManager.default.temporaryDirectory.appendingPathComponent("devstack-verify-\(UUID().uuidString)", isDirectory: true)
        defer { if installation == nil { try? FileManager.default.removeItem(at: destination) } }
        let verifier = RuntimePackVerifier(trustedPublicKeys: keys, requiredTeamID: teamID)
        let runtime = try RuntimePackImporter(verifier: verifier).importArchive(pack, into: destination)
        print("\(installation == nil ? "Verified" : "Installed") \(runtime.id) \(runtime.version) for macOS \(runtime.minimumMacOS)+\(teamID.map { ", Team \($0)" } ?? "")")
    }

    private static func isMachO(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4) ?? Data()
        guard data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64, FAT_MAGIC, FAT_CIGAM].contains(magic)
    }
}
