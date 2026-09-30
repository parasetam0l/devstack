import DevStackCore
import Foundation
import Network
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

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard CodeSignatureValidator.isAuthorizedApp(processIdentifier: connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private enum CodeSignatureValidator {
    static func isAuthorizedApp(processIdentifier: pid_t) -> Bool {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        var requirement: SecRequirement?
        var helperCode: SecCode?
        var helperStaticCode: SecStaticCode?
        var helperInformation: CFDictionary?
        guard SecCodeCopySelf([], &helperCode) == errSecSuccess, let helperCode,
              SecCodeCopyStaticCode(helperCode, [], &helperStaticCode) == errSecSuccess, let helperStaticCode,
              SecCodeCopySigningInformation(helperStaticCode, [], &helperInformation) == errSecSuccess,
              let information = helperInformation as? [String: Any],
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return false }
        let expression = "identifier \"\(PrivilegedHelperConstants.applicationBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(expression, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}

private final class PrivilegedHelperService: NSObject, PrivilegedHelperXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let hostsURL = URL(fileURLWithPath: "/etc/hosts")
    private let stateDirectory = URL(fileURLWithPath: "/Library/Application Support/DevStack", isDirectory: true)
    private let forwarder = LoopbackForwarder()
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

    func trustLocalCA(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let proposed = try self.decoder.decode(LocalCARequest.self, from: request)
            let certificate = try PrivilegedRequestValidator.localCA(proposed)
            guard SecCertificateCreateWithData(nil, certificate.certificateDER as CFData) != nil else {
                throw PrivilegedRequestValidationError.invalidCertificate
            }
            try FileManager.default.createDirectory(at: self.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let destination = self.stateDirectory.appendingPathComponent("DevStack-Local-CA.der")
            try self.writeRootFile(certificate.certificateDER, to: destination, permissions: 0o644)
            _ = try self.runSecurity(["add-trusted-cert", "-d", "-r", "trustRoot", "-k", "/Library/Keychains/System.keychain", destination.path])
            return try self.encodeSuccess()
        }
    }

    func removeManagedState(withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let original = try String(contentsOf: self.hostsURL, encoding: .utf8)
            let replacement = HostsFileEditor.removingManagedSection(from: original)
            try self.writeRootFile(Data((replacement + "\n").utf8), to: self.hostsURL, permissions: 0o644)
            try self.forwarder.apply(PortForwardingConfiguration(enabled: false))
            let certificate = self.stateDirectory.appendingPathComponent("DevStack-Local-CA.der")
            if FileManager.default.fileExists(atPath: certificate.path) {
                _ = try? self.runSecurity(["remove-trusted-cert", "-d", certificate.path])
                try? FileManager.default.removeItem(at: certificate)
            }
            return try self.encodeSuccess()
        }
    }

    func status(withReply reply: @escaping (Data?, NSError?) -> Void) {
        perform(reply) {
            let hosts = (try? String(contentsOf: self.hostsURL, encoding: .utf8)) ?? ""
            let certificate = self.stateDirectory.appendingPathComponent("DevStack-Local-CA.der")
            let status = PrivilegedHelperStatus(
                hostMappingsInstalled: hosts.contains(PrivilegedHelperConstants.hostsBeginMarker),
                portForwardingEnabled: self.forwarder.isEnabled,
                localCATrusted: FileManager.default.fileExists(atPath: certificate.path),
                version: "0.1.0"
            )
            return try self.encoder.encode(status)
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

    private func runSecurity(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "app.devstack.desktop.helper", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }
}

private final class LoopbackForwarder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.devstack.desktop.helper.forwarding")
    private var listeners: [NWListener] = []
    private(set) var isEnabled = false

    func apply(_ configuration: PortForwardingConfiguration) throws {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        isEnabled = false
        guard configuration.enabled else { return }

        for (publicPort, upstreamPort) in [(UInt16(80), configuration.httpUpstreamPort), (UInt16(443), configuration.httpsUpstreamPort)] {
            for host in ["127.0.0.1", "::1"] {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: publicPort)!)
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] incoming in
                    self?.accept(incoming, upstreamPort: upstreamPort)
                }
                listener.start(queue: queue)
                listeners.append(listener)
            }
        }
        isEnabled = true
    }

    private func accept(_ incoming: NWConnection, upstreamPort: UInt16) {
        let outgoing = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
        incoming.stateUpdateHandler = { state in
            if case .ready = state { Self.pipe(from: incoming, to: outgoing) }
        }
        outgoing.stateUpdateHandler = { state in
            if case .ready = state { Self.pipe(from: outgoing, to: incoming) }
        }
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
    }

    private static func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, complete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError == nil { pipe(from: source, to: destination) }
                    else { source.cancel(); destination.cancel() }
                })
            } else if complete || error != nil {
                source.cancel()
                destination.cancel()
            } else {
                pipe(from: source, to: destination)
            }
        }
    }
}
