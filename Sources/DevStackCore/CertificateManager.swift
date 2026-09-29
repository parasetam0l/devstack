import Darwin
import Foundation

public enum CertificateManagerError: LocalizedError, Sendable {
    case invalidHostname(String)
    case certificateGenerationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHostname(let hostname): "Cannot issue a certificate for invalid hostname: \(hostname)"
        case .certificateGenerationFailed(let message): "Certificate generation failed: \(message)"
        }
    }
}

public struct CertificateManager: Sendable {
    public let paths: DevStackPaths
    public let openssl: URL
    private let runner: ProcessRunner

    public init(paths: DevStackPaths, openssl: URL, runner: ProcessRunner = ProcessRunner()) {
        self.paths = paths
        self.openssl = openssl
        self.runner = runner
    }

    public var caCertificate: URL { paths.certificates.appendingPathComponent("DevStack-Local-CA.pem") }
    public var caPrivateKey: URL { paths.certificates.appendingPathComponent("DevStack-Local-CA-key.pem") }

    public func ensureCA() throws {
        try paths.createRequiredDirectories()
        guard !FileManager.default.fileExists(atPath: caCertificate.path) || !FileManager.default.fileExists(atPath: caPrivateKey.path) else { return }
        _ = try runner.runChecked(
            executable: openssl,
            arguments: [
                "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "3650",
                "-subj", "/CN=DevStack Local Development CA/O=DevStack",
                "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout", caPrivateKey.path, "-out", caCertificate.path
            ],
            timeout: 120
        )
        try setPermissions(0o600, on: caPrivateKey)
        try setPermissions(0o644, on: caCertificate)
    }

    public func ensureLeafCertificate(for rawHostname: String, renewBefore days: Int = 30) throws {
        let hostname: String
        do { hostname = try HostnameValidator.validate(rawHostname) }
        catch { throw CertificateManagerError.invalidHostname(rawHostname) }
        try ensureCA()
        let certificate = paths.certificate(for: hostname)
        let privateKey = paths.privateKey(for: hostname)
        if FileManager.default.fileExists(atPath: certificate.path),
           FileManager.default.fileExists(atPath: privateKey.path),
           certificateIsValid(certificate, forAtLeastDays: days) {
            return
        }

        let work = paths.certificates.appendingPathComponent(".issue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let request = work.appendingPathComponent("request.csr")
        let generatedKey = work.appendingPathComponent("key.pem")
        let generatedCertificate = work.appendingPathComponent("certificate.pem")
        let extensionFile = work.appendingPathComponent("extensions.cnf")
        try AtomicFileWriter.write("""
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=DNS:\(hostname)
        """, to: extensionFile, permissions: 0o600)

        _ = try runner.runChecked(
            executable: openssl,
            arguments: ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=\(hostname)", "-keyout", generatedKey.path, "-out", request.path],
            timeout: 120
        )
        _ = try runner.runChecked(
            executable: openssl,
            arguments: [
                "x509", "-req", "-sha256", "-days", "397", "-in", request.path,
                "-CA", caCertificate.path, "-CAkey", caPrivateKey.path, "-CAcreateserial",
                "-extfile", extensionFile.path, "-out", generatedCertificate.path
            ],
            timeout: 120
        )
        try AtomicFileWriter.write(try Data(contentsOf: generatedKey), to: privateKey, permissions: 0o600)
        try AtomicFileWriter.write(try Data(contentsOf: generatedCertificate), to: certificate, permissions: 0o644)
    }

    public func ensureCertificates(for hostnames: some Sequence<String>) throws {
        try ensureCA()
        for hostname in Set(hostnames).sorted() {
            try ensureLeafCertificate(for: hostname)
        }
    }

    public func caCertificateDER() throws -> Data {
        try ensureCA()
        let output = paths.certificates.appendingPathComponent(".DevStack-Local-CA-\(UUID().uuidString).der")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try runner.runChecked(executable: openssl, arguments: ["x509", "-in", caCertificate.path, "-outform", "DER", "-out", output.path])
        return try Data(contentsOf: output)
    }

    public func certificateIsValid(_ certificate: URL, forAtLeastDays days: Int) -> Bool {
        guard days >= 0 else { return false }
        let seconds = days * 86_400
        guard let result = try? runner.run(executable: openssl, arguments: ["x509", "-checkend", String(seconds), "-noout", "-in", certificate.path]) else { return false }
        return result.exitCode == 0
    }

    private func setPermissions(_ permissions: mode_t, on url: URL) throws {
        guard chmod(url.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
