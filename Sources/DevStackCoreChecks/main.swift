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
            builtInRuntimes: temporary.appendingPathComponent("runtimes"),
            defaultSiteRoot: temporary.appendingPathComponent("DevStack")
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
        let defaultSite = SiteDefinition.defaultSite(paths: paths, phpRuntimeID: "php-8.5")
        let withDefault = try renderer.apacheConfiguration(sites: [site, defaultSite])
        let defaultRange = withDefault.range(of: "ServerName localhost")
        let exampleRange = withDefault.range(of: "ServerName example.test")
        try expect(defaultRange != nil && exampleRange != nil && defaultRange!.lowerBound < exampleRange!.lowerBound, "Default localhost vhost is not the first server")
        try expect(withDefault.contains("ServerAlias 127.0.0.1"), "Default vhost does not answer 127.0.0.1")
        try expect(!withDefault.contains("/ https://localhost"), "Default site must serve HTTP without redirect")
        try expect(apache.contains("Redirect temp / https://example.test") && !apache.contains("Redirect permanent"), "The HTTPS redirect must stay temporary")
        let zonedINI = try ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes, timeZone: "Europe/Istanbul").phpINI(runtimeID: "php-8.5", enabledExtensions: [], mailpitBinary: URL(fileURLWithPath: "/tmp/mailpit"))
        let unsafeZoneINI = try ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes, timeZone: "UTC\nextension=evil").phpINI(runtimeID: "php-8.5", enabledExtensions: [], mailpitBinary: URL(fileURLWithPath: "/tmp/mailpit"))
        try expect(zonedINI.contains("date.timezone=Europe/Istanbul") && unsafeZoneINI.contains("date.timezone=UTC\n") && !unsafeZoneINI.contains("evil"), "PHP time zone was not rendered safely")
        try expect(withDefault.contains(paths.defaultSiteRoot.path), "Default site document root was not rendered")
        let nginx = try renderer.nginxConfiguration(sites: [site, defaultSite])
        let nginxDefault = nginx.range(of: "server_name localhost 127.0.0.1 _;")
        let nginxExample = nginx.range(of: "server_name example.test;")
        try expect(nginxDefault != nil && nginxExample != nil && nginxDefault!.lowerBound < nginxExample!.lowerBound, "Default localhost server is not first in nginx")
        let hiddenPathRule = #"<LocationMatch "/\.(?!well-known/)">"#
        // Every vhost serving a site directory carries the rule: two for localhost
        // (HTTP and HTTPS) and one for the HTTPS-only example site.
        try expect(withDefault.components(separatedBy: hiddenPathRule).count - 1 == 3, "Apache does not deny hidden paths in every site vhost")
        let nginxHiddenDeny = nginx.range(of: #"location ~ /\.(?!well-known/) { deny all; }"#)
        let nginxPHP = nginx.range(of: #"location ~ \.php$"#)
        try expect(nginxHiddenDeny != nil && nginxPHP != nil && nginxHiddenDeny!.lowerBound < nginxPHP!.lowerBound, "nginx must deny hidden paths before handing .php files to PHP")
        try expect((try? HostnameValidator.validateSite("app.test")) == "app.test", "A regular site hostname was rejected")
        do {
            _ = try HostnameValidator.validateSite("PhpMyAdmin.localhost.")
            throw CheckFailure(description: "A site claimed a management hostname")
        } catch HostnameValidationError.reserved {
            // Expected.
        }
        let lanRenderer = ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes, localNetworkAccess: true)
        let lanApache = try lanRenderer.apacheConfiguration(sites: [site, defaultSite])
        try expect(lanApache.contains("Listen 0.0.0.0:\(ServicePorts.webHTTPFallback)") && lanApache.contains("Require ip 127.0.0.1 ::1 10.0.0.0/8"), "Local network Apache listeners or access rules were not rendered")
        let lanNginx = try lanRenderer.nginxConfiguration(sites: [site, defaultSite])
        try expect(lanNginx.contains("listen 0.0.0.0:\(ServicePorts.webHTTPFallback)") && lanNginx.contains("deny all"), "Local network nginx listeners or access rules were not rendered")
        let placeholderRoot = temporary.appendingPathComponent("default-site")
        try FileManager.default.createDirectory(at: placeholderRoot, withIntermediateDirectories: true)
        try expect(DefaultSiteContent.ensurePlaceholderIndex(in: placeholderRoot, hostname: "localhost", isDefaultSite: true), "Placeholder index.php was not created")
        try expect(FileManager.default.fileExists(atPath: placeholderRoot.appendingPathComponent("index.php").path), "Placeholder index.php is missing")
        try expect(!DefaultSiteContent.ensurePlaceholderIndex(in: placeholderRoot, hostname: "localhost", isDefaultSite: true), "Placeholder overwrote an existing index")
        try AtomicFileWriter.write("<?php // DevStack placeholder. Replace this file with your project's entry point.\n", to: placeholderRoot.appendingPathComponent("index.php"), permissions: 0o644)
        try expect(DefaultSiteContent.refreshPlaceholderIndex(in: placeholderRoot, hostname: "localhost", isDefaultSite: true), "Stale placeholder was not refreshed")
        try AtomicFileWriter.write("<?php // user project\n", to: placeholderRoot.appendingPathComponent("index.php"), permissions: 0o644)
        try expect(!DefaultSiteContent.refreshPlaceholderIndex(in: placeholderRoot, hostname: "localhost", isDefaultSite: true), "Refresh overwrote a user-edited index")
        let php = try renderer.phpFPMConfiguration(runtimeID: "php-8.5", sites: [site], includeManagementPool: true)
        try expect(php.contains("[management]"), "PHP management pool was not rendered")
        try expect(php.contains(site.id.uuidString.replacingOccurrences(of: "-", with: "_").lowercased()), "Site PHP pool was not rendered")
        // Sites must be able to override their error handling with ini_set().
        try expect(php.contains("php_value[display_errors]"), "Site display_errors is not overridable")
        try expect(php.contains("php_value[error_log]"), "Site error_log is not overridable")
        try expect(!php.contains("php_admin_value[display_errors] = On"), "Site display_errors is still forced on")
        let phpMyAdminConfig = try renderer.phpMyAdminConfiguration(cookieSecret: String(repeating: "a", count: 32))
        try expect(phpMyAdminConfig.contains("['auth_type'] = 'config'") && phpMyAdminConfig.contains("['user'] = 'root'"), "phpMyAdmin does not sign in automatically")
        let adminerWrapper = renderer.adminerWrapperPHP(adminerIndex: URL(fileURLWithPath: "/tmp/adminer/index.php"))
        try expect(adminerWrapper.contains("function adminer_object()") && adminerWrapper.contains("include '/tmp/adminer/index.php'"), "Adminer wrapper was not rendered")
        let composerWrapper = renderer.composerWrapperScript()
        try expect(composerWrapper.contains("self-update"), "Composer wrapper does not guard self-update")
        try expect(composerWrapper.contains("php-8.5"), "Composer wrapper does not use the managed PHP runtime")
        let phpINI = try renderer.phpINI(runtimeID: "php-8.5", enabledExtensions: ["xdebug", "redis"], mailpitBinary: URL(fileURLWithPath: "/tmp/mailpit"))
        try expect(phpINI.contains("xdebug.client_port=9003"), "Xdebug endpoint was not pinned")
        try expect(phpINI.contains("sendmail_path"), "Mail delivery was not configured")
        try expect(!phpINI.contains("opcache.so"), "PHP 8.5 builds OPcache in; nothing to load")
        let sharedOPcache = paths.builtInRuntimes.appendingPathComponent("php-8.4/lib/php/extensions/no-debug-non-zts-20240924/opcache.so")
        try FileManager.default.createDirectory(at: sharedOPcache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: sharedOPcache)
        let php84INI = try renderer.phpINI(runtimeID: "php-8.4", enabledExtensions: ["xdebug"], mailpitBinary: URL(fileURLWithPath: "/tmp/mailpit"))
        let opcacheLine = php84INI.range(of: "zend_extension=\"\(sharedOPcache.path)\"")
        try expect(opcacheLine != nil, "PHP 8.4's shared OPcache is not loaded")
        try expect(opcacheLine!.lowerBound < php84INI.range(of: "xdebug.so")!.lowerBound, "OPcache must load before Xdebug")
        try expect(renderer.mailpitArguments().contains("--disable-version-check"), "Mailpit version check was not disabled")
        let privilegedPorts = ServicePorts(webHTTP: 80, webHTTPS: 9443)
        try expect(privilegedPorts.webHTTPListen == ServicePorts.webHTTPFallback, "Privileged HTTP port did not fall back to the unprivileged listener")
        try expect(privilegedPorts.forwardings == [PortForwardingEntry(publicPort: 80, upstreamPort: ServicePorts.webHTTPFallback)], "Privileged port did not produce the expected forwarding")
        try expect(privilegedPorts.forwardingEntries(proxyProtocol: true) == [PortForwardingEntry(publicPort: 80, upstreamPort: ServicePorts.proxyHTTPFallback, proxyProtocol: true)], "Privileged port did not produce a PROXY protocol forwarding")
        try expect(privilegedPorts.requiresHelper, "Privileged port did not report the helper requirement")
        try expect(ServicePorts(mysql: ServicePorts.webHTTPFallback).collisions == [ServicePorts.webHTTPFallback], "Port collisions were not detected")
        let legacyEntry = try JSONDecoder().decode(PortForwardingEntry.self, from: Data(#"{"publicPort":80,"upstreamPort":8080}"#.utf8))
        try expect(legacyEntry.proxyProtocol == false, "Forwarding entry without a proxy-protocol field must decode as false")
        let proxyForwarding = try PrivilegedRequestValidator.portForwarding(.init(enabled: true, entries: [.init(publicPort: 80, upstreamPort: ServicePorts.proxyHTTPFallback, proxyProtocol: true)]))
        try expect(proxyForwarding.entries.first?.proxyProtocol == true, "PROXY protocol forwarding was rejected")
        do {
            _ = try PrivilegedRequestValidator.portForwarding(.init(enabled: true, entries: [.init(publicPort: 80, upstreamPort: 8080, proxyProtocol: true)]))
            throw CheckFailure(description: "A PROXY header to a non-web listener was accepted")
        } catch PrivilegedRequestValidationError.invalidPortForwarding {
            // Expected.
        }
        let legacyStatus = try JSONDecoder().decode(PrivilegedHelperStatus.self, from: Data(#"{"hostMappingsInstalled":true,"portForwardingEnabled":false,"version":"0.1.0"}"#.utf8))
        try expect(legacyStatus.capabilities.isEmpty && legacyStatus.build.isEmpty, "Legacy helper status must decode with empty defaults")
        let proxyStatus = try JSONDecoder().decode(PrivilegedHelperStatus.self, from: Data(#"{"hostMappingsInstalled":true,"portForwardingEnabled":true,"version":"0.1.0","capabilities":["proxy-protocol"]}"#.utf8))
        try expect(proxyStatus.capabilities.contains(PrivilegedHelperCapabilities.proxyProtocol), "Helper capabilities were not decoded")
        let customRenderer = ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes, ports: privilegedPorts)
        let customApache = try customRenderer.apacheConfiguration(sites: [site])
        try expect(customApache.contains("Listen 127.0.0.1:\(ServicePorts.webHTTPFallback)") && customApache.contains("Listen 127.0.0.1:9443"), "Custom Apache listeners were not rendered")
        try expect(customApache.contains("https://example.test:9443/"), "Custom HTTPS redirect port was not rendered")
        let mixedProxyCount = customApache.components(separatedBy: "RemoteIPProxyProtocol On").count - 1
        try expect(customApache.contains("<VirtualHost *:\(ServicePorts.proxyHTTPFallback)>") && mixedProxyCount == 1, "Mixed-privilege Apache config did not isolate the PROXY protocol vhost")
        let bothPrivileged = ServicePorts(webHTTP: 80, webHTTPS: 443)
        let proxyRenderer = ConfigurationRenderer(paths: paths, runtimeRoot: paths.builtInRuntimes, ports: bothPrivileged)
        let proxyApache = try proxyRenderer.apacheConfiguration(sites: [site, defaultSite])
        try expect(proxyApache.contains("Listen 127.0.0.1:\(ServicePorts.proxyHTTPFallback)") && proxyApache.contains("Listen 127.0.0.1:\(ServicePorts.proxyHTTPSFallback)"), "Apache PROXY listeners were not rendered")
        try expect(proxyApache.contains("LoadModule remoteip_module"), "Apache remoteip module was not loaded")
        try expect(proxyApache.contains("<VirtualHost *:\(ServicePorts.proxyHTTPFallback)>") && proxyApache.contains("RemoteIPProxyProtocol On"), "Apache PROXY vhosts were not rendered")
        let proxyNginx = try proxyRenderer.nginxConfiguration(sites: [site, defaultSite])
        try expect(!proxyNginx.contains(";;") && !proxyNginx.contains("listen listen"), "nginx listener directives are malformed")
        try expect(proxyNginx.contains("listen 127.0.0.1:\(ServicePorts.proxyHTTPFallback) proxy_protocol;"), "nginx PROXY HTTP listener was not rendered")
        try expect(proxyNginx.contains("listen 127.0.0.1:\(ServicePorts.proxyHTTPSFallback) ssl proxy_protocol;"), "nginx PROXY HTTPS listener was not rendered")
        try expect(proxyNginx.contains("real_ip_header proxy_protocol;") && proxyNginx.contains("set_real_ip_from 127.0.0.1;"), "nginx realip was not configured")
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
        try expect(UInt16(nodata[8]) << 8 | UInt16(nodata[9]) == 1, "NODATA answer must carry an SOA authority record")
        let failure = DNSMessage.failureResponse(for: question, rcode: DNSMessage.rcodeServerFailure)
        try expect(failure[3] & 0x0F == 2, "DNS failure rcode is wrong")
        let ttlRange = (localAnswer.count - 10)..<(localAnswer.count - 6)
        try expect(Array(localAnswer[ttlRange]) == [0, 0, 0, 1], "Local DNS TTL must be one second")
        guard let missingQuestion = DNSMessage.parseQuestion(dnsQuery("missing.test", DNSMessage.typeA, 3)) else {
            throw CheckFailure(description: "Negative query did not parse")
        }
        let negative = DNSMessage.negativeResponse(for: missingQuestion)
        try expect(negative[3] & 0x0F == 3, "Negative response rcode is wrong")
        try expect(UInt16(negative[8]) << 8 | UInt16(negative[9]) == 1, "Negative response must carry an SOA authority record")
        try expect(LocalDNSResponder.isDevStackName("new-site.test") && LocalDNSResponder.isDevStackName("phpmyadmin.localhost") && !LocalDNSResponder.isDevStackName("example.com"), "DevStack suffix classification failed")
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
        let responder = LocalDNSResponder(port: 15453, idleTimeout: 0.5)
        let liveAddress = LocalNetwork.primaryIPv4Address() ?? "192.168.1.50"
        try responder.apply(DNSConfiguration(enabled: true, hostnames: ["site.test"], answerAddress: liveAddress), upstreams: [])
        defer { responder.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let liveAnswer = try await udpRoundTrip(dnsQuery("site.test", DNSMessage.typeA, 0x2222), port: 15453)
        try expect(liveAnswer.count >= 12 && UInt16(liveAnswer[6]) << 8 | UInt16(liveAnswer[7]) == 1, "Live DNS responder did not answer")
        if let octets = DNSMessage.ipv4Octets(liveAddress) {
            try expect(liveAnswer.suffix(4) == Data(octets), "Live DNS responder answered the wrong address")
        }
        let liveNegative = try await udpRoundTrip(dnsQuery("missing.test", DNSMessage.typeA, 0x4444), port: 15453)
        try expect(liveNegative[3] & 0x0F == 3, "Unmanaged .test name did not answer NXDOMAIN")
        let liveRefusal = try await udpRoundTrip(dnsQuery("example.com", DNSMessage.typeA, 0x3333), port: 15453)
        try expect(liveRefusal[3] & 0x0F == 2, "DNS responder did not fail closed without upstreams")
        try expect(responder.activeFlowCount > 0, "DNS responder did not track its client flows")
        try await Task.sleep(for: .milliseconds(1_200))
        try expect(responder.activeFlowCount == 0, "DNS responder kept idle client flows open")

        let forwarder = LoopbackForwarder()
        let forwardedPort = try ephemeralLoopbackPort()
        let refusingUpstream = try ephemeralLoopbackPort()
        try forwarder.apply(PortForwardingConfiguration(enabled: true, entries: [PortForwardingEntry(publicPort: forwardedPort, upstreamPort: refusingUpstream)]))
        let refusedClient = try connectLoopback(port: forwardedPort)
        let refusedStart = Date()
        let refusedRead = readLoopback(refusedClient, until: Data("never".utf8), timeout: 3)
        close(refusedClient)
        try expect(refusedRead.closed && Date().timeIntervalSince(refusedStart) < 2, "Forwarder kept a client open while its upstream refused connections")
        let upstreamPort = try ephemeralLoopbackPort()
        let upstreamListener = try listenLoopback(port: upstreamPort)
        defer { close(upstreamListener) }
        try forwarder.apply(PortForwardingConfiguration(enabled: true, entries: [PortForwardingEntry(publicPort: forwardedPort, upstreamPort: upstreamPort, proxyProtocol: true)]))
        let proxiedClient = try connectLoopback(port: forwardedPort)
        defer { close(proxiedClient) }
        _ = Data("ping".utf8).withUnsafeBytes { send(proxiedClient, $0.baseAddress, $0.count, 0) }
        let upstreamConnection = try acceptLoopback(upstreamListener, timeout: 3)
        defer { close(upstreamConnection) }
        let proxied = readLoopback(upstreamConnection, until: Data("ping".utf8), timeout: 3)
        let proxiedText = String(decoding: proxied.data, as: UTF8.self)
        try expect(proxiedText.hasPrefix("PROXY TCP4 127.0.0.1 127.0.0.1 ") && proxiedText.hasSuffix("\r\nping"), "Forwarder did not send the PROXY header ahead of the client bytes")
        try forwarder.apply(PortForwardingConfiguration(enabled: false))
        try expect(!forwarder.isEnabled, "Forwarder stayed enabled after being disabled")

        var unsafeSite = site
        unsafeSite.documentRoot = "/tmp/example\nRequire all granted"
        do {
            _ = try renderer.apacheConfiguration(sites: [unsafeSite])
            throw CheckFailure(description: "Configuration metacharacters were accepted")
        } catch ConfigurationRendererError.unsafeValue {
            // Expected.
        }
        // Trust is added by running security as the user (root cannot show the
        // dialog macOS requires); the path is one argument, spaces and all.
        let caPath = "/Users/me/Library/Application Support/DevStack/Local CA/ca.crt"
        let adminTrust = CertificateManager.trustArguments(caCertificatePath: caPath, keychainPath: "/Users/me/Library/Keychains/login.keychain-db", administrator: true)
        try expect(adminTrust.contains("-d") && adminTrust.last == caPath, "Administrator trust arguments are wrong")
        try expect(!adminTrust.contains("/Library/Keychains/System.keychain"), "Administrator trust must not write the system keychain")
        let userTrust = CertificateManager.trustArguments(caCertificatePath: caPath, keychainPath: "/Users/me/Library/Keychains/login.keychain-db", administrator: false)
        try expect(!userTrust.contains("-d") && userTrust.last == caPath, "User trust arguments are wrong")

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
        runtimeManifest.payload = [
            RuntimePackFile(path: "bin/php", sha256: try unsignedVerifier.sha256(payloadURL)),
            RuntimePackFile(path: "sbom.json", sha256: try unsignedVerifier.sha256(payloadRoot.appendingPathComponent("sbom.json")))
        ]
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

        // Import round trip through the same archive format the packager writes.
        try AtomicFileWriter.write(try JSONEncoder().encode(runtimeManifest), to: payloadRoot.appendingPathComponent("manifest.json"), permissions: 0o644)
        _ = try ProcessRunner().runChecked(executable: URL(fileURLWithPath: "/usr/bin/xattr"), arguments: ["-w", "app.devstack.check", "1", payloadURL.path])
        func packArchive(_ name: String) throws -> URL {
            let archive = temporary.appendingPathComponent(name)
            _ = try ProcessRunner().runChecked(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--sequesterRsrc", payloadRoot.path, archive.path])
            return archive
        }
        let importedRoot = temporary.appendingPathComponent("imported-runtimes", isDirectory: true)
        let importer = RuntimePackImporter(verifier: verifier)
        let imported = try importer.importArchive(try packArchive("valid.devstack-runtime"), into: importedRoot)
        try expect(imported.id == "php-test" && FileManager.default.fileExists(atPath: importedRoot.appendingPathComponent("php-test/bin/php").path), "Signed runtime pack was not imported")
        try Data("unlisted".utf8).write(to: payloadRoot.appendingPathComponent("bin/extra.so"))
        do {
            _ = try importer.importArchive(try packArchive("unlisted.devstack-runtime"), into: temporary.appendingPathComponent("rejected-runtimes"))
            throw CheckFailure(description: "Runtime pack with an unlisted file was imported")
        } catch RuntimePackVerificationError.unexpectedFile("bin/extra.so") {
            // Expected.
        }
        try FileManager.default.removeItem(at: payloadRoot.appendingPathComponent("bin/extra.so"))
        try FileManager.default.removeItem(at: payloadRoot.appendingPathComponent("manifest.json"))
        // Links travel in the signed manifest; the importer recreates the safe ones.
        var linkedManifest = runtimeManifest
        linkedManifest.links = [RuntimePackLink(path: "bin/php-cli", target: "php")]
        linkedManifest.signature = RuntimePackSignature(keyID: "test", value: try privateKey.signature(for: unsignedVerifier.canonicalManifestData(linkedManifest)).base64EncodedString())
        try AtomicFileWriter.write(try JSONEncoder().encode(linkedManifest), to: payloadRoot.appendingPathComponent("manifest.json"), permissions: 0o644)
        let linkedRoot = temporary.appendingPathComponent("linked-runtimes", isDirectory: true)
        _ = try importer.importArchive(try packArchive("linked.devstack-runtime"), into: linkedRoot)
        let importedLink = linkedRoot.appendingPathComponent("php-test/bin/php-cli")
        try expect((try? FileManager.default.destinationOfSymbolicLink(atPath: importedLink.path)) == "php"
                   && (try? String(contentsOf: importedLink, encoding: .utf8)) == "php-runtime", "A verified pack link was not recreated")
        try FileManager.default.removeItem(at: payloadRoot.appendingPathComponent("manifest.json"))
        for unsafe in [RuntimePackLink(path: "bin/escape", target: "../../../etc/passwd"), RuntimePackLink(path: "bin/absolute", target: "/etc/passwd"),
                       RuntimePackLink(path: "bin/dangling", target: "missing"), RuntimePackLink(path: "bin/php", target: "php"),
                       RuntimePackLink(path: "bin", target: "sbom.json")] {
            var unsafeManifest = runtimeManifest
            unsafeManifest.links = [unsafe]
            do {
                try RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false).verify(manifest: unsafeManifest, root: payloadRoot, verifyCodeSignatures: false)
                throw CheckFailure(description: "An unsafe pack link was accepted: \(unsafe.path) -> \(unsafe.target)")
            } catch RuntimePackVerificationError.unsafeLink {
                // Expected.
            }
        }
        // Pinned packs: dependency order, then download, hash check and install.
        func pin(_ id: String, requires: [String] = []) -> RuntimePackPin {
            RuntimePackPin(id: id, version: "1", packRevision: 1, name: "\(id)-1-r1", url: URL(string: "https://example.test/\(id)")!, sha256: "", size: 0, requires: requires)
        }
        let orderCatalog = RuntimePackCatalog(packs: [pin("php", requires: ["openssl", "imagemagick"]), pin("openssl"), pin("imagemagick"), pin("adminer", requires: ["php"])])
        try expect(try orderCatalog.installationOrder(for: ["adminer"]).map(\.id) == ["imagemagick", "openssl", "php", "adminer"], "Packs were not ordered after their requirements")
        for (catalog, expected) in [(RuntimePackCatalog(packs: [pin("a", requires: ["b"]), pin("b", requires: ["a"])]), RuntimePackInstallError.dependencyCycle("a")),
                                    (orderCatalog, RuntimePackInstallError.unknownPack("missing"))] {
            do {
                _ = try catalog.installationOrder(for: [expected == .unknownPack("missing") ? "missing" : "a"])
                throw CheckFailure(description: "Pack ordering accepted \(expected)")
            } catch let error as RuntimePackInstallError {
                try expect(error == expected, "Pack ordering reported \(error) instead of \(expected)")
            }
        }
        try AtomicFileWriter.write(try JSONEncoder().encode(linkedManifest), to: payloadRoot.appendingPathComponent("manifest.json"), permissions: 0o644)
        let installArchive = try packArchive("install.devstack-runtime")
        try FileManager.default.removeItem(at: payloadRoot.appendingPathComponent("manifest.json"))
        let installSize = (try FileManager.default.attributesOfItem(atPath: installArchive.path)[.size] as? NSNumber)?.int64Value ?? 0
        let installHash = try RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false).sha256(installArchive)
        let installPin = RuntimePackPin(id: "php-test", version: "8.5.11", packRevision: 1, name: "php-test-8.5.11-r1", url: installArchive, sha256: installHash, size: installSize)
        let installRoot = temporary.appendingPathComponent("pack-installs", isDirectory: true)
        do {
            try await RuntimePackInstaller(verifier: verifier, runtimes: installRoot).install(installPin)
            throw CheckFailure(description: "A pack was downloaded from a non-HTTPS URL")
        } catch RuntimePackInstallError.insecureURL {
            // Expected.
        }
        let installer = RuntimePackInstaller(verifier: verifier, runtimes: installRoot, allowsFileURLs: true)
        let downloaded = ProgressTotal()
        try await installer.install(installPin) { bytes in downloaded.set(bytes) }
        try expect(installer.isInstalled(installPin) && FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("php-test/bin/php-cli").path),
                   "A pinned pack was not installed with its links")
        try await installer.install(installPin)
        try expect(installer.isInstalled(installPin), "Reinstalling a pack over its installed copy failed")
        var tamperedPin = installPin
        tamperedPin.sha256 = String(repeating: "0", count: 64)
        tamperedPin.packRevision = 2
        do {
            try await installer.install(tamperedPin)
            throw CheckFailure(description: "A download that did not match its pinned hash was installed")
        } catch RuntimePackInstallError.checksumMismatch {
            try expect(installer.installedPin("php-test") == installPin, "A failed install replaced the installed pack")
        }

        var traversalManifest = runtimeManifest
        traversalManifest.runtime.id = "../php-test"
        traversalManifest.signature = RuntimePackSignature(keyID: "test", value: try privateKey.signature(for: unsignedVerifier.canonicalManifestData(traversalManifest)).base64EncodedString())
        do {
            try verifier.verify(manifest: traversalManifest, root: payloadRoot, verifyCodeSignatures: false)
            throw CheckFailure(description: "Runtime identifier with a path separator was accepted")
        } catch RuntimePackVerificationError.invalidRuntimeID {
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
            payload: [
                RuntimePackFile(path: "bin/devstack-check", sha256: try unsignedVerifier.sha256(executableURL), executable: true),
                RuntimePackFile(path: "sbom.json", sha256: try unsignedVerifier.sha256(executablePackRoot.appendingPathComponent("sbom.json")))
            ],
            signingIdentity: "DevStack Test",
            sbomPath: "sbom.json"
        )
        let executableSignature = try privateKey.signature(for: unsignedVerifier.canonicalManifestData(executableManifest))
        executableManifest.signature = RuntimePackSignature(keyID: "test", value: executableSignature.base64EncodedString())
        try verifier.verify(manifest: executableManifest, root: executablePackRoot)
        for team in ["ABCDE12345", "ABC\" or true"] {
            do {
                try RuntimePackVerifier(trustedPublicKeys: ["test": privateKey.publicKey.rawRepresentation], requiredTeamID: team)
                    .verify(manifest: executableManifest, root: executablePackRoot)
                throw CheckFailure(description: "An ad-hoc signed executable passed a Team ID requirement (\(team))")
            } catch RuntimePackVerificationError.invalidCodeSignature {
                // Expected.
            }
        }
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
                requiredRuntimeIDs: ["php-8.5"],
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
        try expect(report.results.contains(where: { $0.id == "config-php-8.5" && $0.severity == .info && $0.evidence.contains("not installed") }), "Doctor did not skip missing runtime configuration")
        // Only what the stack runs is checked: Nginx while Apache is selected,
        // and PHP versions no site uses, are left out.
        try expect(!report.results.contains(where: { $0.id == "config-nginx" || $0.id == "config-php-8.4" }), "Doctor checked configuration the stack does not use")
        try expect(report.results.contains(where: { $0.id == "config-apache" && $0.severity == .info && $0.evidence.contains("Syntax OK") }), "Doctor did not validate installed Apache configuration")
        try expect(report.results.contains(where: { $0.id == "port-3306" }), "Doctor omitted database port check")

        let missingHelperReport = DevStackDoctor().run(
            context: DiagnosticContext(paths: paths, helperInstalled: false, expectedHostnames: ["example.test"]),
            appVersion: "0.1.0"
        )
        try expect(missingHelperReport.results.contains(where: { $0.id == "privileged-helper" && $0.severity == .warning }), "Doctor omitted missing helper")
        try expect(missingHelperReport.results.contains(where: { $0.id == "ca-trust" && $0.severity == .warning }), "Doctor hid CA trust when the helper is missing")

        var optionalRuntime = executableManifest.runtime
        optionalRuntime.id = "mysql-5.7"
        optionalRuntime.kind = .mysql
        optionalRuntime.supportState = .endOfLife
        optionalRuntime.build = RuntimeBuildMetadata(buildSystem: "test", flags: [], feasibilityGate: "Legacy compatibility")
        let optionalReport = DevStackDoctor().run(context: DiagnosticContext(paths: paths, runtimeManifests: [optionalRuntime]), appVersion: "checks")
        try expect(optionalReport.results.contains { $0.id == "runtime-mysql-5.7" && $0.severity == .info }, "Doctor treated an intentionally omitted legacy runtime as a repair failure")
        let requiredReport = DevStackDoctor().run(context: DiagnosticContext(paths: paths, runtimeManifests: [optionalRuntime], requiredRuntimeIDs: ["mysql-5.7"]), appVersion: "checks")
        try expect(requiredReport.results.contains { $0.id == "runtime-mysql-5.7" && $0.severity == .error && $0.fix == .installRuntime("mysql-5.7") }, "Doctor failed to report a missing selected runtime")
        var unusedRuntime = executableManifest.runtime
        unusedRuntime.id = "nginx-1.30"
        unusedRuntime.kind = .nginx
        let unusedReport = DevStackDoctor().run(context: DiagnosticContext(paths: paths, runtimeManifests: [unusedRuntime], requiredRuntimeIDs: ["apache-2.4"]), appVersion: "checks")
        try expect(unusedReport.results.contains { $0.id == "runtime-nginx-1.30" && $0.severity == .info && $0.fix == nil }, "Doctor reported a runtime the stack does not use as a failure")
        // Servers an old copy left running can be stopped from Doctor; other
        // programs on a needed port are only named.
        let leftover = PortOwner(pid: 1, command: "httpd", executable: "/Users/me/.Trash/DevStack.app/Contents/Resources/Runtimes/apache-2.4/bin/httpd")
        let homebrew = PortOwner(pid: 2, command: "mysqld", executable: "/opt/homebrew/opt/mysql/bin/mysqld")
        try expect(leftover.isDevStackRuntime && !homebrew.isDevStackRuntime, "DevStack runtime servers are not told apart")
        let conflict = PortConflict(port: 8080, service: .apache, owner: leftover)
        try expect(conflict.description.hasPrefix("Port 8080 (Apache) is used by httpd (PID 1)") && conflict.recoveryAction.contains("Doctor"), "Port conflicts are not named")
        try expect(PortConflict(port: 3306, service: .mysql84, owner: homebrew).recoveryAction.contains("free port"), "Other programs get the wrong advice")
        let docker = PortOwner(pid: 3, command: "com.docker.backend", executable: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        try expect(docker.containerApplication == "Docker" && PortConflict(port: 3306, service: .mysql84, owner: docker).description.contains("Docker (com.docker.backend, PID 3): a container publishes it"), "Docker is not named")

        // With 80 and 443, the web server listens on internal ports the helper
        // forwards to; DevStack can move those, and the public ports stay.
        var forwarded = ServicePorts(webHTTP: 80, webHTTPS: 443)
        try expect(forwarded.webHTTPListen == 8080 && forwarded.proxyHTTPListen == 8082 && forwarded.isInternal(.webHTTP) && !forwarded.isInternal(.mysql), "Internal ports default to the fallbacks")
        forwarded.setInternalPort(18080, for: .webHTTP)
        try expect(forwarded.webHTTP == 80 && forwarded.webHTTPListen == 18080 && forwarded.forwardings.contains { $0.publicPort == 80 && $0.upstreamPort == 18080 }, "A moved internal port is not forwarded to")
        try expect(forwarded.publicOnly == ServicePorts(webHTTP: 80, webHTTPS: 443), "Settings compares internal ports")
        let roundTrip = try JSONDecoder().decode(ServicePorts.self, from: JSONEncoder().encode(forwarded))
        try expect(roundTrip == forwarded, "Internal ports are not saved")
        let older = try JSONDecoder().decode(ServicePorts.self, from: Data(#"{"webHTTP":80,"webHTTPS":443,"mysql":3306,"postgresql":5432,"mailpitSMTP":1025,"mailpitInbox":8025}"#.utf8))
        try expect(older.internalPorts == nil && older.webHTTPListen == 8080, "Configurations without internal ports do not load")
        try expect(ServicePorts().proxyHTTPListen == nil && ServicePorts().webHTTPListen == 8080 && !ServicePorts().isInternal(.webHTTP), "High ports listen directly")
        let otherHelper = HelperProcesses.Running(pid: 1, executable: "/Users/me/.Trash/DevStack.app/Contents/Library/LaunchServices/DevStackPrivilegedHelper")
        try expect(otherHelper.applicationPath == "/Users/me/.Trash/DevStack.app", "Helper app path is wrong")

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

        // The system LibreSSL in a runtime-shaped layout: the manager derives
        // OPENSSL_CONF from the binary's location, as for the bundled OpenSSL.
        let checkOpenSSL = temporary.appendingPathComponent("openssl-runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: checkOpenSSL.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: checkOpenSSL.appendingPathComponent("bin/openssl"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/openssl"))
        try AtomicFileWriter.write("[ req ]\ndistinguished_name = req_distinguished_name\n[ req_distinguished_name ]\n", to: checkOpenSSL.appendingPathComponent("ssl/openssl.cnf"), permissions: 0o644)
        let certificates = CertificateManager(paths: paths, openssl: checkOpenSSL.appendingPathComponent("bin/openssl"))
        try certificates.ensureLeafCertificate(for: "certificate-check.test")
        let firstLeaf = try Data(contentsOf: paths.certificate(for: "certificate-check.test"))
        try certificates.ensureLeafCertificate(for: "certificate-check.test")
        try expect(try Data(contentsOf: paths.certificate(for: "certificate-check.test")) == firstLeaf, "A valid leaf certificate was reissued")
        try FileManager.default.removeItem(at: certificates.caCertificate)
        try FileManager.default.removeItem(at: certificates.caPrivateKey)
        try certificates.ensureLeafCertificate(for: "certificate-check.test")
        let reissuedLeaf = paths.certificate(for: "certificate-check.test")
        try expect(try Data(contentsOf: reissuedLeaf) != firstLeaf && certificates.isIssuedByCurrentCA(reissuedLeaf), "A leaf signed by a replaced CA was kept")

        let logDirectory = temporary.appendingPathComponent("rotation-logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let busyLog = logDirectory.appendingPathComponent("site-busy-access.log")
        let quietLog = logDirectory.appendingPathComponent("apache-error.log")
        try Data(repeating: 0x41, count: 2_048).write(to: busyLog)
        try Data("quiet\n".utf8).write(to: quietLog)
        try Data("old archive".utf8).write(to: logDirectory.appendingPathComponent("site-busy-access.log.1"))
        let appendWriter = open(busyLog.path, O_WRONLY | O_APPEND)
        try expect(appendWriter >= 0, "Could not open the rotation fixture for appending")
        defer { close(appendWriter) }
        let rotatedLogs = LogFiles.rotateOversized(in: logDirectory, threshold: 1_024)
        try expect(rotatedLogs.map(\.lastPathComponent) == ["site-busy-access.log"], "Only the oversized log should rotate")
        try expect((try FileManager.default.attributesOfItem(atPath: busyLog.path + ".1")[.size] as? Int) == 2_048, "Rotation did not keep the previous contents")
        _ = Data("after\n".utf8).withUnsafeBytes { write(appendWriter, $0.baseAddress, $0.count) }
        try expect(try Data(contentsOf: busyLog) == Data("after\n".utf8), "A running writer left a gap after rotation")
        try expect(try Data(contentsOf: quietLog) == Data("quiet\n".utf8), "A small log was rotated")
        try Data((1...200).map { "line \($0)\n" }.joined().utf8).write(to: quietLog)
        let logTail = LogFiles.tail(of: quietLog, maximumBytes: 64) ?? ""
        try expect(logTail.hasPrefix("line ") && logTail.hasSuffix("line 200\n") && logTail.utf8.count <= 64, "Log tail did not start at a line boundary")
        try expect(LogFiles.tail(of: logDirectory.appendingPathComponent("missing.log")) == nil, "A missing log produced a tail")
        let logEntries = LogFiles.entries(fileNames: ["php-8.5-fpm.log", "site-localhost-error.log", "apache-error.log", "notes.txt", "site-gone-access.log"], sites: [defaultSite])
        try expect(logEntries.map(\.title) == ["Apache — errors", "PHP 8.5 — FPM", "localhost — errors", "site-gone-access.log"], "Log files were not named and grouped")
        try expect(logEntries.first?.service == .apache && LogFiles.primaryLog(for: .php85) == "php-8.5-fpm.log", "Log services were not resolved")
        try migrationChecks()
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

// MARK: - Loopback socket helpers

private func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return address
}

private func posixFailure(_ operation: String) -> CheckFailure {
    CheckFailure(description: "\(operation) failed: \(String(cString: strerror(errno)))")
}

/// A loopback port that was free a moment ago.
private func ephemeralLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw posixFailure("socket") }
    defer { close(descriptor) }
    var address = loopbackAddress(port: 0)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0 else { throw posixFailure("bind") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard named == 0 else { throw posixFailure("getsockname") }
    return UInt16(bigEndian: address.sin_port)
}

private func listenLoopback(port: UInt16) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw posixFailure("socket") }
    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = loopbackAddress(port: port)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(descriptor, 4) == 0 else {
        close(descriptor)
        throw posixFailure("listen")
    }
    return descriptor
}

private func connectLoopback(port: UInt16) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw posixFailure("socket") }
    var address = loopbackAddress(port: port)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else {
        close(descriptor)
        throw posixFailure("connect")
    }
    return descriptor
}

private func acceptLoopback(_ listener: Int32, timeout: TimeInterval) throws -> Int32 {
    var request = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&request, 1, Int32(timeout * 1_000)) == 1 else { throw CheckFailure(description: "No connection arrived within \(timeout) seconds") }
    let descriptor = accept(listener, nil, nil)
    guard descriptor >= 0 else { throw posixFailure("accept") }
    return descriptor
}

/// Reads until `marker` has arrived, the peer closes, or the timeout passes.
private func readLoopback(_ descriptor: Int32, until marker: Data, timeout: TimeInterval) -> (data: Data, closed: Bool) {
    var received = Data()
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while Date() < deadline, received.range(of: marker) == nil {
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1_000))
        guard poll(&request, 1, remaining) == 1 else { break }
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count <= 0 { return (received, true) }
        received.append(contentsOf: buffer[0..<count])
    }
    return (received, false)
}

private final class ProgressTotal: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func set(_ value: Int64) { lock.lock(); bytes = value; lock.unlock() }
}

// MARK: - Importing from other apps

private func migrationChecks() throws {
    let old = try JSONDecoder().decode(AppConfiguration.self, from: Data(#"{"schemaVersion":5}"#.utf8))
    try expect(old.mysql(.mysql84).rootPassword == "root" && old.mysql(.mysql84).sqlMode == nil, "Existing installations lost root/root")
    var configured = AppConfiguration()
    configured.mysqlSettings["mysql-8.4"] = MySQLSettings(rootPassword: "", sqlMode: "STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER", nativePassword: true)
    try expect(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configured)) == configured, "MySQL settings do not survive relaunch")
    try expect(MySQLSettings.sqlMode("STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER,SIMULTANEOUS_ASSIGNMENT", for: .mysql84) == "STRICT_TRANS_TABLES", "MariaDB-only SQL modes reached MySQL 8.4")
    try expect(MySQLSettings.sqlMode("NO_AUTO_CREATE_USER", for: .mysql57) == "NO_AUTO_CREATE_USER", "MySQL 5.7 lost a mode it knows")
    try expect(MySQLSettings.isUsablePassword("") && MySQLSettings.isUsablePassword("root") && !MySQLSettings.isUsablePassword("a'b") && !MySQLSettings.isUsablePassword("a$b"),
               "Root password character rules are wrong")

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("devstack-migration-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let paths = DevStackPaths(applicationSupport: scratch.appendingPathComponent("support"), logs: scratch.appendingPathComponent("logs"), defaultSiteRoot: scratch.appendingPathComponent("localhost"))
    let renderer = ConfigurationRenderer(paths: paths, runtimeRoot: scratch, mysqlSettings: configured.mysqlSettings, selectedDatabase: .mysql84)
    let mysqlConfiguration = renderer.mysqlConfiguration(engine: .mysql84, baseDirectory: scratch)
    try expect(mysqlConfiguration.contains("sql-mode=\"STRICT_TRANS_TABLES\"") && mysqlConfiguration.contains("mysql-native-password=ON"), "MySQL settings were not rendered")
    try expect(!renderer.mysqlConfiguration(engine: .mysql57, baseDirectory: scratch).contains("sql-mode"), "MySQL 5.7 took 8.4's settings")
    let phpMyAdmin = try renderer.phpMyAdminConfiguration(cookieSecret: String(repeating: "a", count: 32))
    try expect(phpMyAdmin.contains("['password'] = '';") && phpMyAdmin.contains("['AllowNoPassword'] = true;"), "phpMyAdmin does not sign in without a password")

    // php.ini, my.cnf and Apache files.
    let ini = INIFile.settings("[client]\nport=3306\n[mysqld]\n; comment\nuser=mysql\ndatadir = \"/data dir\"\nskip-networking\nport=3306 # trailing\n", section: "mysqld")
    try expect(ini.map(\.key) == ["user", "datadir", "skip-networking", "port"] && ini[1].value == "/data dir" && ini[3].value == "3306", "my.cnf was misread")
    let parsed = ApacheConfiguration.parse("""
        Define SITES /Users/me/Sites
        # Alias /commented "/nowhere"
        Alias /one "${SITES}/one"
        Alias "/two words" \\
            "/Users/me/Two Words/public"
        <VirtualHost *:80 *:8081>
            ServerName http://Api.Test:80
            DocumentRoot relative/root
            Alias /docs /Users/me/docs
        </VirtualHost>
        """, serverRoot: URL(fileURLWithPath: "/srv"))
    try expect(parsed.aliases == [ApacheAlias(path: "/one", directory: "/Users/me/Sites/one"), ApacheAlias(path: "/two words", directory: "/Users/me/Two Words/public")],
               "Alias lines were misread: \(parsed.aliases)")
    try expect(parsed.virtualHosts == [ApacheVirtualHost(serverName: "api.test", documentRoot: "/srv/relative/root", ports: ["80", "8081"],
                                                         pathAliases: [ApacheAlias(path: "/docs", directory: "/Users/me/docs")])],
               "A virtual host was misread: \(parsed.virtualHosts)")
    let hosts = ApacheConfiguration.virtualHosts("""
        <VirtualHost *:80>
            ServerName dummy-host.example.com
            DocumentRoot "/docs/dummy"
        </VirtualHost>
        <VirtualHost *:80>
            ServerName Shop.Local:80
            ServerAlias www.shop.local
            DocumentRoot "/htdocs/shop/public"
        </VirtualHost>
        # <VirtualHost *:80>
        <VirtualHost *:443>
            ServerName shop.local
            DocumentRoot "/htdocs/shop/public"
        </VirtualHost>
        """)
    try expect(hosts == [ApacheVirtualHost(serverName: "shop.local", aliases: ["www.shop.local"], documentRoot: "/htdocs/shop/public", ports: ["80"])],
               "Virtual hosts were misread: \(hosts)")

    // An installation moved after setup still names its old ServerRoot.
    let moved = scratch.appendingPathComponent("XAMPP82/xamppfiles")
    try FileManager.default.createDirectory(at: moved.appendingPathComponent("etc"), withIntermediateDirectories: true)
    try Data("""
        ServerRoot "/Applications/XAMPP/xamppfiles"
        DocumentRoot "/Applications/XAMPP/xamppfiles/htdocs"
        Alias /phpmyadmin "/Applications/XAMPP/xamppfiles/phpmyadmin"
        Alias /mine "/Users/me/mine"
        """.utf8).write(to: moved.appendingPathComponent("etc/httpd.conf"))
    let movedSetup = ApacheConfiguration.load(moved.appendingPathComponent("etc/httpd.conf"), serverRoot: moved)
    try expect(movedSetup.documentRoot == moved.appendingPathComponent("htdocs").path
               && movedSetup.aliases.map(\.directory) == [moved.appendingPathComponent("phpmyadmin").path, "/Users/me/mine"],
               "A moved installation's paths were not read as its own: \(movedSetup.documentRoot ?? "-") \(movedSetup.aliases)")

    // A small XAMPP installation.
    let applications = scratch.appendingPathComponent("Applications")
    let root = applications.appendingPathComponent("XAMPP/xamppfiles")
    let htdocs = root.appendingPathComponent("htdocs")
    let elsewhere = scratch.appendingPathComponent("Elsewhere")
    let files: [String: String] = [
        "xampp": "", "properties.ini": "[General]\nbase_stack_version=8.2.4-0\n",
        "etc/httpd.conf": """
            ServerRoot "\(root.path)"
            DocumentRoot "\(htdocs.path)"
            Include etc/extra/httpd-vhosts.conf
            IncludeOptional etc/extra/custom/*.conf
            Include etc/extra/httpd-xampp.conf
            IncludeOptional etc/extra/missing/*.conf
            """,
        "etc/extra/httpd-xampp.conf": "Alias /phpmyadmin \"\(root.path)/phpmyadmin\"\nAliasMatch ^/manual(.*)$ \"\(root.path)/manual$1\"\n",
        "etc/extra/httpd-vhosts.conf": """
            <VirtualHost *:80>
                ServerName localhost
                DocumentRoot "\(htdocs.path)"
                Alias /desk1 "\(elsewhere.path)/Desktop/desk1"
            </VirtualHost>
            <VirtualHost *:80>
                ServerName crm.local
                DocumentRoot "\(htdocs.path)/crm/public"
            </VirtualHost>
            <VirtualHost *:80>
                ServerName api.dev
                DocumentRoot "\(scratch.path)/api/public"
            </VirtualHost>
            """,
        "etc/extra/custom/projects.conf": """
            Define PROJECTS "\(elsewhere.path)/Projects"
            Alias /desk2 \\
                "${PROJECTS}/desk2"
            Alias /shopcode "${PROJECTS}/shop/public"
            Alias /gone "\(elsewhere.path)/Gone"
            Alias /locked "\(elsewhere.path)/Locked"
            AliasMatch ^/x(.*)$ "/tmp/x$1"
            <VirtualHost *:80 *:8081>
                ServerName shop.lan
                ServerAlias www.shop.lan
                DocumentRoot "${PROJECTS}/shop/public"
            </VirtualHost>
            """,
        "../../../Elsewhere/Desktop/desk1/index.php": "<?php", "../../../Elsewhere/Projects/desk2/index.php": "<?php",
        "../../../Elsewhere/Projects/shop/artisan": "", "../../../Elsewhere/Projects/shop/public/index.php": "<?php",
        "../../../Elsewhere/Locked/index.php": "<?php",
        "etc/my.cnf": "[mysqld]\ndatadir=\(root.path)/var/mysql\n",
        "etc/php.ini": "memory_limit=1G\nupload_max_filesize=8M\nmax_execution_time=0\n",
        "htdocs/index.php": "<?php header('Location: '.$uri.'/dashboard/');",
        "htdocs/dashboard/index.html": "", "htdocs/favicon.ico": "", "htdocs/notes.php": "<?php",
        "htdocs/crm/index.php": "<?php", "htdocs/crm/public/index.php": "<?php",
        "htdocs/shop kopyası 2/index.php": "<?php", "htdocs/blog/wp-config.php": "<?php define( 'DB_NAME', 'blog' );",
        "htdocs/app/artisan": "", "htdocs/app/public/index.php": "<?php", "htdocs/static/index.html": "<html>",
        "var/mysql/ibdata1": "data", "var/mysql/shop/products.ibd": "", "var/mysql/my@002ddb/t.frm": "",
        "var/mysql/mysql/user.MAD": "", "var/mysql/phpmyadmin/pma.frm": "", "var/mysql/test/db.opt": "",
        "../../../api/public/index.php": "<?php"
    ]
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    let installations = XAMPPInstallation.find(applications: applications)
    try expect(installations.count == 1 && installations[0].version == "8.2.4" && installations[0].phpVersion == "8.2", "XAMPP was not found")
    let locked = elsewhere.appendingPathComponent("Locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    let inventory = XAMPPScanner.scan(installations[0])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    func project(_ name: String) -> MigrationProject? { inventory.projects.first { $0.name == name } }
    try expect(project("desk1")?.kind == .external && project("desk1")?.localhostPath == "desk1" && project("desk1")?.readable == true,
               "An Alias inside the localhost host was missed")
    try expect(project("desk2")?.localhostPath == "desk2", "An Alias in an included file was missed")
    try expect(project("shop")?.virtualHost == "shop.lan" && project("shop")?.localhostPath == "shopcode" && project("shop")?.webRoot == "public"
               && project("shop")?.framework == .laravel, "An Alias and a host on one folder were not one project")
    try expect(project("shop")?.originalURLs.contains("http://localhost/shopcode") == true && project("shop")?.originalURLs.contains("http://shop.lan") == true,
               "An Alias project's XAMPP addresses were misread")
    try expect(project("Locked")?.readable == false, "A folder DevStack can't read was not marked")
    try expect(project("phpmyadmin") == nil && project("Gone") == nil && project("manual") == nil, "XAMPP's own or missing folders became projects")
    for expected in ["/gone", "www.shop.lan", "8081", "AliasMatch ^/x"] {
        try expect(inventory.notes.contains { $0.contains(expected) }, "The notes do not mention \(expected): \(inventory.notes)")
    }
    try expect(!inventory.notes.contains { $0.contains("manual") }, "XAMPP's own AliasMatch was reported")
    try expect(MigrationNaming.hostname(for: project("shop")!, keepDomains: true, taken: []) == "shop.lan"
               && MigrationNaming.hostname(for: project("shop")!, taken: []) == "shop.localhost"
               && MigrationNaming.hostname(for: project("crm")!, keepDomains: true, taken: []) == "crm.localhost"
               && MigrationNaming.hostname(for: project("shop")!, keepDomains: true, taken: ["shop.lan"]) == "shop-2.lan",
               "Domains were not kept, or .local was kept")
    try expect(Set(inventory.skippedDefaults) == ["dashboard", "favicon.ico", "index.php"], "XAMPP's own pages were imported: \(inventory.skippedDefaults)")
    try expect(project("app")?.framework == .laravel && project("app")?.webRoot == "public", "Laravel's web root was missed")
    try expect(project("blog")?.framework == .wordpress && project("static")?.framework == .staticSite, "Frameworks were misread")
    try expect(project("crm")?.virtualHost == "crm.local" && project("crm")?.webRoot == "public", "A virtual host in htdocs was not attached to its folder")
    try expect(project("api")?.kind == .external && project("api")?.webRoot == "public" && project("api")?.virtualHost == "api.dev", "A virtual host outside htdocs was missed")
    try expect(inventory.projects.contains { $0.kind == .looseFiles(["notes.php"]) }, "Loose files in htdocs were missed")
    try expect(inventory.databases.map(\.name) == ["my-db", "shop", "test"] && inventory.databases.last?.isSample == true, "Databases were misread: \(inventory.databases.map(\.name))")
    try expect(project("shop kopyası 2")?.originalURLs.first == "http://localhost/shop%20kopyas%C4%B1%202", "A folder's XAMPP address was misread")

    try expect(MigrationNaming.slug("atasarim-v2 kopyası 10") == "atasarim-v2-kopyasi-10" && MigrationNaming.slug("Çağrı Ödeme!") == "cagri-odeme", "Folder names were not turned into hostnames")
    try expect(MigrationNaming.hostname(for: project("crm")!, taken: []) == "crm.localhost", ".local hosts did not become .localhost")
    try expect(MigrationNaming.hostname(for: project("app")!, taken: ["app.localhost"]) == "app-2.localhost", "Hostnames were not made unique")
    var tested = project("crm")!
    tested.virtualHost = "www.crm.test"
    try expect(MigrationNaming.hostname(for: tested, taken: []) == "www.crm.test", ".test hosts were renamed")
    try expect(MigrationNaming.databaseName("shop", taken: ["shop", "shop_xampp"]) == "shop_xampp2", "Database names clashed")
    try expect(MigrationNaming.folder(named: "crm", in: htdocs).lastPathComponent == "crm-xampp", "Folder names clashed")
    try expect(DatabaseFolderName.decode("my@002ddb") == "my-db" && DatabaseFolderName.encode("my-db") == "my@002ddb", "Database folder names were misread")
    let available = ["php-7.4", "php-8.4", "php-8.5"]
    try expect(PHPVersionMapping.runtimeID(for: "8.2", available: available) == "php-8.4" && PHPVersionMapping.runtimeID(for: "5.6", available: available) == "php-7.4"
               && PHPVersionMapping.runtimeID(for: "8.5", available: available) == "php-8.5" && PHPVersionMapping.runtimeID(for: "9.1", available: available) == "php-8.5",
               "PHP versions were mapped wrongly")
    let limits = PHPSettingsImport.overrides(fromPHPINI: "memory_limit=1G\nupload_max_filesize=8M\nmax_execution_time=0\npost_max_size=-1\n")
    try expect(limits.memoryLimit == "1G" && limits.uploadMaxFilesize == "64M" && limits.maxExecutionTime == 0 && limits.postMaxSize == "-1", "XAMPP's PHP limits were not carried over: \(limits)")
    try expect(MachO.architectures(of: URL(fileURLWithPath: "/usr/bin/true")).contains("arm64"), "Executable architectures were misread")

    try expect(MariaDBVersion.majorMinor("10.1.8-MariaDB") == "10.1" && MariaDBVersion.majorMinor("10.4.28-MariaDB-log\n") == "10.4"
               && MariaDBVersion.majorMinor("garbage") == nil, "MariaDB versions were misread")
    let growing = scratch.appendingPathComponent("growing.sql")
    FileManager.default.createFile(atPath: growing.path, contents: nil)
    _ = FileSize.of(growing)
    _ = try? growing.resourceValues(forKeys: [.fileSizeKey])
    try Data(count: 4_096).write(to: growing)
    try expect(FileSize.of(growing) == 4_096, "A growing export kept its first, cached size")

    // Copying.
    let copy = scratch.appendingPathComponent("copy")
    try FileManager.default.createSymbolicLink(at: htdocs.appendingPathComponent("app/link"), withDestinationURL: htdocs.appendingPathComponent("app/artisan"))
    let failures = try ProjectCopier.copyFolder(htdocs.appendingPathComponent("app"), to: copy, totals: (3, 0), isCancelled: { false }, progress: { _ in })
    try expect(failures.isEmpty && FileManager.default.fileExists(atPath: copy.appendingPathComponent("public/index.php").path)
               && (try? FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("link").path)) != nil, "A project was not copied whole")
    do {
        _ = try ProjectCopier.copyFolder(htdocs.appendingPathComponent("crm"), to: scratch.appendingPathComponent("cancelled"), totals: (2, 0), isCancelled: { true }, progress: { _ in })
        throw CheckFailure(description: "A cancelled copy finished")
    } catch is CancellationError {
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.hasPrefix(".devstack-import") || $0 == "cancelled" }
        try expect(leftovers.isEmpty, "A cancelled copy left files behind")
    }

    // Converting MariaDB exports.
    func converted(_ lines: [String], _ target: DatabaseEngine = .mysql84) -> [String] {
        var state = MariaDBDumpConverter.State()
        return lines.compactMap { MariaDBDumpConverter.convert(line: $0, state: &state, target: target) }
    }
    try expect(converted(["/*M!999999\\- enable the sandbox mode */ "]).isEmpty, "MariaDB's sandbox line reached MySQL")
    let table = [
        "CREATE TABLE `products` (",
        "  `id` int(11) NOT NULL AUTO_INCREMENT,",
        "  `description` text DEFAULT 'it''s none',",
        "  `notes` text DEFAULT NULL,",
        "  `sku` char(36) DEFAULT uuid(),",
        "  `updated` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),",
        "  `tax` decimal(10,2) GENERATED ALWAYS AS (`price` * 1.2) PERSISTENT,",
        "  `id2` uuid DEFAULT NULL,",
        "  `title` varchar(50) COLLATE utf8mb4_unicode_nopad_ci DEFAULT NULL,",
        "  KEY `t` (`title`) IGNORED,",
        "  CONSTRAINT `1` FOREIGN KEY (`id`) REFERENCES `x` (`id`),",
        "  CONSTRAINT `CONSTRAINT_1` CHECK (`id` >= 0)",
        ") ENGINE=Aria AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci PAGE_CHECKSUM=1 TRANSACTIONAL=1;"
    ]
    let mysql84 = converted(table)
    try expect(mysql84[2] == "  `description` text DEFAULT ('it''s none')," && mysql84[3] == table[3], "TEXT defaults were not made expressions: \(mysql84[2])")
    try expect(mysql84[4] == "  `sku` char(36) DEFAULT (uuid()),", "Function defaults were not made expressions: \(mysql84[4])")
    try expect(mysql84[5] == table[5], "CURRENT_TIMESTAMP defaults changed")
    try expect(mysql84[6].hasSuffix("STORED,") && mysql84[7] == "  `id2` char(36) DEFAULT NULL,", "MariaDB column types survived")
    try expect(mysql84[8].contains("utf8mb4_unicode_ci") && mysql84[9] == "  KEY `t` (`title`),", "MariaDB collations or index options survived")
    try expect(mysql84[10] == "  FOREIGN KEY (`id`) REFERENCES `x` (`id`)," && mysql84[11] == "  CHECK (`id` >= 0)", "Constraint names that clash in MySQL survived")
    try expect(mysql84[12] == ") ENGINE=InnoDB AUTO_INCREMENT=4 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;", "Aria table options survived: \(mysql84[12])")
    let mysql57 = converted(table, .mysql57)
    try expect(mysql57[2] == "  `description` text," && mysql57[4] == "  `sku` char(36),", "MySQL 5.7 kept defaults it cannot hold")
    try expect(mysql57[12].contains("utf8mb4_unicode_520_ci"), "MySQL 5.7 got an 8.0 collation")
    try expect(converted(["/*!50013 DEFINER=`app`@`%` SQL SECURITY DEFINER */"]) == ["/*!50013 DEFINER=CURRENT_USER SQL SECURITY DEFINER */"], "Definers were kept")
    try expect(converted(["/*!50003 SET sql_mode = 'STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER' */ ;"]) == ["/*!50003 SET sql_mode = 'STRICT_TRANS_TABLES' */ ;"], "Routine SQL modes were not filtered")
    try expect(converted(["DROP SEQUENCE IF EXISTS `s`;", "CREATE SEQUENCE `s` start with 1", "  cache 1000;", "DO SETVAL(`s`, 1, 0);", "SELECT 1;"]) == ["SELECT 1;"], "Sequences reached MySQL")
    try expect(converted(["/*!100101 SET x=1 */;"]) == ["/*M!100101 SET x=1 */;"], "MariaDB version comments would run in MySQL")
    try expect(converted(["SET NAMES utf8mb3;"], .mysql57) == ["SET NAMES utf8;"], "MySQL 5.7 got utf8mb3")

    // Rows pass through, except values of generated columns.
    var state = MariaDBDumpConverter.State()
    for line in table { _ = MariaDBDumpConverter.convert(line: line, state: &state, target: .mysql84) }
    let rows = ["INSERT INTO `products` VALUES", "(1,'a, (b)','it''s',NULL,NOW(),3.60,NULL,'DEFINER=`x`@`y`'),", "(2,'\\\\',0x00,'y','2024',1.20,NULL,NULL);", "INSERT INTO `other` VALUES (1,'DEFINER=`x`@`y` ENGINE=Aria');"]
    let output = rows.map { String(decoding: MariaDBDumpConverter.convert(lineData: Data($0.utf8), state: &state, target: .mysql84, renamed: nil) ?? Data(), as: UTF8.self) }
    try expect(output[0] == rows[0] && output[1] == "(1,'a, (b)','it''s',NULL,NOW(),DEFAULT,NULL,'DEFINER=`x`@`y`'),"
               && output[2] == "(2,'\\\\',0x00,'y','2024',DEFAULT,NULL,NULL);" && output[3] == rows[3], "Rows were changed: \(output)")

    let dumpFile = scratch.appendingPathComponent("dump.sql")
    try Data("SELECT 1;\nCREATE TABLE `x` (\n  `a` int\n);\n".utf8).write(to: dumpFile)
    if case .statementFailed(let message, let line, let statement) = DatabaseImporter.failure("mysql: [Warning] x\nERROR 1064 (42000) at line 2: You have an error", file: dumpFile) {
        try expect(message == "You have an error" && line == 2 && statement == "CREATE TABLE `x` (", "An import error was misread")
    } else { throw CheckFailure(description: "An import error was misread") }

    let before = DatabaseSnapshot(tables: ["a": 2, "b": 1], views: 1, routines: 2)
    try expect(before.differences(from: DatabaseSnapshot(tables: ["a": 2, "b": 1], views: 1, routines: 2)).isEmpty
               && before.differences(from: DatabaseSnapshot(tables: ["a": 1], views: 1, routines: 1)) == ["Table a has 1 of 2 rows", "Table b is missing", "1 of 2 procedures and functions are missing"],
               "Database differences were misreported")
    let account = MariaDBAccount(user: "app", host: "localhost", passwordHash: "*ABC", globalPrivileges: [], databasePrivileges: ["shop": ["SELECT", "INSERT"], "gone": ["ALL PRIVILEGES"]])
    try expect(MariaDBAccounts.statements(for: account, renamed: ["shop": "shop_xampp"]) == [
        "CREATE USER IF NOT EXISTS 'app'@'localhost' IDENTIFIED WITH mysql_native_password AS '*ABC'",
        "GRANT SELECT, INSERT ON `shop_xampp`.* TO 'app'@'localhost'"
    ], "Accounts were recreated wrongly")
    try expect(MariaDBAccounts.statements(for: MariaDBAccount(user: "s", host: "%", passwordHash: nil), renamed: [:]).isEmpty, "An account with an unknown sign-in was recreated")

    // Project settings and WordPress addresses.
    let wordpress = scratch.appendingPathComponent("wp")
    try FileManager.default.createDirectory(at: wordpress, withIntermediateDirectories: true)
    try Data("<?php\ndefine( 'DB_NAME', 'blog' );\ndefine('DB_HOST', '127.0.0.1:3306');\ndefine('WP_HOME', 'http://localhost/wp');\n$table_prefix = 'site_';\n".utf8).write(to: wordpress.appendingPathComponent("wp-config.php"))
    let settings = ProjectSettingsUpdater.wordPressSettings(in: wordpress)
    try expect(settings?.database == "blog" && settings?.tablePrefix == "site_", "wp-config.php was misread")
    let changes = try ProjectSettingsUpdater.update(project: wordpress, renamedDatabases: ["blog": "blog_xampp"], mysqlPort: 3307, newURL: "https://wp.localhost", oldURLs: ["http://localhost/wp"])
    let updated = try String(contentsOf: wordpress.appendingPathComponent("wp-config.php"), encoding: .utf8)
    try expect(changes.count == 1 && updated.contains("'DB_NAME', 'blog_xampp'") && updated.contains("'DB_HOST', '127.0.0.1:3307'") && updated.contains("'WP_HOME', 'https://wp.localhost'")
               && FileManager.default.fileExists(atPath: wordpress.appendingPathComponent("wp-config.php.xampp-backup").path), "wp-config.php was not updated: \(updated)")
    try expect(try ProjectSettingsUpdater.update(project: wordpress, renamedDatabases: [:], mysqlPort: 3307, newURL: "https://wp.localhost", oldURLs: []).isEmpty, "An up-to-date project was changed")
    let pairs = WordPressAddressUpdate.pairs(oldURLs: ["http://localhost/wp/", "http://localhost/wp"], newURL: "https://wp.localhost")
    try expect(pairs.count == 2 && pairs[0] == ["http:\\/\\/localhost\\/wp", "https:\\/\\/wp.localhost"], "WordPress address pairs are wrong: \(pairs)")
}
