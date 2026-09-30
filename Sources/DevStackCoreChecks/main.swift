import DevStackCore
import CryptoKit
import Foundation
import Network

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

private struct BuildToolsLockCheck: Decodable {
    var schemaVersion: Int
    var tools: [BuildToolCheck]
}

private struct BuildToolCheck: Decodable {
    var id: String
    var version: String
    var kind: String
    var url: URL
    var sha256: String
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
        let old = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"schemaVersion":1,"selectedDatabase":"mysql-8.4"}"#.utf8))
        try expect(old.selectedPostgreSQL == .none, "Existing installations unexpectedly enable PostgreSQL")
        try expect(old.enabledExtensions["php-8.4"]?.contains("pdo_pgsql") == true, "Existing PHP configuration did not gain its PostgreSQL driver")
        for mysql in [DatabaseEngine.none, .mysql84] {
            for postgres in [PostgreSQLEngine.none, .postgresql18] {
                let configuration = AppConfiguration(selectedDatabase: mysql, selectedPostgreSQL: postgres)
                let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
                try expect(decoded == configuration, "Database selections do not survive relaunch")
                let expected: Set<ServiceKind> = Set([mysql.service, postgres.service].compactMap { $0 })
                try expect(Set(configuration.selectedDatabaseServices) == expected, "Start Stack includes a disabled database")
            }
        }

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

        let buildToolsLockURL = repositoryRoot.appendingPathComponent("Dependencies/build-tools-lock.json")
        let buildToolsLock = try JSONDecoder().decode(BuildToolsLockCheck.self, from: Data(contentsOf: buildToolsLockURL))
        try expect(buildToolsLock.schemaVersion == 1, "Unsupported build-tools lock schema")
        try expect(Set(buildToolsLock.tools.map(\.id)).count == buildToolsLock.tools.count, "Build-tools lock contains duplicate IDs")
        try expect(buildToolsLock.tools.allSatisfy { $0.sha256.count == 64 }, "Build-tool checksum is malformed")
        try expect(buildToolsLock.tools.allSatisfy { $0.url.scheme == "https" }, "Build-tool source is not HTTPS")
        try expect(buildToolsLock.tools.allSatisfy { !$0.version.isEmpty && !$0.kind.isEmpty }, "Build-tool metadata is incomplete")

        try expect(
            HostnameValidator.validate(" Example.TEST. ") == "example.test",
            "Hostname normalization failed"
        )
        do {
            _ = try HostnameValidator.validate("192.168.0.1")
            throw CheckFailure(description: "IP literal hostname was accepted")
        } catch HostnameValidationError.ipLiteral {
            // Expected.
        }
        do {
            _ = try HostnameValidator.validate("*.example.test")
            throw CheckFailure(description: "Wildcard hostname was accepted")
        } catch HostnameValidationError.wildcard {
            // Expected.
        }
        do {
            _ = try HostnameValidator.validate("example.test", existing: ["EXAMPLE.test."])
            throw CheckFailure(description: "Duplicate hostname was accepted")
        } catch HostnameValidationError.duplicate {
            // Expected.
        }
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
        let validForwarding = try PrivilegedRequestValidator.portForwarding(.init(enabled: true, entries: [.init(publicPort: 80, upstreamPort: 8080)]))
        try expect(validForwarding.entries.count == 1, "Privileged loopback forwarding was rejected")
        do {
            _ = try PrivilegedRequestValidator.portForwarding(.init(enabled: true, entries: [.init(publicPort: 8080, upstreamPort: 8080)]))
            throw CheckFailure(description: "Unprivileged public port was accepted for forwarding")
        } catch PrivilegedRequestValidationError.invalidPortForwarding {
            // Expected.
        }
        do {
            _ = try PrivilegedRequestValidator.portForwarding(.init(enabled: true, entries: [.init(publicPort: 22, upstreamPort: 8080)]))
            throw CheckFailure(description: "Reserved port forwarding was accepted")
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
        let composerWrapper = renderer.composerWrapperScript()
        try expect(composerWrapper.contains("self-update"), "Composer wrapper does not guard self-update")
        try expect(composerWrapper.contains("php-8.5"), "Composer wrapper does not use the managed PHP runtime")
        let phpINI = try renderer.phpINI(runtimeID: "php-8.5", enabledExtensions: ["xdebug", "redis"], mailpitBinary: URL(fileURLWithPath: "/tmp/mailpit"))
        try expect(phpINI.contains("xdebug.client_port=9003"), "Xdebug endpoint was not pinned")
        try expect(phpINI.contains("sendmail_path"), "Mail delivery was not configured")
        try expect(renderer.mailpitArguments().contains("--disable-version-check"), "Mailpit version check was not disabled")
        let privilegedPorts = ServicePorts(webHTTP: 80, webHTTPS: 9443)
        try expect(privilegedPorts.webHTTPListen == ServicePorts.webHTTPFallback, "Privileged HTTP port did not fall back to the unprivileged listener")
        try expect(privilegedPorts.forwardings == [PortForwardingEntry(publicPort: 80, upstreamPort: ServicePorts.webHTTPFallback)], "Privileged port did not produce the expected forwarding")
        try expect(privilegedPorts.requiresHelper, "Privileged port did not report the helper requirement")
        try expect(ServicePorts(mysql: ServicePorts.webHTTPFallback).collisions == [ServicePorts.webHTTPFallback], "Port collisions were not detected")
        let customRenderer = ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes, ports: privilegedPorts)
        let customApache = try customRenderer.apacheConfiguration(sites: [site])
        try expect(customApache.contains("Listen 127.0.0.1:\(ServicePorts.webHTTPFallback)") && customApache.contains("Listen 127.0.0.1:9443"), "Custom Apache listeners were not rendered")
        try expect(customApache.contains("https://example.test:9443/"), "Custom HTTPS redirect port was not rendered")
        let customINI = try customRenderer.phpINI(runtimeID: "php-8.5", enabledExtensions: [], mailpitBinary: URL(fileURLWithPath: "/tmp/mailpit"))
        try expect(customINI.contains("mysqli.default_port=\(ServicePorts.mysqlFallback)"), "Configured PHP database port was not rendered")
        try expect(customRenderer.mailpitArguments().contains("127.0.0.1:\(ServicePorts.mailpitInboxFallback)"), "Configured Mailpit listener was not rendered")
        let dnsQuery = { (name: String, type: UInt16, id: UInt16) -> Data in
            var data = Data([UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            for label in name.split(separator: ".") {
                data.append(UInt8(label.utf8.count))
                data.append(contentsOf: label.utf8)
            }
            data.append(0)
            data.append(contentsOf: [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01])
            return data
        }
        guard let question = DNSMessage.parseQuestion(dnsQuery("site.test", DNSMessage.typeA, 0x1234)) else {
            throw CheckFailure(description: "DNS query did not parse")
        }
        try expect(question.id == 0x1234 && question.name == "site.test" && question.type == DNSMessage.typeA && question.klass == DNSMessage.classIN, "DNS question fields are wrong")
        let localAnswer = DNSMessage.localResponse(for: question, address: "192.168.1.50")
        try expect(UInt16(localAnswer[6]) << 8 | UInt16(localAnswer[7]) == 1, "Local DNS answer did not include an A record")
        try expect(localAnswer.suffix(4) == Data([192, 168, 1, 50]), "Local DNS answer address is wrong")
        guard let aaaa = DNSMessage.parseQuestion(dnsQuery("site.test", DNSMessage.typeAAAA, 2)) else {
            throw CheckFailure(description: "AAAA query did not parse")
        }
        let nodata = DNSMessage.localResponse(for: aaaa, address: "192.168.1.50")
        try expect(UInt16(nodata[6]) << 8 | UInt16(nodata[7]) == 0, "AAAA for a managed hostname must answer NODATA")
        let failure = DNSMessage.failureResponse(for: question, rcode: DNSMessage.rcodeServerFailure)
        try expect(failure[3] & 0x0F == 2, "DNS failure rcode is wrong")
        try expect(DNSUpstreams.parseResolvConf("nameserver 192.168.1.1\nnameserver 8.8.8.8 # lan\n").count == 2, "resolv.conf parsing failed")
        try expect(DNSUpstreams.usableResolvers(contents: "nameserver 127.0.0.1\nnameserver 192.168.1.1\n", excluding: []).count == 1, "Loopback resolver was not excluded")
        try expect(LocalNetwork.isPrivateIPv4("192.168.1.5") && LocalNetwork.isPrivateIPv4("10.0.0.1") && !LocalNetwork.isPrivateIPv4("8.8.8.8"), "Private IPv4 classification failed")
        try expect(LocalNetwork.isLocalSource("192.168.1.5") && LocalNetwork.isLocalSource("::1") && !LocalNetwork.isLocalSource("8.8.8.8"), "Local source classification failed")
        let validatedDNS = try PrivilegedRequestValidator.dnsConfiguration(DNSConfiguration(enabled: true, hostnames: ["site.test"], answerAddress: "192.168.1.50"))
        try expect(validatedDNS.hostnames == ["site.test"], "DNS configuration validation failed")
        do {
            _ = try PrivilegedRequestValidator.dnsConfiguration(DNSConfiguration(enabled: true, hostnames: ["site.test"], answerAddress: "8.8.8.8"))
            throw CheckFailure(description: "Public DNS answer address was accepted")
        } catch PrivilegedRequestValidationError.invalidDNSAddress {
            // Expected.
        }
        do {
            _ = try PrivilegedRequestValidator.portForwarding(.init(enabled: true, lanEntries: [.init(publicPort: 22, upstreamPort: 8080)]))
            throw CheckFailure(description: "Reserved LAN forwarding was accepted")
        } catch PrivilegedRequestValidationError.invalidPortForwarding {
            // Expected.
        }
        func udpRoundTrip(_ query: Data, port: UInt16) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
                let gate = UDPReplyGate(continuation: continuation)
                connection.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    connection.send(content: query, completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { data, _, _, error in
                            if let error { gate.fail(error) }
                            else if let data, !data.isEmpty { gate.succeed(data) }
                            else { gate.fail(CocoaError(.coderReadCorrupt)) }
                            connection.cancel()
                        }
                    })
                }
                connection.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { gate.fail(URLError(.timedOut)) }
            }
        }
        let responder = LocalDNSResponder(port: 15453)
        try responder.apply(DNSConfiguration(enabled: true, hostnames: ["site.test"], answerAddress: "192.168.1.50"), upstreams: [])
        defer { responder.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let liveAnswer = try await udpRoundTrip(dnsQuery("site.test", DNSMessage.typeA, 0x2222), port: 15453)
        try expect(liveAnswer.count >= 12 && UInt16(liveAnswer[6]) << 8 | UInt16(liveAnswer[7]) == 1, "Live DNS responder did not answer")
        try expect(liveAnswer.suffix(4) == Data([192, 168, 1, 50]), "Live DNS responder answered the wrong address")
        let liveRefusal = try await udpRoundTrip(dnsQuery("example.com", DNSMessage.typeA, 0x3333), port: 15453)
        try expect(liveRefusal[3] & 0x0F == 2, "DNS responder did not fail closed without upstreams")
        var unsafeSite = site
        unsafeSite.documentRoot = "/tmp/example\nRequire all granted"
        do {
            _ = try renderer.apacheConfiguration(sites: [unsafeSite])
            throw CheckFailure(description: "Configuration metacharacters were accepted")
        } catch ConfigurationRendererError.unsafeValue {
            // Expected.
        }

        let store = AppConfigurationStore(url: paths.configurationFile)
        var configuration = AppConfiguration()
        configuration.sites = [site]
        try await store.save(configuration)
        let loaded = try await store.load()
        try expect(loaded == configuration, "Configuration round trip failed")

        let newerConfiguration = temporary.appendingPathComponent("newer-configuration.json")
        try Data(#"{"schemaVersion":99,"sites":[],"selectedDatabase":"mysql-8.4","enabledExtensions":{},"startAtLogin":false,"importedRuntimeIDs":[]}"#.utf8).write(to: newerConfiguration)
        do {
            _ = try await AppConfigurationStore(url: newerConfiguration).load()
            throw CheckFailure(description: "Newer configuration schema was accepted")
        } catch let error as CocoaError where error.code == .fileReadCorruptFile {
            // Expected.
        }
        let atomicProbe = temporary.appendingPathComponent("atomic-probe")
        try AtomicFileWriter.write("probe", to: atomicProbe, permissions: 0o600)
        let atomicAttributes = try FileManager.default.attributesOfItem(atPath: atomicProbe.path)
        try expect((atomicAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Atomic writer did not apply permissions")

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
        let streamedInput = temporary.appendingPathComponent("streamed-input.sql")
        let streamedOutput = temporary.appendingPathComponent("streamed-output.sql")
        let largeInput = Data(repeating: 0x61, count: 2_000_000)
        try largeInput.write(to: streamedInput)
        let streamed = try ProcessRunner().runChecked(executable: URL(fileURLWithPath: "/bin/cat"),
            standardInputFile: streamedInput, standardOutputFile: streamedOutput)
        try expect(streamed.standardOutput.isEmpty && (try Data(contentsOf: streamedOutput)) == largeInput,
            "SQL file streaming did not preserve the input or captured it in memory")

        let timeoutStart = Date()
        do {
            _ = try ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            throw CheckFailure(description: "Command timeout was ignored")
        } catch CommandExecutionError.timedOut { }
        try expect(Date().timeIntervalSince(timeoutStart) < 3.5, "Command cleanup exceeded its bounded deadline")

        let databaseManager = DatabaseManager(paths: paths, runtimeRoot: paths.builtInRuntimes)
        do {
            _ = try databaseManager.initializeIfNeeded(.none)
            throw CheckFailure(description: "No MySQL was treated as a database engine")
        } catch DatabaseManagerError.engineNotSelected { }
        let backupName = databaseManager.backupFilename(
            engine: .mysql84,
            database: nil,
            date: Date(timeIntervalSince1970: 0)
        )
        try expect(backupName == "mysql-8.4-all-databases-19700101-000000-000.sql", "Database backup naming is not deterministic")
        try expect(
            databaseManager.archiveDataDirectoryName(engine: .mysql57, date: Date(timeIntervalSince1970: 0)) == "mysql-5.7-data-19700101-000000-000",
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

        let helperStatus = PrivilegedHelperStatus(hostMappingsInstalled: true, portForwardingEnabled: true, version: "1.0")
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
        try expect(missingHelperReport.results.contains(where: { $0.id == "privileged-helper" && $0.severity == .warning }), "Doctor omitted missing helper")

        var optionalRuntime = executableManifest.runtime
        optionalRuntime.id = "mysql-5.7"
        optionalRuntime.kind = .mysql
        optionalRuntime.supportState = .endOfLife
        optionalRuntime.build = RuntimeBuildMetadata(buildSystem: "test", flags: [], feasibilityGate: "Legacy compatibility")
        let optionalReport = DevStackDoctor().run(context: DiagnosticContext(paths: paths, runtimeManifests: [optionalRuntime]), appVersion: "checks")
        try expect(optionalReport.results.contains { $0.id == "runtime-mysql-5.7" && $0.severity == .info }, "Doctor treated an intentionally omitted legacy runtime as a repair failure")
        let requiredReport = DevStackDoctor().run(context: DiagnosticContext(paths: paths, runtimeManifests: [optionalRuntime], requiredRuntimeIDs: ["mysql-5.7"]), appVersion: "checks")
        try expect(requiredReport.results.contains { $0.id == "runtime-mysql-5.7" && $0.severity == .error }, "Doctor failed to report a missing selected runtime")

        let migrated = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"schemaVersion":1,"sites":[]}"#.utf8))
        try expect(migrated.selectedWebServer == .apache, "Nginx must stay disabled when migrating old configurations")
        try expect(migrated.ports == ServicePorts() && !migrated.localNetworkAccess && migrated.schemaVersion == AppConfiguration.currentSchemaVersion, "Port defaults or schema migration failed")
        try expect(paths.phpSocket(runtimeID: "php-8.5", siteID: UUID()).path.utf8.count < 104, "PHP socket exceeds the macOS limit")
        let supervisorRecord = temporary.appendingPathComponent("processes.json")
        let supervisor = ServiceSupervisor(recordsURL: supervisorRecord)
        let serviceLog = temporary.appendingPathComponent("logs/sleep.log")
        try await supervisor.start(ServiceSpecification(
            kind: .mailpit,
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            logFile: serviceLog
        ))
        let runningState = await supervisor.state(for: .mailpit)
        try expect(runningState.phase == .running, "Service did not enter running state")
        let reconciledSupervisor = ServiceSupervisor(recordsURL: supervisorRecord)
        let restoredState = await reconciledSupervisor.state(for: .mailpit)
        try expect(restoredState.phase == .running && restoredState.pid == runningState.pid, "Supervisor did not restore the owned process")
        await reconciledSupervisor.stop(.mailpit)
        let stoppedState = await supervisor.state(for: .mailpit)
        try expect(stoppedState.phase == .stopped, "Service did not stop")
        print("DevStackCoreChecks: all checks passed")
    }
}

private final class UDPReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func succeed(_ data: Data) { complete { .success(data) } }
    func fail(_ error: Error) { complete { .failure(error) } }

    private func complete(_ result: () -> Result<Data, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result())
    }
}
