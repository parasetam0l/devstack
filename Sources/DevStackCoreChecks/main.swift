import DevStackCore
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
