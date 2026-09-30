import Foundation
import Security

extension CertificateManager {
    public func isTrusted(for hostname: String = "phpmyadmin.localhost") -> Bool {
        guard let pem = try? String(contentsOf: paths.certificate(for: hostname), encoding: .utf8) else { return false }
        let encoded = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: encoded), let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, hostname as CFString), &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    // The user keychain is sufficient for browser HTTPS on this account. macOS
    // owns the authorization dialog; credentials never pass through DevStack.
    public func trustForCurrentUser() throws {
        try ensureCertificates(for: ["phpmyadmin.localhost", "adminer.localhost", "mailpit.localhost"])
        if isTrusted() { return }
        let keychain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")
        _ = try ProcessRunner().runChecked(executable: URL(fileURLWithPath: "/usr/bin/security"), arguments: [
            "add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", keychain.path, caCertificate.path
        ], timeout: 120)
        guard isTrusted() else {
            throw CertificateManagerError.certificateGenerationFailed("macOS did not authorize this CA for HTTPS. Approve the native certificate trust dialog and retry.")
        }
    }
}
