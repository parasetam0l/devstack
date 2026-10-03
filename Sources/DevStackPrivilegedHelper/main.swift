import DevStackCore
import Foundation
import Security

@main
enum DevStackPrivilegedHelperMain {
    static func main() {
        let delegate = HelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: PrivilegedHelperConstants.machServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}

private final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = PrivilegedHelperService()
    /// Built once from the helper's own signature. A helper without a Team ID
    /// (ad-hoc or unsigned) accepts no clients.
    private let clientRequirement = CodeSignatureValidator.clientRequirement()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let clientRequirement else { return false }
        // XPC checks the requirement against the peer's audit token on every
        // message. A process-ID lookup could be satisfied by a different
        // process that reuses the ID after the check.
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private enum CodeSignatureValidator {
    /// The DevStack app signed by the helper's own team.
    static func clientRequirement() -> String? {
        var helperCode: SecCode?
        var helperStaticCode: SecStaticCode?
        var helperInformation: CFDictionary?
        guard SecCodeCopySelf([], &helperCode) == errSecSuccess, let helperCode,
              SecCodeCopyStaticCode(helperCode, [], &helperStaticCode) == errSecSuccess, let helperStaticCode,
              SecCodeCopySigningInformation(helperStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &helperInformation) == errSecSuccess,
              let information = helperInformation as? [String: Any],
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        let expression = "identifier \"\(PrivilegedHelperConstants.applicationBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        // Reject a malformed requirement here rather than on the first message.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, requirement != nil else { return nil }
        return expression
    }
}

private final class PrivilegedHelperService: NSObject, PrivilegedHelperXPCProtocol, @unchecked Sendable {
    /// Build number of the app bundle this helper was started from. Read once
    /// at startup: after an app update the running helper still reports the old
    /// build, so the app knows to retire it.
    private static let launchBuild: String = {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var contentsCandidates = [executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
        // Bundle.main.bundleURL is the executable's directory for a daemon
        // binary, so its Contents directory is two levels up as well.
        contentsCandidates.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        contentsCandidates.append(Bundle.main.bundleURL)
        for contents in contentsCandidates {
            let info = contents.appendingPathComponent("Info.plist")
            if let build = (NSDictionary(contentsOf: info)?["CFBundleVersion"] as? String), !build.isEmpty {
                return build
            }
        }
        return ""
    }()

    private let lock = NSLock()
    private let hostsURL = URL(fileURLWithPath: "/etc/hosts")
    private let stateDirectory = URL(fileURLWithPath: "/Library/Application Support/DevStack", isDirectory: true)
    private let forwarder = LoopbackForwarder()
    private let dnsResponder = LocalDNSResponder()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func applyHostMappings(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let mappings = try self.decoder.decode([HostMapping].self, from: request)
            let original = try String(contentsOf: self.hostsURL, encoding: .utf8)
            let replacement = try HostsFileEditor.replacingManagedSection(in: original, mappings: mappings)
            try self.writeRootFile(Data(replacement.utf8), to: self.hostsURL, permissions: 0o644)
            return try self.encodeSuccess()
        }
    }

    func setPortForwarding(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let proposed = try self.decoder.decode(PortForwardingConfiguration.self, from: request)
            let configuration = try PrivilegedRequestValidator.portForwarding(proposed)
            try self.forwarder.apply(configuration)
            return try self.encodeSuccess()
        }
    }

    func setDNSConfiguration(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let proposed = try self.decoder.decode(DNSConfiguration.self, from: request)
            let configuration = try PrivilegedRequestValidator.dnsConfiguration(proposed)
            let resolvConf = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)) ?? ""
            let upstreams = DNSUpstreams.usableResolvers(contents: resolvConf, excluding: [configuration.answerAddress])
            try self.dnsResponder.apply(configuration, upstreams: upstreams)
            return try self.encodeSuccess()
        }
    }

    func removeManagedState(withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let original = try String(contentsOf: self.hostsURL, encoding: .utf8)
            let replacement = HostsFileEditor.removingManagedSection(from: original)
            try self.writeRootFile(Data((replacement + "\n").utf8), to: self.hostsURL, permissions: 0o644)
            try self.forwarder.apply(PortForwardingConfiguration(enabled: false))
            self.dnsResponder.stop()
            // Legacy cleanup: earlier builds stored a CA copy here after a
            // failed system-trust attempt (a daemon cannot authorize that).
            let certificate = self.stateDirectory.appendingPathComponent("DevStack-Local-CA.der")
            try? FileManager.default.removeItem(at: certificate)
            return try self.encodeSuccess()
        }
    }

    func status(withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let hosts = (try? String(contentsOf: self.hostsURL, encoding: .utf8)) ?? ""
            let status = PrivilegedHelperStatus(
                hostMappingsInstalled: hosts.contains(PrivilegedHelperConstants.hostsBeginMarker),
                portForwardingEnabled: self.forwarder.isEnabled,
                version: "0.1.0",
                build: Self.launchBuild,
                dnsEnabled: self.dnsResponder.isEnabled,
                dnsAnswerAddress: self.dnsResponder.answerAddress,
                dnsFailure: self.dnsResponder.failureDescription,
                capabilities: [PrivilegedHelperCapabilities.proxyProtocol]
            )
            return try self.encoder.encode(status)
        }
    }

    func retire(withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            // The app replaced this helper on disk. Exit after the reply so
            // launchd starts the current binary on the next request instead of
            // keeping the outdated one running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(EXIT_SUCCESS) }
            return try self.encodeSuccess()
        }
    }

    private func perform(_ reply: @escaping (Data?, NSError?) -> Void, operation: @escaping () throws -> Data) {
        lock.lock()
        defer { lock.unlock() }
        do { reply(try operation(), nil) }
        catch { reply(nil, error as NSError) }
    }

    private func encodeSuccess() throws -> Data {
        try encoder.encode(["ok": true])
    }

    private func writeRootFile(_ data: Data, to destination: URL, permissions: Int) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".devstack-\(UUID().uuidString)")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: permissions, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: temporary.path)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
