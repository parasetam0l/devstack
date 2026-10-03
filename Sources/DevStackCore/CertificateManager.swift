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
    private var environment: [String: String] {
        RuntimeEnvironment.openssl(at: openssl.deletingLastPathComponent().deletingLastPathComponent())
    }

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
            environment: environment, timeout: 120
        )
        try setPermissions(0o600, on: caPrivateKey)
        try setPermissions(0o644, on: caCertificate)
    }

    public func ensureLeafCertificate(for rawHostname: String, renewBefore days: Int = 30, force: Bool = false) throws {
        let hostname: String
        do { hostname = try HostnameValidator.validate(rawHostname) }
        catch { throw CertificateManagerError.invalidHostname(rawHostname) }
        try ensureCA()
        let certificate = paths.certificate(for: hostname)
        let privateKey = paths.privateKey(for: hostname)
        // A leaf from an earlier CA (for example after the CA files were
        // removed and regenerated) is still in date but no longer trusted.
        if !force, FileManager.default.fileExists(atPath: certificate.path),
           FileManager.default.fileExists(atPath: privateKey.path),
           certificateIsValid(certificate, forAtLeastDays: days),
           isIssuedByCurrentCA(certificate) {
            return
        }

        let work = paths.certificates.appendingPathComponent(".issue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let request = work.appendingPathComponent("request.csr")
        let generatedKey = work.appendingPathComponent("key.pem")
        let generatedCertificate = work.appendingPathComponent("certificate.pem")
        let extensionFile = work.appendingPathComponent("extensions.cnf")
        // The default site also answers on the loopback IP literals.
        let subjectAltNames = hostname == "localhost" ? "DNS:localhost, IP:127.0.0.1, IP:::1" : "DNS:\(hostname)"
        try AtomicFileWriter.write("""
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=\(subjectAltNames)
        """, to: extensionFile, permissions: 0o600)

        _ = try runner.runChecked(
            executable: openssl,
            arguments: ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-subj", "/CN=\(hostname)", "-keyout", generatedKey.path, "-out", request.path],
            environment: environment, timeout: 120
        )
        _ = try runner.runChecked(
            executable: openssl,
            arguments: [
                "x509", "-req", "-sha256", "-days", "397", "-in", request.path,
                "-CA", caCertificate.path, "-CAkey", caPrivateKey.path, "-CAcreateserial",
                "-extfile", extensionFile.path, "-out", generatedCertificate.path
            ],
            environment: environment, timeout: 120
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

    public func refreshTrustBundle() throws {
        try ensureCA()
        let roots = try runner.runChecked(executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain"])
        let ca = try String(contentsOf: caCertificate, encoding: .utf8)
        try AtomicFileWriter.write(roots.standardOutput + "\n" + ca,
            to: paths.certificates.appendingPathComponent("trusted-roots.pem"), permissions: 0o644)
    }

    public func caCertificateDER() throws -> Data {
        try ensureCA()
        let output = paths.certificates.appendingPathComponent(".DevStack-Local-CA-\(UUID().uuidString).der")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try runner.runChecked(executable: openssl, arguments: ["x509", "-in", caCertificate.path, "-outform", "DER", "-out", output.path], environment: environment)
        return try Data(contentsOf: output)
    }

    public func isIssuedByCurrentCA(_ certificate: URL) -> Bool {
        guard let result = try? runner.run(executable: openssl, arguments: ["verify", "-CAfile", caCertificate.path, certificate.path], environment: environment) else { return false }
        return result.exitCode == 0
    }

    public func certificateIsValid(_ certificate: URL, forAtLeastDays days: Int) -> Bool {
        guard days >= 0 else { return false }
        let seconds = days * 86_400
        guard let result = try? runner.run(executable: openssl, arguments: ["x509", "-checkend", String(seconds), "-noout", "-in", certificate.path], environment: environment) else { return false }
        return result.exitCode == 0
    }

    private func setPermissions(_ permissions: mode_t, on url: URL) throws {
        guard chmod(url.path, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public struct CertificateSummary: Identifiable, Hashable, Sendable {
    public var id: String { hostname }
    public let hostname: String
    public let certificate: URL
    public let subject: String
    public let issuer: String
    public let serial: String
    public let fingerprint: String
    public let validFrom: Date?
    public let expiresAt: Date?
    public let error: String?
    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? true }
}

extension CertificateManager {
    public func summary(of certificate: URL, hostname: String) -> CertificateSummary {
        do {
            let output = try runner.runChecked(executable: openssl,
                arguments: ["x509", "-in", certificate.path, "-noout", "-subject", "-issuer", "-serial", "-startdate", "-enddate", "-fingerprint", "-sha256"], environment: environment).standardOutput
            var fields: [String: String] = [:]
            for line in output.split(separator: "\n") {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1].trimmingCharacters(in: .whitespaces) }
            }
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "MMM d HH:mm:ss yyyy z"
            return CertificateSummary(hostname: hostname, certificate: certificate, subject: fields["subject"] ?? "", issuer: fields["issuer"] ?? "", serial: fields["serial"] ?? "", fingerprint: fields["sha256 Fingerprint"] ?? "", validFrom: fields["notBefore"].flatMap(format.date), expiresAt: fields["notAfter"].flatMap(format.date), error: nil)
        } catch {
            return CertificateSummary(hostname: hostname, certificate: certificate, subject: "", issuer: "", serial: "", fingerprint: "", validFrom: nil, expiresAt: nil, error: error.localizedDescription)
        }
    }
    public func leafSummaries() throws -> [CertificateSummary] {
        let directory = paths.certificates.appendingPathComponent("sites")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pem" && !$0.lastPathComponent.hasSuffix("-key.pem") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { summary(of: $0, hostname: $0.deletingPathExtension().lastPathComponent) }
    }
    public func deleteLeafCertificate(for rawHostname: String) throws {
        let hostname = try HostnameValidator.validate(rawHostname)
        for file in [paths.certificate(for: hostname), paths.privateKey(for: hostname)] {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
