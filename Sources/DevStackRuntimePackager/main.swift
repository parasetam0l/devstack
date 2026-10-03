import CryptoKit
import Darwin
import DevStackCore
import Foundation

private enum PackagerError: LocalizedError {
    case usage
    case invalidPrivateKey
    case unsafePayload(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: DevStackRuntimePackager PAYLOAD RUNTIME_MANIFEST SBOM LICENSES KEY_ID RAW_ED25519_KEY OUTPUT.devstack-runtime"
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

        try copyDirectoryContents(payload, to: staging)
        try FileManager.default.copyItem(at: sbom, to: staging.appendingPathComponent("sbom.cdx.json"))
        let licenseDestination = staging.appendingPathComponent("licenses", isDirectory: true)
        try FileManager.default.createDirectory(at: licenseDestination, withIntermediateDirectories: true)
        try copyDirectoryContents(licenses, to: licenseDestination)

        let unsignedVerifier = RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false)
        var files: [RuntimePackFile] = []
        guard let enumerator = FileManager.default.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { throw PackagerError.unsafePayload(staging.path) }
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw PackagerError.unsafePayload(file.path) }
            guard values.isRegularFile == true else { continue }
            // Every file in the archive is listed, hidden ones included: the
            // importer rejects anything the signed manifest does not cover.
            let relative = String(file.path.dropFirst(staging.path.count + 1))
            files.append(RuntimePackFile(path: relative, sha256: try unsignedVerifier.sha256(file), executable: try isMachO(file)))
        }
        files.sort { $0.path < $1.path }

        var manifest = RuntimePackManifest(
            runtime: runtime,
            payload: files,
            signingIdentity: keyID,
            sbomPath: "sbom.cdx.json"
        )
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

    private static func copyDirectoryContents(_ source: URL, to destination: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw PackagerError.unsafePayload(item.path) }
            try FileManager.default.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
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
