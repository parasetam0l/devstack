import DevStackCore
import CryptoKit
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(description: message) }
}

@main
enum DevStackCoreChecks {
    static func main() async throws {
        try expect(
            HostnameValidator.validate(" Example.TEST. ") == "example.test",
            "Hostname normalization failed"
        )
        try expect(
            HostnameValidator.shadowsPublicDomain("example.com"),
            "Public domain warning was not detected"
        )
        try expect(
            !HostnameValidator.shadowsPublicDomain("example.test"),
            "Reserved .test domain was incorrectly flagged"
        )

        let hosts = """
        127.0.0.1 localhost
        # BEGIN DEVSTACK MANAGED — DO NOT EDIT
        127.0.0.1 old.test
        ::1 old.test
        # END DEVSTACK MANAGED
        """
        let replacedHosts = try HostsFileEditor.replacingManagedSection(
            in: hosts,
            mappings: [HostMapping(hostname: "example.test")]
        )
        try expect(!replacedHosts.contains("old.test"), "Old managed host entry was preserved")
        try expect(replacedHosts.contains("127.0.0.1\texample.test"), "IPv4 host entry was not generated")
        try expect(replacedHosts.contains("::1\texample.test"), "IPv6 host entry was not generated")
        do {
            _ = try PrivilegedRequestValidator.portForwarding(.init(enabled: true, httpUpstreamPort: 8081))
            throw CheckFailure(description: "Arbitrary port forwarding was accepted")
        } catch PrivilegedRequestValidationError.invalidPortForwarding {
            // Expected.
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("devstack-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = DevStackPaths(
            applicationSupport: temporary.appendingPathComponent("support"),
            logs: temporary.appendingPathComponent("logs"),
            builtInRuntimes: temporary.appendingPathComponent("runtimes")
        )
        try paths.createRequiredDirectories()
        let site = SiteDefinition(
            name: "Example",
            hostname: "example.test",
            documentRoot: temporary.appendingPathComponent("site").path,
            logs: SiteLogPaths(
                access: temporary.appendingPathComponent("logs/example-access.log").path,
                error: temporary.appendingPathComponent("logs/example-error.log").path
            )
        )
        let renderer = ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes)
        let apache = try renderer.apacheConfiguration(sites: [site])
        try expect(apache.contains("ServerName example.test"), "Apache virtual host was not rendered")
        let php = try renderer.phpFPMConfiguration(runtimeID: "php-8.5", sites: [site], includeManagementPool: true)
        try expect(php.contains("[management]"), "PHP management pool was not rendered")
        try expect(php.contains(site.id.uuidString.replacingOccurrences(of: "-", with: "_").lowercased()), "Site PHP pool was not rendered")

        let store = AppConfigurationStore(url: paths.configurationFile)
        var configuration = AppConfiguration()
        configuration.sites = [site]
        try await store.save(configuration)
        let loaded = try await store.load()
        try expect(loaded == configuration, "Configuration round trip failed")

        let command = try ProcessRunner().runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["devstack"]
        )
        try expect(command.standardOutput == "devstack", "Command output capture failed")

        let payloadRoot = temporary.appendingPathComponent("runtime-pack", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        let payloadURL = payloadRoot.appendingPathComponent("bin/php")
        try FileManager.default.createDirectory(at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("php-runtime".utf8).write(to: payloadURL)
        try Data("{}".utf8).write(to: payloadRoot.appendingPathComponent("sbom.json"))
        let privateKey = Curve25519.Signing.PrivateKey()
        var runtimeManifest = RuntimePackManifest(
            runtime: RuntimeManifest(
                id: "php-test",
                kind: .php,
                version: "8.5.11",
                entryPoints: ["php": "bin/php"],
                license: "PHP-3.01",
                source: SourceProvenance(url: URL(string: "https://example.test/php.tar.xz")!, sha256: String(repeating: "0", count: 64)),
                supportState: .supported
            ),
            payload: [],
            signingIdentity: "DevStack Test",
            sbomPath: "sbom.json"
        )
        let unsignedVerifier = RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false)
        runtimeManifest.payload = [RuntimePackFile(path: "bin/php", sha256: try unsignedVerifier.sha256(payloadURL))]
        let signature = try privateKey.signature(for: unsignedVerifier.canonicalManifestData(runtimeManifest))
        runtimeManifest.signature = RuntimePackSignature(keyID: "test", value: signature.base64EncodedString())
        let verifier = RuntimePackVerifier(trustedPublicKeys: ["test": privateKey.publicKey.rawRepresentation])
        try verifier.verify(
            manifest: runtimeManifest,
            root: payloadRoot,
            verifyCodeSignatures: false,
            currentMacOS: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
        do {
            _ = try verifier.validateRelativePath("../escape")
            throw CheckFailure(description: "Runtime path traversal was accepted")
        } catch RuntimePackVerificationError.unsafePath {
            // Expected.
        }

        let report = DevStackDoctor().run(
            context: DiagnosticContext(paths: paths, helperInstalled: false, expectedHostnames: ["example.test"]),
            appVersion: "0.1.0"
        )
        try expect(report.results.contains(where: { $0.id == "architecture" }), "Doctor omitted architecture check")
        try expect(report.results.contains(where: { $0.id == "privileged-helper" && $0.severity == .error }), "Doctor omitted missing helper")

        let supervisor = ServiceSupervisor()
        let serviceLog = temporary.appendingPathComponent("logs/sleep.log")
        try await supervisor.start(ServiceSpecification(
            kind: .mailpit,
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            logFile: serviceLog
        ))
        let runningState = await supervisor.state(for: .mailpit)
        try expect(runningState.phase == .running, "Service did not enter running state")
        await supervisor.stop(.mailpit)
        let stoppedState = await supervisor.state(for: .mailpit)
        try expect(stoppedState.phase == .stopped, "Service did not stop")
        print("DevStackCoreChecks: all checks passed")
    }
}
