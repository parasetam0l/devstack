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

    /// Adds the CA to the system trust store so every user and browser on this
    /// Mac accepts DevStack certificates. macOS shows one administrator prompt;
    /// credentials never pass through DevStack.
    public func trustForSystem() throws {
        try ensureCertificates(for: ["phpmyadmin.localhost", "adminer.localhost", "mailpit.localhost"])
        if isTrusted() { return }
        // Running `security` directly as the user only produces a write
        // permissions error: macOS needs root for the system trust store and
        // does not authorize the process on its own. `do shell script ... with
        // administrator privileges` is the supported way to show the standard
        // administrator password prompt.
        let script = Self.appleScriptAdminScript(for: Self.systemTrustCommand(caCertificatePath: caCertificate.path))
        do {
            _ = try ProcessRunner().runChecked(
                executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", script],
                timeout: 300
            )
        } catch {
            let text = error.localizedDescription
            if text.contains("-128") {
                throw CertificateManagerError.certificateGenerationFailed("The administrator prompt was cancelled. Try again, trust the CA for this user only, or skip.")
            }
            throw CertificateManagerError.certificateGenerationFailed("The administrator prompt was not completed: \(text)")
        }
        guard isTrusted() else {
            throw CertificateManagerError.certificateGenerationFailed("The CA was not added to the system trust store. Approve the administrator prompt and retry, or trust it for this user only.")
        }
    }

    /// Adds the CA to the system trust store through an administrator prompt.
    /// Exposed so the quoting of paths with spaces stays covered by checks.
    public static func systemTrustCommand(caCertificatePath: String) -> String {
        [
            "/usr/bin/security",
            "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl",
            "-k", "/Library/Keychains/System.keychain",
            singleQuoted(caCertificatePath)
        ].joined(separator: " ")
    }

    public static func appleScriptAdminScript(for command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
