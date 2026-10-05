import Foundation

public struct DiagnosticContext: Sendable {
    public var paths: DevStackPaths
    public var runtimeManifests: [RuntimeManifest]
    public var applicationURL: URL?
    public var helperInstalled: Bool
    public var helperStatus: PrivilegedHelperStatus?
    public var certificateTrusted: Bool
    public var expectedHostnames: [String]
    public var serviceStates: [ServiceState]
    public var requiredRuntimeIDs: Set<String>
    public var selectedDatabase: DatabaseEngine
    public var selectedPostgreSQL: PostgreSQLEngine
    public var selectedWebServer: WebServer
    public var ports: ServicePorts
    public var localNetworkAccess: Bool

    public init(
        paths: DevStackPaths,
        runtimeManifests: [RuntimeManifest] = [],
        applicationURL: URL? = nil,
        helperInstalled: Bool = false,
        helperStatus: PrivilegedHelperStatus? = nil,
        certificateTrusted: Bool = false,
        expectedHostnames: [String] = [],
        serviceStates: [ServiceState] = [],
        requiredRuntimeIDs: Set<String> = [],
        selectedDatabase: DatabaseEngine = .mysql84,
        selectedPostgreSQL: PostgreSQLEngine = .none,
        selectedWebServer: WebServer = .apache,
        ports: ServicePorts = ServicePorts(),
        localNetworkAccess: Bool = false
    ) {
        self.paths = paths
        self.runtimeManifests = runtimeManifests
        self.applicationURL = applicationURL
        self.helperInstalled = helperInstalled
        self.helperStatus = helperStatus
        self.certificateTrusted = certificateTrusted
        self.expectedHostnames = expectedHostnames
        self.serviceStates = serviceStates
        self.selectedDatabase = selectedDatabase
        self.selectedPostgreSQL = selectedPostgreSQL
        self.selectedWebServer = selectedWebServer
        self.ports = ports
        self.localNetworkAccess = localNetworkAccess
        self.requiredRuntimeIDs = requiredRuntimeIDs
    }
}

public struct DevStackDoctor: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = .init()) {
        self.runner = runner
    }

    public func run(context: DiagnosticContext, appVersion: String, progress: (@Sendable (String) -> Void)? = nil) -> DiagnosticReport {
        progress?("Checking this Mac and local directories…")
        var results: [DiagnosticResult] = []
        let architecture = ProcessInfo.processInfo.machineArchitecture
        results.append(.init(
            id: "architecture",
            title: "Apple Silicon architecture",
            severity: architecture == "arm64" ? .info : .error,
            evidence: architecture,
            remediation: architecture == "arm64" ? nil : "DevStack requires an Apple Silicon Mac."
        ))

        results.append(directoryResult(context.paths.applicationSupport, id: "application-support"))
        results.append(directoryResult(context.paths.logs, id: "logs"))
        results.append(helperResult(context))
        results.append(contentsOf: otherHelperResults(context))
        results.append(caTrustResult(context))
        results.append(contentsOf: helperStatusResults(context.helperStatus, context: context))
        results.append(contentsOf: serviceReadinessResults(context.serviceStates))
        progress?("Checking ports and local domain mappings…")
        results.append(contentsOf: portResults(context: context))
        results.append(hostsResult(expected: context.expectedHostnames))
        results.append(contentsOf: runtimeResults(context.runtimeManifests, paths: context.paths, required: context.requiredRuntimeIDs, progress: progress))
        progress?("Validating configuration and certificates…")
        results.append(contentsOf: configurationResults(context))
        results.append(contentsOf: certificateResults(context))
        results.append(databaseResult(context))
        results.append(postgreSQLResult(context))
        results.append(diskResult(context.paths.applicationSupport))

        if let applicationURL = context.applicationURL {
            progress?("Verifying the application signature…")
            results.append(codeSignatureResult(applicationURL))
        }
        return DiagnosticReport(appVersion: appVersion, results: results)
    }

    private func directoryResult(_ url: URL, id: String) -> DiagnosticResult {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".doctor-\(UUID().uuidString)")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return .init(id: id, title: url.lastPathComponent, severity: .info, evidence: "Writable: \(redact(url.path))")
        } catch {
            return .init(id: id, title: url.lastPathComponent, severity: .error, evidence: error.localizedDescription, remediation: "Repair directory ownership and permissions.")
        }
    }

    private func helperResult(_ context: DiagnosticContext) -> DiagnosticResult {
        let severity: DiagnosticSeverity
        let evidence: String
        switch (context.helperStatus, context.helperInstalled) {
        case (let status?, _):
            severity = .info
            evidence = "Authorized and responding (version \(status.version)); host mappings \(status.hostMappingsInstalled ? "installed" : "missing")."
        case (nil, true):
            severity = .warning
            evidence = "Registered but did not return authenticated status."
        case (nil, false):
            severity = .warning
            evidence = "Unavailable. Services can run on high ports; standard ports and system host mappings require an authorized signed helper."
        }
        return .init(
            id: "privileged-helper",
            title: "Privileged helper",
            severity: severity,
            evidence: evidence,
            remediation: severity == .info ? nil : "Set up or repair the DevStack helper.",
            fix: severity == .info ? nil : .repairHelper
        )
    }

    /// A helper running from another DevStack copy holds the helper's launchd
    /// label and the privileged ports, so this copy's helper cannot start; it
    /// comes back at every boot while that copy exists.
    private func otherHelperResults(_ context: DiagnosticContext) -> [DiagnosticResult] {
        guard let application = context.applicationURL else { return [] }
        return HelperProcesses.others(than: application, runner: runner).map { helper in
            let copy = helper.applicationPath ?? helper.executable
            let team = HelperProcesses.teamIdentifier(ofApplicationAt: copy)
            return .init(
                id: "other-helper-\(helper.pid)",
                title: "Helper from another DevStack copy",
                severity: .error,
                evidence: "A DevStack helper runs from \(copy)\(team.map { ", signed by team \($0)" } ?? ""). It holds the helper's name and the privileged ports, so this copy's helper cannot start, and macOS starts it again at every boot while that copy exists.",
                remediation: "Remove stops it, moves that copy to the Trash and sets up this copy's helper. Empty the Trash afterwards.",
                fix: .removeOtherHelper(executable: helper.executable)
            )
        }
    }

    private func helperStatusResults(_ status: PrivilegedHelperStatus?, context: DiagnosticContext) -> [DiagnosticResult] {
        guard let status else { return [] }
        let forwardingNeedsHelper = !context.ports.forwardings.isEmpty
        return [
            .init(
                id: "helper-port-forwarding",
                title: "Privileged port forwarding",
                severity: status.portForwardingEnabled ? .info : (forwardingNeedsHelper ? .warning : .info),
                evidence: status.portForwardingEnabled ? "Loopback forwarding is enabled." : (forwardingNeedsHelper ? "Privileged ports configured but no forwarder is active." : "No privileged ports configured; high ports work without forwarding."),
                remediation: status.portForwardingEnabled ? nil : (forwardingNeedsHelper ? "Start DevStack to enable its loopback-only forwarders." : nil)
            ),
            .init(
                id: "local-dns",
                title: "Local DNS server",
                severity: status.dnsFailure != nil ? .error : (status.dnsEnabled ? .info : (context.localNetworkAccess ? .warning : .info)),
                evidence: status.dnsFailure ?? (status.dnsEnabled
                    ? "Answering DevStack hostnames with \(status.dnsAnswerAddress ?? "the LAN address") over UDP+TCP; other queries are forwarded to the system resolvers."
                    : "Disabled."),
                remediation: status.dnsFailure ?? (status.dnsEnabled ? nil : (context.localNetworkAccess
                    ? "Local network access is enabled in Settings but the helper is not answering on port 53."
                    : "Enable Local network access in Settings to serve DevStack hostnames to phones."))
            )
        ]
    }

    /// CA trust is independent of the helper: HTTPS on .localhost works
    /// without it, so the result is reported either way.
    private func caTrustResult(_ context: DiagnosticContext) -> DiagnosticResult {
        .init(
            id: "ca-trust",
            title: "Local CA trust",
            severity: context.certificateTrusted ? .info : .warning,
            evidence: context.certificateTrusted ? "The public DevStack CA is trusted for this user." : "The DevStack CA is not trusted for this user.",
            remediation: context.certificateTrusted ? nil : "Trust the DevStack CA; macOS asks for your login password.",
            fix: context.certificateTrusted ? nil : .trustCertificate
        )
    }

    private func serviceReadinessResults(_ states: [ServiceState]) -> [DiagnosticResult] {
        states.sorted { $0.service.rawValue < $1.service.rawValue }.map { state in
            let severity: DiagnosticSeverity
            let evidence: String
            let remediation: String?
            switch state.phase {
            case .running:
                severity = .info
                evidence = "Running\(state.pid.map { " (PID \($0))" } ?? "")"
                remediation = nil
            case .stopped:
                severity = .info
                evidence = "Stopped"
                remediation = nil
            case .starting, .stopping:
                severity = .warning
                evidence = state.phase.rawValue.capitalized
                remediation = "Wait for the current service transition to complete."
            case .failed:
                severity = .error
                evidence = state.failure?.message ?? "Failed"
                remediation = state.failure?.recoveryAction ?? "Review the service log and retry."
            }
            return .init(
                id: "service-\(state.service.rawValue)",
                title: "Service \(state.service.rawValue)",
                severity: severity,
                evidence: evidence,
                remediation: remediation,
                containsSensitiveData: state.failure?.logExcerpt != nil
            )
        }
    }

    private func portResults(context: DiagnosticContext) -> [DiagnosticResult] {
        let selectedDatabaseService: ServiceKind = context.selectedDatabase == .mysql57 ? .mysql57 : .mysql84
        let webService = context.selectedWebServer.service
        let ports = context.ports
        // Only the ports of services in the stack; a database left out of it
        // may run elsewhere on its usual port.
        var owners: [(UInt16, ServiceKind)] = [
            (ports.webHTTPListen, webService), (ports.webHTTPSListen, webService),
            (ports.mailpitSMTPListen, .mailpit), (ports.mailpitInboxListen, .mailpit)
        ]
        if context.selectedDatabase != .none { owners.append((ports.mysqlListen, selectedDatabaseService)) }
        if context.selectedPostgreSQL != .none { owners.append((ports.postgresqlListen, .postgresql18)) }
        var upstreams: [UInt16: UInt16] = [:]
        if context.helperInstalled {
            for entry in ports.forwardings {
                if entry.publicPort == ports.mysql, context.selectedDatabase == .none { continue }
                if entry.publicPort == ports.postgresql, context.selectedPostgreSQL == .none { continue }
                let service: ServiceKind
                switch entry.publicPort {
                case ports.webHTTP, ports.webHTTPS: service = webService
                case ports.mysql: service = selectedDatabaseService
                case ports.postgresql: service = .postgresql18
                default: service = .mailpit
                }
                owners.append((entry.publicPort, service))
                upstreams[entry.publicPort] = entry.upstreamPort
            }
        }
        var phases: [ServiceKind: ServicePhase] = [:]
        for state in context.serviceStates { phases[state.service] = state.phase }
        // This copy's helper answers; a listener on a forwarded port is its.
        let ownForwarder = context.helperStatus?.portForwardingEnabled == true
        return owners.map { port, service in
            let listening = PortAvailability.isListening(port)
            let upstream = upstreams[port]
            let ours = listening && (upstream == nil ? phases[service] == .running : ownForwarder)
            let expected = phases[service] == .running && (port >= 1024 || context.helperInstalled)
            // lsof sees this user's processes, such as servers an old copy left.
            let owner = listening && !ours ? PortOwner.lookup(port: port, runner: runner) : nil
            let evidence: String
            if ours {
                evidence = upstream.map { "The DevStack helper forwards it to port \($0)." } ?? "\(service.displayName) is listening."
            } else if listening {
                evidence = owner.map { owner in
                    "Used by \(owner.summary)\(owner.executable.map { " from \($0)" } ?? "")."
                        + (owner.isDevStackRuntime ? " It is a DevStack server this copy did not start, such as one an old copy left running." : "")
                } ?? "Another program is listening\(upstream != nil ? ", not this copy's helper" : "")."
            } else {
                evidence = "Nothing is listening."
            }
            let severity: DiagnosticSeverity
            let remediation: String?
            var fix: DiagnosticFix?
            if ours {
                severity = .info
                remediation = nil
            } else if listening {
                // The stack cannot start while another program holds one of its ports.
                severity = .error
                if let owner, owner.isDevStackRuntime {
                    remediation = "Stop it, then start the stack again."
                    fix = .stopProcess(pid: owner.pid, command: owner.command)
                } else {
                    remediation = "Quit that program, or choose another port in Settings → Ports."
                }
            } else if expected {
                severity = .error
                remediation = upstream != nil
                    ? "The helper is not forwarding this port. Repair the helper."
                    : "\(service.displayName) is not listening. Restart it and check its log."
            } else {
                severity = .info
                remediation = nil
            }
            if !listening, expected, upstream != nil { fix = .repairHelper }
            return .init(id: "port-\(port)", title: "Port \(port)", severity: severity, evidence: evidence, remediation: remediation, fix: fix)
        }
    }

    private func hostsResult(expected: [String]) -> DiagnosticResult {
        let expected = expected.filter { $0 != "localhost" && !$0.hasSuffix(".localhost") }
        if expected.isEmpty {
            return .init(id: "hosts", title: "Local domain resolution", severity: .info, evidence: "The configured .localhost domains resolve through macOS without hosts-file edits.")
        }
        do {
            let hosts = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            let missing = expected.filter { !hosts.localizedCaseInsensitiveContains($0) }
            let hasMarkers = hosts.contains(PrivilegedHelperConstants.hostsBeginMarker) && hosts.contains(PrivilegedHelperConstants.hostsEndMarker)
            let healthy = missing.isEmpty && (expected.isEmpty || hasMarkers)
            return .init(
                id: "hosts",
                title: "/etc/hosts mappings",
                severity: healthy ? .info : .warning,
                evidence: healthy
                    ? "The marked DevStack section contains all expected hostnames."
                    : "Managed markers: \(hasMarkers ? "present" : "missing"); missing hostnames: \(missing.isEmpty ? "none" : missing.joined(separator: ", ")).",
                remediation: healthy ? nil : "Reapply site mappings from DevStack."
            )
        } catch {
            return .init(id: "hosts", title: "/etc/hosts mappings", severity: .error, evidence: error.localizedDescription)
        }
    }

    private func runtimeResults(_ manifests: [RuntimeManifest], paths: DevStackPaths, required: Set<String>, progress: (@Sendable (String) -> Void)?) -> [DiagnosticResult] {
        manifests.map { manifest in
            progress?("Inspecting \(manifest.id)…")
            if manifest.kind == .phpExtension {
                let owners = manifest.build?.dependencies.filter { $0.hasPrefix("php-") } ?? []
                let installed = owners.compactMap { id -> URL? in
                    let roots = [paths.importedRuntimes.appendingPathComponent(id), paths.builtInRuntimes.appendingPathComponent(id)]
                    return roots.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bin/php").path) }
                }
                guard !installed.isEmpty else {
                    return .init(id: "runtime-\(manifest.id)", title: manifest.id, severity: owners.contains(where: required.contains) ? .warning : .info, evidence: "The owning PHP runtime is not installed.")
                }
                let failures = installed.flatMap { root in auditRuntimeBinaries(at: root, manifest: manifest) }
                let missing = installed.flatMap { root in manifest.entryPoints.values.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) } }
                let healthy = failures.isEmpty && missing.isEmpty
                return .init(id: "runtime-\(manifest.id)", title: "Extension \(manifest.id)", severity: healthy ? .info : .error,
                    evidence: healthy ? "Module and signature verified for \(installed.map(\.lastPathComponent).joined(separator: ", "))." : (failures + missing).joined(separator: "\n"),
                    remediation: healthy ? nil : "Reinstall the affected PHP runtime and extension.")
            }
            let roots = [paths.importedRuntimes.appendingPathComponent(manifest.id), paths.builtInRuntimes.appendingPathComponent(manifest.id)]
            let root = roots.first { FileManager.default.fileExists(atPath: $0.path) }
            if root == nil, manifest.build?.feasibilityGate != nil, manifest.supportState != .supported, !required.contains(manifest.id) {
                return .init(id: "runtime-\(manifest.id)", title: "Optional runtime \(manifest.id)", severity: .info,
                    evidence: "Not included in this build. Its compatibility gate must pass before installation.")
            }
            let missing = manifest.entryPoints.values.filter { relative in
                guard let root else { return true }
                return !FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
            }
            guard let root else {
                // Runtimes the stack does not use are optional downloads.
                let used = required.contains(manifest.id)
                return .init(
                    id: "runtime-\(manifest.id)",
                    title: "Runtime \(manifest.id)",
                    severity: used ? .error : .info,
                    evidence: used ? "Not installed, but your stack uses it." : "Not installed. Your stack does not use it.",
                    remediation: used ? "Install it from the Runtimes page." : nil,
                    fix: used ? .installRuntime(manifest.id) : nil
                )
            }
            guard missing.isEmpty else {
                return .init(
                    id: "runtime-\(manifest.id)",
                    title: "Runtime \(manifest.id)",
                    severity: .error,
                    evidence: "Incomplete. Missing: \(missing.joined(separator: ", "))",
                    remediation: "Remove it on the Runtimes page and install it again."
                )
            }
            let binaryFailures = auditRuntimeBinaries(at: root, manifest: manifest)
            return .init(
                id: "runtime-\(manifest.id)",
                title: "Runtime \(manifest.id)",
                severity: binaryFailures.isEmpty ? .info : .error,
                evidence: binaryFailures.isEmpty ? "Entry points, ARM64 architecture, signatures, and dependency paths passed." : binaryFailures.joined(separator: "\n"),
                remediation: binaryFailures.isEmpty ? nil : "Remove it on the Runtimes page and install it again."
            )
        }
    }

    private func auditRuntimeBinaries(at root: URL, manifest: RuntimeManifest) -> [String] {
        let verifier = RuntimePackVerifier(trustedPublicKeys: [:], requireSignature: false, runner: runner)
        var candidates = Set(manifest.entryPoints.values.map { root.appendingPathComponent($0) })
        if manifest.kind != .phpExtension, let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            while let file = enumerator.nextObject() as? URL {
                guard file.pathExtension == "dylib" || file.pathExtension == "so" else { continue }
                guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                candidates.insert(file)
            }
        }

        var failures: [String] = []
        for file in candidates.sorted(by: { $0.path < $1.path }) {
            guard let result = try? runner.run(executable: URL(fileURLWithPath: "/usr/bin/file"), arguments: ["-b", file.path], timeout: 10),
                  result.exitCode == 0,
                  result.standardOutput.contains("Mach-O") else { continue }
            do {
                try verifier.verifyMachO(file, relativePath: file.path.replacingOccurrences(of: root.path + "/", with: ""))
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func configurationResults(_ context: DiagnosticContext) -> [DiagnosticResult] {
        var checks: [(id: String, title: String, executable: URL, arguments: [String], reportsOutput: Bool)] = []
        // Only what the stack runs: the selected web server and the PHP
        // versions in use. The others have no generated configuration.
        if context.selectedWebServer == .apache {
            let apacheConfig = context.paths.generatedApache.appendingPathComponent("httpd.conf")
            checks.append((
                "config-apache", "Apache configuration",
                context.paths.runtimeDirectory("apache-2.4").appendingPathComponent("bin/httpd"),
                ["-t", "-f", apacheConfig.path],
                true
            ))
        } else {
            checks.append(("config-nginx", "Nginx configuration", context.paths.runtimeDirectory("nginx-1.30").appendingPathComponent("sbin/nginx"),
                ["-t", "-p", context.paths.generatedNginx.path + "/", "-c", context.paths.generatedNginx.appendingPathComponent("nginx.conf").path], true))
        }
        for runtimeID in ["php-7.4", "php-8.4", "php-8.5"] where context.requiredRuntimeIDs.contains(runtimeID) {
            let config = context.paths.generatedPHP.appendingPathComponent("\(runtimeID)-fpm.conf")
            checks.append((
                "config-\(runtimeID)", "\(runtimeID) FPM configuration",
                context.paths.runtimeDirectory(runtimeID).appendingPathComponent("sbin/php-fpm"),
                ["-t", "-y", config.path, "-c", context.paths.generatedPHP.appendingPathComponent("\(runtimeID).ini").path],
                true
            ))
        }
        let engine = context.selectedDatabase
        let mysqlConfig = context.paths.generated.appendingPathComponent("\(engine.rawValue).cnf")
        let mysqlArguments = engine == .mysql84
            ? ["--defaults-file=\(mysqlConfig.path)", "--validate-config"]
            : ["--defaults-file=\(mysqlConfig.path)", "--verbose", "--help"]
        if engine != .none { checks.append((
            "config-\(engine.rawValue)", "\(engine.displayName) configuration",
            context.paths.runtimeDirectory(engine.rawValue).appendingPathComponent("bin/mysqld"),
            mysqlArguments,
            engine == .mysql84
        )) }

        return checks.map { id, title, executable, arguments, reportsOutput in
            let referencedFiles = arguments.filter { $0.hasPrefix("/") || $0.hasPrefix("--defaults-file=") }
            let missingReference = referencedFiles.first { argument in
                let path = argument.replacingOccurrences(of: "--defaults-file=", with: "")
                return !FileManager.default.fileExists(atPath: path)
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                // The runtime check above reports the missing runtime.
                return .init(id: id, title: title, severity: .info, evidence: "Not checked: the runtime is not installed.")
            }
            guard missingReference == nil else {
                return .init(id: id, title: title, severity: .info,
                             evidence: "Not checked: DevStack writes this configuration when the stack first starts.")
            }
            do {
                let result = try runner.runChecked(executable: executable, arguments: arguments,
                    environment: RuntimeEnvironment.services(openssl: context.paths.runtimeDirectory("openssl-3.5"),
                        imageMagick: context.paths.runtimeDirectory("imagemagick-7.1"), phpConfiguration: context.paths.generatedPHP), timeout: 30)
                let output = (result.standardError + result.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
                let evidence = output.isEmpty || !reportsOutput ? "Syntax valid" : redact(String(output.prefix(2_000)))
                return .init(id: id, title: title, severity: .info, evidence: evidence)
            } catch {
                return .init(id: id, title: title, severity: .error, evidence: redact(error.localizedDescription), remediation: "Regenerate the configuration and inspect the relevant service log.")
            }
        }
    }

    private func certificateResults(_ context: DiagnosticContext) -> [DiagnosticResult] {
        let openssl = context.paths.runtimeDirectory("openssl-3.5").appendingPathComponent("bin/openssl")
        let certificates = context.expectedHostnames.map { context.paths.certificate(for: $0) }
        let privateKeys = context.expectedHostnames.map { context.paths.privateKey(for: $0) }
        guard FileManager.default.isExecutableFile(atPath: openssl.path) else {
            return [.init(id: "certificates", title: "TLS certificates", severity: .warning, evidence: "OpenSSL runtime is not installed; certificate expiry was not checked.")]
        }
        let missing = certificates.filter { !FileManager.default.fileExists(atPath: $0.path) }
        let expiring = certificates.filter { certificate in
            guard FileManager.default.fileExists(atPath: certificate.path) else { return false }
            guard let result = try? runner.run(executable: openssl, arguments: ["x509", "-checkend", "2592000", "-noout", "-in", certificate.path],
                environment: RuntimeEnvironment.openssl(at: context.paths.runtimeDirectory("openssl-3.5")), timeout: 10)
            else { return true }
            return result.exitCode != 0
        }
        let insecureKeys = privateKeys.filter { key in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: key.path),
                  let permissions = attributes[.posixPermissions] as? NSNumber else { return true }
            return permissions.intValue & 0o077 != 0
        }
        let healthy = missing.isEmpty && expiring.isEmpty && insecureKeys.isEmpty
        return [.init(
            id: "certificates",
            title: "TLS certificates",
            severity: healthy ? .info : .warning,
            evidence: healthy
                ? "All leaf certificates are valid for at least 30 days and private keys are mode 0600."
                : "Missing: \(missing.count); expiring or invalid: \(expiring.count); insecure or missing keys: \(insecureKeys.count).",
            remediation: healthy ? nil : "Renew site certificates and verify private-key permissions."
        )]
    }

    private func databaseResult(_ context: DiagnosticContext) -> DiagnosticResult {
        if context.selectedDatabase == .none {
            return .init(id: "database-state", title: "MySQL selection", severity: .info, evidence: "MySQL is excluded from Start Stack. Existing databases are preserved.")
        }
        let selectedDirectory = context.selectedDatabase == .mysql57 ? context.paths.mysql57Data : context.paths.mysql84Data
        let otherDirectory = context.selectedDatabase == .mysql57 ? context.paths.mysql84Data : context.paths.mysql57Data
        guard selectedDirectory.standardizedFileURL.path != otherDirectory.standardizedFileURL.path else {
            return .init(id: "database-state", title: "Database isolation", severity: .error, evidence: "MySQL data directories resolve to the same path.", remediation: "Move each engine to its own data directory before starting MySQL.")
        }
        let initialized = FileManager.default.fileExists(atPath: selectedDirectory.appendingPathComponent("mysql").path)
        let manager = DatabaseManager(paths: context.paths, runtimeRoot: context.paths.runtimeDirectory(context.selectedDatabase.rawValue).deletingLastPathComponent(), runner: runner,
                                      opensslRuntime: context.paths.runtimeDirectory("openssl-3.5"), port: context.ports.mysqlListen)
        let selectedService: ServiceKind = context.selectedDatabase == .mysql57 ? .mysql57 : .mysql84
        let running = context.serviceStates.first(where: { $0.service == selectedService })?.phase == .running
        let reachable = running ? manager.ping(context.selectedDatabase) : false
        let healthy = !running || reachable
        return .init(
            id: "database-state",
            title: "Database isolation and state",
            severity: healthy ? .info : .error,
            evidence: "Selected: \(context.selectedDatabase.displayName); initialized: \(initialized ? "yes" : "no"); readiness: \(running ? (reachable ? "reachable" : "unreachable") : "stopped"); data directories are separate.",
            remediation: healthy ? nil : "Inspect the selected MySQL log and restart the engine."
        )
    }

    private func postgreSQLResult(_ context: DiagnosticContext) -> DiagnosticResult {
        let running = context.serviceStates.contains { $0.service == .postgresql18 && $0.phase == .running }
        let manager = PostgreSQLManager(paths: context.paths, runtime: context.paths.runtimeDirectory("postgresql-18"),
                                        opensslRuntime: context.paths.runtimeDirectory("openssl-3.5"), port: context.ports.postgresqlListen)
        let reachable = !running || manager.ping()
        return .init(id: "postgresql-state", title: "PostgreSQL state", severity: reachable ? .info : .error,
            evidence: "Selected: \(context.selectedPostgreSQL.displayName); service: \(running ? "running" : "stopped"); own data directory: \(context.paths.postgresql18Data.path).",
            remediation: reachable ? nil : "Inspect the PostgreSQL log and check port \(context.ports.postgresqlListen).")
    }

    private func diskResult(_ url: URL) -> DiagnosticResult {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let bytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            let severity: DiagnosticSeverity = bytes < 2_000_000_000 ? .warning : .info
            return .init(
                id: "disk-space",
                title: "Available disk space",
                severity: severity,
                evidence: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                remediation: severity == .warning ? "Free at least 2 GB before initializing runtimes." : nil
            )
        } catch {
            return .init(id: "disk-space", title: "Available disk space", severity: .warning, evidence: error.localizedDescription)
        }
    }

    private func codeSignatureResult(_ applicationURL: URL) -> DiagnosticResult {
        do {
            let result = try runner.runChecked(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", applicationURL.path],
                timeout: 30
            )
            return .init(id: "code-signature", title: "Application signature", severity: .info, evidence: result.standardError.isEmpty ? "Valid" : result.standardError)
        } catch {
            return .init(id: "code-signature", title: "Application signature", severity: .error, evidence: error.localizedDescription, remediation: "Install an intact signed DevStack application.")
        }
    }

    private func redact(_ value: String) -> String {
        value.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
    }
}

public struct SupportBundleExporter: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = .init()) {
        self.runner = runner
    }

    public func export(report: DiagnosticReport, paths: DevStackPaths, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("DevStack-Support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(try encoder.encode(redacted(report)), to: staging.appendingPathComponent("diagnostics.json"))

        copyRedactedFile(paths.configurationFile, to: staging.appendingPathComponent("configuration.json"))
        copyTextTree(paths.generated, to: staging.appendingPathComponent("Generated"), maximumFileBytes: 1_000_000)
        copyTextTree(paths.logs, to: staging.appendingPathComponent("Logs"), maximumFileBytes: 200_000)

        let temporaryArchive = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        _ = try runner.runChecked(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, temporaryArchive.path],
            timeout: 60
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryArchive, to: destination)
    }

    private func copyTextTree(_ source: URL, to destination: URL, maximumFileBytes: Int) {
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return }
        while let file = enumerator.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= maximumFileBytes
            else { continue }
            let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
            copyRedactedFile(file, to: destination.appendingPathComponent(relative))
        }
    }

    private func copyRedactedFile(_ source: URL, to destination: URL) {
        guard var text = try? String(contentsOf: source, encoding: .utf8) else { return }
        text = text.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
        text = text.replacingOccurrences(of: #"(?i)(password|passwd|secret)\s*[=:]\s*[^\s\"']+"#, with: "$1=<redacted>", options: .regularExpression)
        try? AtomicFileWriter.write(text, to: destination)
    }

    private func redacted(_ report: DiagnosticReport) -> DiagnosticReport {
        var report = report
        report.results = report.results.map { result in
            var result = result
            result.evidence = result.containsSensitiveData ? "<redacted>" : result.evidence.replacingOccurrences(of: NSHomeDirectory(), with: "$HOME")
            return result
        }
        return report
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
