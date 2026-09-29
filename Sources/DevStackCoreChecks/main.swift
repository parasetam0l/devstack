import DevStackCore
import CryptoKit
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

private struct RuntimeLockCheck: Decodable {
    var schemaVersion: Int
    var runtimes: [RuntimeManifest]
}

private struct DependencyLockCheck: Decodable {
    var schemaVersion: Int
    var sources: [DependencySourceCheck]
}

private struct DependencySourceCheck: Decodable {
    var id: String
    var version: String
    var url: URL
    var sha256: String
    var license: String
    var targets: [String]
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(description: message) }
}

@main
enum DevStackCoreChecks {
    static func main() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lockURL = repositoryRoot.appendingPathComponent("Sources/DevStackApp/Resources/runtime-lock.json")
        let runtimeLock = try JSONDecoder().decode(RuntimeLockCheck.self, from: Data(contentsOf: lockURL))
        try expect(runtimeLock.schemaVersion == 1, "Unsupported runtime lock schema")
        try expect(Set(runtimeLock.runtimes.map(\.id)).count == runtimeLock.runtimes.count, "Runtime lock contains duplicate IDs")
        try expect(runtimeLock.runtimes.allSatisfy { $0.source.sha256.count == 64 }, "Runtime source checksum is malformed")

        let dependencyLockURL = repositoryRoot.appendingPathComponent("Dependencies/dependency-lock.json")
        let dependencyLock = try JSONDecoder().decode(DependencyLockCheck.self, from: Data(contentsOf: dependencyLockURL))
        try expect(dependencyLock.schemaVersion == 1, "Unsupported dependency lock schema")
        try expect(Set(dependencyLock.sources.map(\.id)).count == dependencyLock.sources.count, "Dependency lock contains duplicate IDs")
        try expect(dependencyLock.sources.allSatisfy { $0.sha256.count == 64 }, "Dependency source checksum is malformed")
        try expect(dependencyLock.sources.allSatisfy { $0.url.scheme == "https" }, "Dependency source is not HTTPS")
        try expect(dependencyLock.sources.allSatisfy { !$0.version.isEmpty && !$0.license.isEmpty && !$0.targets.isEmpty }, "Dependency source metadata is incomplete")

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
        let standardInput = try ProcessRunner().runChecked(
            executable: URL(fileURLWithPath: "/bin/cat"),
            standardInput: Data("database-import".utf8)
        )
        try expect(standardInput.standardOutput == "database-import", "Command standard input failed")

        let databaseManager = DatabaseManager(paths: paths, runtimeRoot: paths.builtInRuntimes)
        let backupName = databaseManager.backupFilename(
            engine: .mysql84,
            database: nil,
            date: Date(timeIntervalSince1970: 0)
        )
        try expect(backupName == "mysql-8.4-all-databases-19700101-000000.sql", "Database backup naming is not deterministic")
        try expect(
            databaseManager.archiveDataDirectoryName(engine: .mysql57, date: Date(timeIntervalSince1970: 0)) == "mysql-5.7-data-19700101-000000",
            "Database data archive naming is not deterministic"
        )
        do {
            _ = try databaseManager.archiveDataDirectory(.mysql84)
            throw CheckFailure(description: "Missing database data directory was archived")
        } catch DatabaseManagerError.dataDirectoryMissing {
            // Expected.
        }
        let liveDataDirectory = databaseManager.dataDirectoryURL(.mysql57)
        try FileManager.default.createDirectory(at: liveDataDirectory.appendingPathComponent("mysql"), withIntermediateDirectories: true)
        let archivedDataDirectory = try databaseManager.archiveDataDirectory(.mysql57, date: Date(timeIntervalSince1970: 0))
        try expect(FileManager.default.fileExists(atPath: archivedDataDirectory.appendingPathComponent("mysql").path), "Database data directory was not archived")
        try expect(!FileManager.default.fileExists(atPath: liveDataDirectory.path), "Archived database data directory was not moved")

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

        let executablePackRoot = temporary.appendingPathComponent("executable-runtime-pack", isDirectory: true)
        let executableURL = executablePackRoot.appendingPathComponent("bin/devstack-check")
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixtureSource = temporary.appendingPathComponent("devstack-check.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: fixtureSource)
        _ = try ProcessRunner().runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: ["-arch", "arm64", "-o", executableURL.path, fixtureSource.path],
            timeout: 120
        )
        _ = try ProcessRunner().runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", executableURL.path],
            timeout: 60
        )
        try Data("{}".utf8).write(to: executablePackRoot.appendingPathComponent("sbom.json"))
        var executableManifest = RuntimePackManifest(
            runtime: RuntimeManifest(
                id: "executable-test",
                kind: .library,
                version: "1.0.0",
                entryPoints: ["check": "bin/devstack-check"],
                license: "MIT",
                source: SourceProvenance(url: URL(string: "https://example.test/runtime.tar.xz")!, sha256: String(repeating: "1", count: 64)),
                supportState: .supported
            ),
            payload: [RuntimePackFile(path: "bin/devstack-check", sha256: try unsignedVerifier.sha256(executableURL), executable: true)],
            signingIdentity: "DevStack Test",
            sbomPath: "sbom.json"
        )
        let executableSignature = try privateKey.signature(for: unsignedVerifier.canonicalManifestData(executableManifest))
        executableManifest.signature = RuntimePackSignature(keyID: "test", value: executableSignature.base64EncodedString())
        try verifier.verify(manifest: executableManifest, root: executablePackRoot)
        var forbiddenManifest = executableManifest
        forbiddenManifest.runtime.dependencyPaths = ["/opt/homebrew/lib/libdevstack.dylib"]
        do {
            try RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false).verify(
                manifest: forbiddenManifest,
                root: executablePackRoot,
                verifyCodeSignatures: false
            )
            throw CheckFailure(description: "Build-machine dependency path was accepted")
        } catch RuntimePackVerificationError.forbiddenDependency {
            // Expected.
        }

        let fakeApache = paths.builtInRuntimes.appendingPathComponent("apache-2.4/bin/httpd")
        try AtomicFileWriter.write("#!/bin/sh\necho 'Syntax OK'\n", to: fakeApache, permissions: 0o755)
        try AtomicFileWriter.write("# generated httpd.conf\n", to: paths.generatedApache.appendingPathComponent("httpd.conf"), permissions: 0o644)

        let helperStatus = PrivilegedHelperStatus(hostMappingsInstalled: true, portForwardingEnabled: true, localCATrusted: false, version: "1.0")
        let failedMySQL = ServiceFailure(message: "Service exited unexpectedly.", exitCode: 1, recoveryAction: "Restart MySQL and inspect its log.")
        let report = DevStackDoctor().run(
            context: DiagnosticContext(
                paths: paths,
                helperInstalled: true,
                helperStatus: helperStatus,
                expectedHostnames: ["example.test"],
                serviceStates: [
                    ServiceState(service: .mailpit, phase: .running, pid: 1234),
                    ServiceState(service: .mysql84, phase: .failed, failure: failedMySQL)
                ],
                selectedDatabase: .mysql57
            ),
            appVersion: "0.1.0"
        )
        try expect(report.results.contains(where: { $0.id == "architecture" }), "Doctor omitted architecture check")
        try expect(report.results.contains(where: { $0.id == "privileged-helper" && $0.severity == .info && $0.evidence.contains("1.0") }), "Doctor did not report authenticated helper status")
        try expect(report.results.contains(where: { $0.id == "helper-port-forwarding" && $0.severity == .info }), "Doctor omitted enabled port forwarding")
        try expect(report.results.contains(where: { $0.id == "ca-trust" && $0.severity == .warning }), "Doctor did not flag untrusted local CA")
        try expect(report.results.contains(where: { $0.id == "service-mailpit" && $0.severity == .info }), "Doctor did not report running service")
        try expect(report.results.contains(where: { $0.id == "service-mysql-8.4" && $0.severity == .error && $0.remediation == failedMySQL.recoveryAction }), "Doctor did not surface service failure recovery")
        try expect(report.results.contains(where: { $0.id == "database-state" && $0.evidence.contains("MySQL 5.7.44") }), "Doctor did not report selected database state")
        try expect(report.results.contains(where: { $0.id == "config-php-8.5" && $0.severity == .warning }), "Doctor did not skip missing runtime configuration")
        try expect(report.results.contains(where: { $0.id == "config-apache" && $0.severity == .info && $0.evidence.contains("Syntax OK") }), "Doctor did not validate installed Apache configuration")
        try expect(report.results.contains(where: { $0.id == "port-3306" }), "Doctor omitted database port check")

        let missingHelperReport = DevStackDoctor().run(
            context: DiagnosticContext(paths: paths, helperInstalled: false, expectedHostnames: ["example.test"]),
            appVersion: "0.1.0"
        )
        try expect(missingHelperReport.results.contains(where: { $0.id == "privileged-helper" && $0.severity == .error }), "Doctor omitted missing helper")

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
