import Foundation
import Network

/// The helper's TCP forwarders: privileged public ports to the unprivileged
/// DevStack listeners on loopback, optionally prefixed with a PROXY protocol
/// header. Requests are validated by `PrivilegedRequestValidator` before they
/// reach `apply`.
public final class LoopbackForwarder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.devstack.desktop.helper.forwarding")
    private var active: [ListenerKey: NWListener] = [:]
    private var activeBindings: [ListenerKey: ForwardBinding] = [:]
    public private(set) var isEnabled = false

    public init() {}

    private struct ForwardBinding: Hashable {
        let port: UInt16
        let upstream: UInt16
        let localSourcesOnly: Bool
        let proxyProtocol: Bool
    }

    private struct ListenerKey: Hashable {
        let host: String
        let port: UInt16
    }

    /// (Re)binds the forwarding listeners. Repeated calls with the same
    /// configuration are a no-op, so the periodic XPC refreshes from the app
    /// never interrupt live listeners. When listeners must change, obsolete
    /// ones are cancelled and awaited before the replacement binds, with
    /// retries for the window where the old socket is still closing.
    public func apply(_ configuration: PortForwardingConfiguration) throws {
        let desired = Self.desiredListeners(for: configuration)
        if desired == activeBindings, desired.isEmpty == !isEnabled { return }

        // Cancel listeners that are no longer wanted or whose upstream changed.
        for (key, listener) in active where desired[key] != activeBindings[key] {
            waitForCancellation(listener, timeout: 1.0)
            active.removeValue(forKey: key)
            activeBindings.removeValue(forKey: key)
        }
        // Start missing listeners; retry while the old socket is still closing.
        for (key, binding) in desired where active[key] == nil {
            do {
                active[key] = try startListener(host: key.host, binding: binding)
                activeBindings[key] = binding
            } catch {
                isEnabled = !active.isEmpty
                throw error
            }
        }
        isEnabled = !active.isEmpty
    }

    private static func desiredListeners(for configuration: PortForwardingConfiguration) -> [ListenerKey: ForwardBinding] {
        guard configuration.enabled else { return [:] }
        var bindings: [UInt16: ForwardBinding] = [:]
        for entry in configuration.entries {
            bindings[entry.publicPort] = ForwardBinding(port: entry.publicPort, upstream: entry.upstreamPort, localSourcesOnly: false, proxyProtocol: entry.proxyProtocol)
        }
        for entry in configuration.lanEntries {
            // A LAN binding covers loopback too, so it replaces the loopback binding for that port.
            bindings[entry.publicPort] = ForwardBinding(port: entry.publicPort, upstream: entry.upstreamPort, localSourcesOnly: true, proxyProtocol: entry.proxyProtocol)
        }
        var desired: [ListenerKey: ForwardBinding] = [:]
        for binding in bindings.values {
            if binding.localSourcesOnly {
                desired[ListenerKey(host: "0.0.0.0", port: binding.port)] = binding
            } else {
                desired[ListenerKey(host: "127.0.0.1", port: binding.port)] = binding
                desired[ListenerKey(host: "::1", port: binding.port)] = binding
            }
        }
        return desired
    }

    /// Starts a listener and waits until it is ready, retrying when the port is
    /// still held by the previous socket.
    private func startListener(host: String, binding: ForwardBinding) throws -> NWListener {
        var lastError: Error = ForwarderError.bindFailed(host: host, port: binding.port)
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.15 * Double(attempt)) }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: binding.port)!)
            // Connections the forwarder closed first leave TIME_WAIT entries on
            // the public port for up to a minute; without address reuse a
            // rebind after a configuration change fails with EADDRINUSE.
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] incoming in
                if binding.localSourcesOnly, !LocalNetwork.isLocalSource(Self.hostDescription(incoming.endpoint)) {
                    incoming.cancel()
                    return
                }
                self?.accept(incoming, binding: binding)
            }
            let semaphore = DispatchSemaphore(value: 0)
            let outcome = ListenerOutcome()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    semaphore.signal()
                case .failed(let error):
                    outcome.failure = error
                    semaphore.signal()
                default:
                    break
                }
            }
            listener.start(queue: queue)
            if semaphore.wait(timeout: .now() + 3) == .timedOut {
                waitForCancellation(listener, timeout: 1.0)
                lastError = ForwarderError.bindTimedOut(host: host, port: binding.port)
                continue
            }
            if let failure = outcome.failure {
                waitForCancellation(listener, timeout: 1.0)
                lastError = failure
                continue
            }
            return listener
        }
        throw lastError
    }

    /// Cancels a listener and waits for Network.framework to release the socket.
    private func waitForCancellation(_ listener: NWListener, timeout: TimeInterval) {
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { semaphore.signal() }
        }
        listener.cancel()
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private final class ListenerOutcome: @unchecked Sendable {
        var failure: Error?
    }

    /// One forwarded connection. Both sides must be ready and, when the binding
    /// uses the PROXY protocol, the header must reach the web server before any
    /// client byte. All access happens on the forwarder's serial queue, so no
    /// locking is required.
    private final class ForwardSession: @unchecked Sendable {
        private let incoming: NWConnection
        private let outgoing: NWConnection
        private let header: Data?
        private var incomingReady = false
        private var outgoingReady = false
        private var started = false

        init(incoming: NWConnection, outgoing: NWConnection, header: Data?) {
            self.incoming = incoming
            self.outgoing = outgoing
            self.header = header
        }

        func incomingBecameReady() {
            incomingReady = true
            startIfReady()
        }

        func outgoingBecameReady() {
            outgoingReady = true
            startIfReady()
        }

        private func startIfReady() {
            guard !started, incomingReady, outgoingReady else { return }
            started = true
            guard let header else {
                LoopbackForwarder.pipe(from: incoming, to: outgoing)
                LoopbackForwarder.pipe(from: outgoing, to: incoming)
                return
            }
            outgoing.send(content: header, completion: .contentProcessed { [incoming, outgoing] error in
                guard error == nil else {
                    incoming.cancel()
                    outgoing.cancel()
                    return
                }
                LoopbackForwarder.pipe(from: incoming, to: outgoing)
                LoopbackForwarder.pipe(from: outgoing, to: incoming)
            })
        }
    }

    private enum ForwarderError: LocalizedError {
        case bindFailed(host: String, port: UInt16)
        case bindTimedOut(host: String, port: UInt16)

        var errorDescription: String? {
            switch self {
            case .bindFailed(let host, let port): "Could not bind \(host):\(port) for port forwarding."
            case .bindTimedOut(let host, let port): "Timed out binding \(host):\(port) for port forwarding."
            }
        }
    }

    private static func hostDescription(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        return "\(host)"
    }

    private func accept(_ incoming: NWConnection, binding: ForwardBinding) {
        let outgoing = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: binding.upstream)!, using: .tcp)
        let header = binding.proxyProtocol ? Self.proxyHeader(for: incoming.endpoint, publicPort: binding.port) : nil
        let session = ForwardSession(incoming: incoming, outgoing: outgoing, header: header)
        incoming.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                session.incomingBecameReady()
            case .failed, .cancelled:
                outgoing.cancel()
            default:
                break
            }
        }
        outgoing.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                session.outgoingBecameReady()
            // A refused loopback connection (the web server is stopped) waits
            // for a network change that never comes. Close the client instead
            // of holding both sockets open indefinitely.
            case .waiting, .failed, .cancelled:
                incoming.cancel()
                outgoing.cancel()
            default:
                break
            }
        }
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
    }

    /// PROXY protocol v1 line carrying the real client address. The destination
    /// fields are loopback placeholders; realip consumers only read the source.
    private static func proxyHeader(for endpoint: NWEndpoint, publicPort: UInt16) -> Data? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let source: String
        let family: String
        switch host {
        case .ipv4(let address):
            source = "\(address)"
            family = "TCP4"
        case .ipv6(let address):
            source = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
            family = "TCP6"
        default:
            return nil
        }
        let destination = family == "TCP4" ? "127.0.0.1" : "::1"
        return Data("PROXY \(family) \(source) \(destination) \(port.rawValue) \(publicPort)\r\n".utf8)
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
