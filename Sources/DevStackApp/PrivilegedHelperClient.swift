import DevStackCore
import Foundation
import ServiceManagement
import Security

struct PrivilegedHelperClient: @unchecked Sendable {
    private let service = SMAppService.daemon(plistName: "app.devstack.desktop.helper.plist")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var isRegistered: Bool { service.status == .enabled }
    var registrationStatus: SMAppService.Status { service.status }

    /// Signing Team ID of the running app, when present.
    var teamIdentifier: String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True when running from the installed signed release rather than a
    /// build directory, DerivedData, or preview staging path.
    var isRunningFromApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var runningBundlePath: String { Bundle.main.bundleURL.path }

    var canAuthenticate: Bool { teamIdentifier != nil }

    /// Fail-closed: ad-hoc / unsigned / preview builds can never drive the
    /// privileged helper, no matter what. The error tells the user exactly
    /// which build they launched and which one to open instead.
    func register() throws {
        guard canAuthenticate else {
            throw NSError(domain: "app.devstack.desktop.helper", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "This build is ad-hoc signed and cannot drive the helper. Open the signed DevStack build in Applications instead."])
        }
        guard service.status != .enabled, service.status != .requiresApproval else { return }
        try service.register()
    }

    func unregister() async throws {
        guard service.status != .notRegistered else { return }
        try await service.unregister()
    }

    func applyHostMappings(_ mappings: [HostMapping]) async throws {
        let request = try encoder.encode(mappings)
        let _: HelperAcknowledgement = try await call { proxy, reply in
            proxy.applyHostMappings(request, withReply: reply)
        }
    }

    func setPortForwarding(_ configuration: PortForwardingConfiguration) async throws {
        let request = try encoder.encode(configuration)
        let _: HelperAcknowledgement = try await call { proxy, reply in
            proxy.setPortForwarding(request, withReply: reply)
        }
    }

    func setDNSConfiguration(_ configuration: DNSConfiguration) async throws {
        let request = try encoder.encode(configuration)
        let _: HelperAcknowledgement = try await call { proxy, reply in
            proxy.setDNSConfiguration(request, withReply: reply)
        }
    }

    func removeManagedState() async throws {
        let _: HelperAcknowledgement = try await call { proxy, reply in
            proxy.removeManagedState(withReply: reply)
        }
    }

    func status() async throws -> PrivilegedHelperStatus {
        try await refreshStatus().status
    }

    /// Result of a helper status refresh: the helper's state plus whether an
    /// outdated helper was retired, in which case the caller re-applies the
    /// managed state to the freshly started helper.
    struct StatusRefresh: Sendable {
        var status: PrivilegedHelperStatus
        var restarted: Bool
    }

    /// Asks the helper for its status. When the running helper was started from
    /// an older app build, it is retired and launchd starts the current binary
    /// on the next request; the status is then fetched again.
    func refreshStatus() async throws -> StatusRefresh {
        let status = try await rawStatus()
        guard let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !currentBuild.isEmpty, !status.build.isEmpty, status.build != currentBuild else {
            return StatusRefresh(status: status, restarted: false)
        }
        let _: HelperAcknowledgement? = try? await call { proxy, reply in
            proxy.retire(withReply: reply)
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(400))
            if let fresh = try? await rawStatus(), fresh.build == currentBuild {
                return StatusRefresh(status: fresh, restarted: true)
            }
        }
        return StatusRefresh(status: status, restarted: true)
    }

    private func rawStatus() async throws -> PrivilegedHelperStatus {
        try await call { proxy, reply in proxy.status(withReply: reply) }
    }

    private func call<Response: Decodable & Sendable>(
        _ operation: @escaping (PrivilegedHelperXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: PrivilegedHelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperXPCProtocol.self)
            let gate = ReplyGate(continuation: continuation, decoder: decoder, connection: connection)
            connection.interruptionHandler = { gate.fail(CocoaError(.xpcConnectionInterrupted)) }
            connection.invalidationHandler = { gate.fail(CocoaError(.xpcConnectionInvalid)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                gate.fail(NSError(domain: "app.devstack.desktop.helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "The helper did not reply within 15 seconds. Check its approval in System Settings."]))
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.fail(error)
            }) as? PrivilegedHelperXPCProtocol else {
                continuation.resume(throwing: CocoaError(.featureUnsupported))
                return
            }
            connection.resume()
            operation(proxy) { data, error in gate.finish(data: data, error: error) }
        }
    }
}

private struct HelperAcknowledgement: Decodable, Sendable {
    let ok: Bool
}

private final class ReplyGate<Response: Decodable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Response, Error>?
    private let decoder: JSONDecoder
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<Response, Error>, decoder: JSONDecoder, connection: NSXPCConnection) {
        self.continuation = continuation
        self.decoder = decoder
        self.connection = connection
    }

    func finish(data: Data?, error: NSError?) {
        complete {
            if let error { return .failure(error) }
            guard let data else { return .failure(CocoaError(.coderReadCorrupt)) }
            return Result { try decoder.decode(Response.self, from: data) }
        }
    }

    func fail(_ error: Error) {
        complete { .failure(error) }
    }

    private func complete(_ result: () -> Result<Response, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        connection.invalidate()
        continuation.resume(with: result())
    }
}
