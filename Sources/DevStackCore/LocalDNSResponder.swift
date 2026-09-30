import Foundation
import Network

/// A tiny UDP DNS server for DevStack hostnames.
///
/// Managed hostnames answer directly with the Mac's LAN address (A records;
/// AAAA and everything else answer NODATA so remote clients use IPv4). Every
/// other query is relayed unchanged to the system resolvers, so pointing a
/// phone at this server does not change how the rest of the internet resolves.
/// Only loopback and private-network clients are served.
public final class LocalDNSResponder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.devstack.desktop.dns")
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var failure: String?
    private var configuration = DNSConfiguration(enabled: false)
    private var managedNames: Set<String> = []
    private var upstreams: [String] = []

    public init(port: UInt16 = 53) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 53
    }

    public var isEnabled: Bool { listener != nil && failure == nil }
    public var answerAddress: String? { isEnabled ? configuration.answerAddress : nil }
    public var failureDescription: String? { failure }
    public var listeningPort: UInt16? { listener?.port?.rawValue }

    /// Applies the configuration. The listener is kept while the service stays
    /// enabled so changing hostnames never races a rebind of port 53.
    public func apply(_ configuration: DNSConfiguration, upstreams: [String]) throws {
        self.configuration = configuration
        self.managedNames = Set(configuration.hostnames.map { $0.lowercased() })
        self.upstreams = upstreams
        guard configuration.enabled else {
            stop()
            return
        }
        guard listener == nil else {
            failure = nil
            return
        }
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.queue.async { self?.failure = "\(error)" }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        failure = nil
    }

    private func accept(_ connection: NWConnection) {
        guard LocalNetwork.isLocalSource(Self.hostDescription(connection.endpoint)) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }
            self.respond(to: data, on: connection)
        }
    }

    private func respond(to query: Data, on connection: NWConnection) {
        guard let question = DNSMessage.parseQuestion(query) else {
            forward(query, upstreamIndex: 0, on: connection)
            return
        }
        if managedNames.contains(question.name) {
            send(DNSMessage.localResponse(for: question, address: configuration.answerAddress), on: connection)
            return
        }
        forward(query, upstreamIndex: 0, on: connection)
    }

    private func forward(_ query: Data, upstreamIndex: Int, on connection: NWConnection) {
        guard upstreamIndex < upstreams.count else {
            send(DNSMessage.failureResponse(for: DNSMessage.parseQuestion(query), rcode: DNSMessage.rcodeServerFailure), on: connection)
            return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(upstreams[upstreamIndex]), port: 53, using: .udp)
        let state = ForwardState()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard state.claim() else { return }
            upstream.cancel()
            self?.forward(query, upstreamIndex: upstreamIndex + 1, on: connection)
        }
        upstream.stateUpdateHandler = { [weak self] update in
            guard case .ready = update else { return }
            upstream.send(content: query, completion: .contentProcessed { _ in
                upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { data, _, _, error in
                    guard let self, state.claim() else { return }
                    if let data, !data.isEmpty, error == nil {
                        self.send(data, on: connection)
                    } else {
                        self.forward(query, upstreamIndex: upstreamIndex + 1, on: connection)
                    }
                    upstream.cancel()
                }
            })
        }
        upstream.start(queue: queue)
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func hostDescription(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "" }
        return "\(host)"
    }
}

private final class ForwardState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
