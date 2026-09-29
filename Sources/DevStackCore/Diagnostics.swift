import Foundation

public struct DiagnosticContext: Sendable {
    public var paths: DevStackPaths
    public var runtimeManifests: [RuntimeManifest]
    public var applicationURL: URL?
    public var helperInstalled: Bool
    public var expectedHostnames: [String]

    public init(
        paths: DevStackPaths,
        runtimeManifests: [RuntimeManifest] = [],
        applicationURL: URL? = nil,
        helperInstalled: Bool = false,
        expectedHostnames: [String] = []
    ) {
        self.paths = paths
        self.runtimeManifests = runtimeManifests
        self.applicationURL = applicationURL
        self.helperInstalled = helperInstalled
        self.expectedHostnames = expectedHostnames
    }
}

public struct DevStackDoctor: Sendable {
    private let runner: ProcessRunner

    public init(runner: ProcessRunner = .init()) {
        self.runner = runner
    }

    public func run(context: DiagnosticContext, appVersion: String) -> DiagnosticReport {
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
        results.append(.init(
            id: "privileged-helper",
            title: "Privileged helper",
            severity: context.helperInstalled ? .info : .error,
            evidence: context.helperInstalled ? "Installed" : "Not installed",
            remediation: context.helperInstalled ? nil : "Install and authorize the DevStack helper from Settings."
        ))

        results.append(contentsOf: portResults([80, 443, 3306, 1025, 8025, 8080, 8443]))
        results.append(hostsResult(expected: context.expectedHostnames))
        results.append(contentsOf: runtimeResults(context.runtimeManifests, paths: context.paths))
        results.append(diskResult(context.paths.applicationSupport))

        if let applicationURL = context.applicationURL {
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

    private func portResults(_ ports: [Int]) -> [DiagnosticResult] {
        ports.map { port in
            do {
                let result = try runner.run(
                    executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                    arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
                    timeout: 5
                )
                let occupied = result.exitCode == 0 && !result.standardOutput.isEmpty
                return .init(
                    id: "port-\(port)",
                    title: "Port \(port)",
                    severity: occupied ? .warning : .info,
                    evidence: occupied ? redact(result.standardOutput) : "Available",
                    remediation: occupied ? "Stop the conflicting listener before starting DevStack." : nil
                )
            } catch {
                return .init(id: "port-\(port)", title: "Port \(port)", severity: .warning, evidence: error.localizedDescription)
            }
        }
    }

    private func hostsResult(expected: [String]) -> DiagnosticResult {
        do {
            let hosts = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
            let missing = expected.filter { !hosts.localizedCaseInsensitiveContains($0) }
            return .init(
                id: "hosts",
                title: "/etc/hosts mappings",
                severity: missing.isEmpty ? .info : .warning,
                evidence: missing.isEmpty ? "All expected hostnames are present." : "Missing: \(missing.joined(separator: ", "))",
                remediation: missing.isEmpty ? nil : "Reapply site mappings from DevStack."
            )
        } catch {
            return .init(id: "hosts", title: "/etc/hosts mappings", severity: .error, evidence: error.localizedDescription)
        }
    }

    private func runtimeResults(_ manifests: [RuntimeManifest], paths: DevStackPaths) -> [DiagnosticResult] {
        manifests.map { manifest in
            let roots = [paths.builtInRuntimes.appendingPathComponent(manifest.id), paths.importedRuntimes.appendingPathComponent(manifest.id)]
            let root = roots.first { FileManager.default.fileExists(atPath: $0.path) }
            let missing = manifest.entryPoints.values.filter { relative in
                guard let root else { return true }
                return !FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
            }
            return .init(
                id: "runtime-\(manifest.id)",
                title: "Runtime \(manifest.id)",
                severity: missing.isEmpty ? .info : .error,
                evidence: missing.isEmpty ? "All entry points are present." : "Missing: \(missing.joined(separator: ", "))",
                remediation: missing.isEmpty ? nil : "Reinstall DevStack or import a valid signed runtime pack."
            )
        }
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
