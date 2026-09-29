import DevStackCore
import Foundation
import ServiceManagement

struct PrivilegedHelperClient: @unchecked Sendable {
    private let service = SMAppService.daemon(plistName: "app.devstack.desktop.helper.plist")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var isRegistered: Bool { service.status == .enabled }
    var registrationStatus: SMAppService.Status { service.status }

    func register() throws {
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

    func trustLocalCA(_ certificateDER: Data) async throws {
        let request = try encoder.encode(LocalCARequest(certificateDER: certificateDER))
        let _: HelperAcknowledgement = try await call { proxy, reply in
            proxy.trustLocalCA(request, withReply: reply)
        }
    }

    func removeManagedState() async throws {
        let _: HelperAcknowledgement = try await call { proxy, reply in
            proxy.removeManagedState(withReply: reply)
        }
    }

    func status() async throws -> PrivilegedHelperStatus {
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
