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

    /// Trusts the CA in this user's trust settings. macOS asks for the user's
    /// password in its own dialog; credentials never pass through DevStack.
    public func trustForCurrentUser() throws {
        try ensureCertificates(for: ["phpmyadmin.localhost", "adminer.localhost", "mailpit.localhost"])
        if isTrusted() { return }
        try addTrustedCertificate(administrator: false)
        guard isTrusted() else {
            throw CertificateManagerError.trustFailed("macOS did not authorize this CA for HTTPS. Approve the macOS dialog and retry.")
        }
    }

    /// Trusts the CA in the administrator trust settings, which every app on
    /// this Mac follows. macOS asks for an administrator's password in its own
    /// dialog; credentials never pass through DevStack.
    public func trustForSystem() throws {
        try ensureCertificates(for: ["phpmyadmin.localhost", "adminer.localhost", "mailpit.localhost"])
        if isTrusted() { return }
        try addTrustedCertificate(administrator: true)
        guard isTrusted() else {
            throw CertificateManagerError.trustFailed("The CA is still not trusted. Approve the macOS dialog and retry, or trust it for this user only.")
        }
    }

    /// Runs `security add-trusted-cert` as the user, from DevStack itself.
    /// Since macOS 11 a trust change needs the authorization dialog even for
    /// root, and only a process in the user's session can show it: run as root
    /// through an osascript administrator prompt, the change is refused ("no
    /// user interaction was possible").
    private func addTrustedCertificate(administrator: Bool) throws {
        let loginKeychain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")
        let arguments = Self.trustArguments(caCertificatePath: caCertificate.path, keychainPath: loginKeychain.path, administrator: administrator)
        do {
            _ = try ProcessRunner().runChecked(executable: URL(fileURLWithPath: "/usr/bin/security"), arguments: arguments, timeout: 300)
        } catch CommandExecutionError.nonZeroExit(_, let result) {
            let output = (result.standardError + result.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            if output.localizedCaseInsensitiveContains("cancel") {
                throw CertificateManagerError.trustFailed("The macOS dialog was cancelled. Try again, or skip this step.")
            }
            throw CertificateManagerError.trustFailed("macOS did not change the trust settings: \(output)")
        } catch CommandExecutionError.timedOut {
            throw CertificateManagerError.trustFailed("The macOS dialog was not answered in time. Try again.")
        }
    }

    /// The `security` arguments that trust the CA for HTTPS: in this user's
    /// trust settings, or with `-d` in the administrator ones. The certificate
    /// goes into the login keychain, which the user can write; the system
    /// keychain would need root, and root cannot show the dialog.
    public static func trustArguments(caCertificatePath: String, keychainPath: String, administrator: Bool) -> [String] {
        ["add-trusted-cert"] + (administrator ? ["-d"] : []) + ["-r", "trustRoot", "-p", "ssl", "-k", keychainPath, caCertificatePath]
    }
}
