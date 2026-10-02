import Foundation
import Network

/// A tiny DNS server for DevStack hostnames (UDP + TCP on port 53).
///
/// Managed hostnames answer directly with the Mac's LAN address (A records;
/// AAAA and everything else answer NODATA so remote clients use IPv4). Every
/// other query is relayed unchanged to the system resolvers, so pointing a
/// phone at this server does not change how the rest of the internet resolves.
/// Only loopback and private-network clients are served.
public final class LocalDNSResponder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.devstack.desktop.dns")
    private let port: NWEndpoint.Port
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var failure: String?
    private var retired: Set<ObjectIdentifier> = []
    private var configuration = DNSConfiguration(enabled: false)
    private var managedNames: Set<String> = []
    private var upstreams: [String] = []

    public init(port: UInt16 = 53) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 53
    }

    public var isEnabled: Bool { (udpListener != nil || tcpListener != nil) && failure == nil }
    public var answerAddress: String? { isEnabled ? configuration.answerAddress : nil }
    public var failureDescription: String? { failure }
    public var listeningPort: UInt16? { udpListener?.port?.rawValue ?? tcpListener?.port?.rawValue }

    /// Applies the configuration. Listeners are kept while the service stays
    /// enabled so changing hostnames never races a rebind of port 53.
    public func apply(_ configuration: DNSConfiguration, upstreams: [String]) throws {
        self.configuration = configuration
        self.managedNames = Set(configuration.hostnames.map { $0.lowercased() })
        self.upstreams = upstreams
        guard configuration.enabled else {
            stop()
            return
        }
        if udpListener != nil || tcpListener != nil {
            failure = nil
            return
        }
        do {
            let udp = try makeListener(proto: .udp)
            let tcp = try makeListener(proto: .tcp)
            self.udpListener = udp
            self.tcpListener = tcp
            self.failure = nil
        } catch {
            stop()
            self.failure = error.localizedDescription
            throw error
        }
    }

    public func stop() {
        // Retire the listeners before cancelling so their asynchronous
        // .cancelled updates are not mistaken for unexpected failures when a
        // new configuration starts listeners again right away.
        if let udpListener { retired.insert(ObjectIdentifier(udpListener)) }
        if let tcpListener { retired.insert(ObjectIdentifier(tcpListener)) }
        udpListener?.cancel()
        tcpListener?.cancel()
        udpListener = nil
        tcpListener = nil
        failure = nil
    }

    private enum Proto { case udp, tcp }

    private func makeListener(proto: Proto) throws -> NWListener {
        let parameters: NWParameters = proto == .udp ? .udp : .tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            if case .failed(let error) = state {
                self.queue.async { [weak self] in
                    guard let self, !self.isRetired(listener) else { return }
                    self.failure = "\(error)"
                }
            } else if case .cancelled = state {
                self.queue.async { [weak self] in
                    guard let self, !self.isRetired(listener) else { return }
                    if self.failure == nil { self.failure = "DNS listener cancelled unexpectedly." }
                }
            }
        }
        if proto == .udp {
            listener.newConnectionHandler = { [weak self] connection in self?.acceptUDP(connection) }
        } else {
            listener.newConnectionHandler = { [weak self] connection in self?.acceptTCP(connection) }
        }
        listener.start(queue: queue)
        return listener
    }

    private func isRetired(_ listener: NWListener) -> Bool {
        retired.remove(ObjectIdentifier(listener)) != nil
    }

    // MARK: - UDP (one datagram per receive, loop for reuse)

    private func acceptUDP(_ connection: NWConnection) {
        guard LocalNetwork.isLocalSource(Self.hostDescription(connection.endpoint)) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveUDP(on: connection)
    }

    private func receiveUDP(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            if error != nil {
                // ECONNRESET etc. on UDP flow: drop this flow, listener stays up.
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                // Empty read: keep waiting for a real query.
                self.receiveUDP(on: connection)
                return
            }
            self.respondUDP(to: data, on: connection)
        }
    }

    private func respondUDP(to query: Data, on connection: NWConnection) {
        guard let question = DNSMessage.parseQuestion(query) else {
            forward(query, upstreamIndex: 0, on: connection, isTCP: false)
            return
        }
        if managedNames.contains(question.name) {
            sendUDP(DNSMessage.localResponse(for: question, address: currentAnswerAddress()), on: connection)
            return
        }
        if Self.isDevStackName(question.name) {
            sendUDP(DNSMessage.negativeResponse(for: question), on: connection)
            return
        }
        forward(query, upstreamIndex: 0, on: connection, isTCP: false)
    }

    private func sendUDP(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            // Keep the flow open for further queries instead of one-shot cancel.
            self?.receiveUDP(on: connection)
        })
    }

    // MARK: - TCP (2-byte length prefix, loop for pipelining)

    private func acceptTCP(_ connection: NWConnection) {
        guard LocalNetwork.isLocalSource(Self.hostDescription(connection.endpoint)) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receiveTCPLength(on: connection)
    }

    private func receiveTCPLength(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, data.count == 2 else { connection.cancel(); return }
            let length = Int(data[0]) << 8 | Int(data[1])
            guard length > 0, length <= 65_535 else { connection.cancel(); return }
            self.receiveTCPBody(length: length, on: connection)
        }
    }

    private func receiveTCPBody(length: Int, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, data.count == length else { connection.cancel(); return }
            self.respondTCP(to: data, on: connection)
        }
    }

    private func respondTCP(to query: Data, on connection: NWConnection) {
        guard let question = DNSMessage.parseQuestion(query) else {
            forward(query, upstreamIndex: 0, on: connection, isTCP: true)
            return
        }
        if managedNames.contains(question.name) {
            sendTCP(DNSMessage.localResponse(for: question, address: currentAnswerAddress()), on: connection)
            return
        }
        if Self.isDevStackName(question.name) {
            sendTCP(DNSMessage.negativeResponse(for: question), on: connection)
            return
        }
        forward(query, upstreamIndex: 0, on: connection, isTCP: true)
    }

    /// DevStack answers authoritatively for its own suffixes. Forwarding an
    /// unmanaged `.test`/`.localhost` query upstream would let a remote
    /// negative cache outlive a site that is added moments later.
    public static func isDevStackName(_ name: String) -> Bool {
        name == "test" || name.hasSuffix(".test") || name == "localhost" || name.hasSuffix(".localhost")
    }

    /// The configured address while it is still assigned to an interface;
    /// otherwise the current primary LAN address, so a network change does not
    /// keep handing out a stale address until the app re-applies.
    private func currentAnswerAddress() -> String {
        let configured = configuration.answerAddress
        if !configured.isEmpty, LocalNetwork.activeIPv4Addresses().contains(where: { $0.address == configured }) {
            return configured
        }
        return LocalNetwork.primaryIPv4Address() ?? configured
    }

    private func sendTCP(_ response: Data, on connection: NWConnection) {
        var framed = Data(count: 2)
        framed[0] = UInt8((response.count >> 8) & 0xFF)
        framed[1] = UInt8(response.count & 0xFF)
        framed.append(response)
        connection.send(content: framed, completion: .contentProcessed { [weak self] _ in
            self?.receiveTCPLength(on: connection)
        })
    }

    // MARK: - Upstream forwarding (always UDP upstream)

    private func forward(_ query: Data, upstreamIndex: Int, on connection: NWConnection, isTCP: Bool) {
        guard upstreamIndex < upstreams.count else {
            let failure = DNSMessage.failureResponse(for: DNSMessage.parseQuestion(query), rcode: DNSMessage.rcodeServerFailure)
            if isTCP { sendTCP(failure, on: connection) } else { sendUDP(failure, on: connection) }
            return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(upstreams[upstreamIndex]), port: 53, using: .udp)
        let state = ForwardState()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard state.claim() else { return }
            upstream.cancel()
            self?.forward(query, upstreamIndex: upstreamIndex + 1, on: connection, isTCP: isTCP)
        }
        upstream.stateUpdateHandler = { [weak self] update in
            guard case .ready = update else { return }
            upstream.send(content: query, completion: .contentProcessed { [weak self] _ in
                upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self] data, _, _, error in
                    guard state.claim() else { return }
                    guard let strongSelf = self else { return }
                    if let data, !data.isEmpty, error == nil {
                        if isTCP { strongSelf.sendTCP(data, on: connection) } else { strongSelf.sendUDP(data, on: connection) }
                    } else {
                        strongSelf.forward(query, upstreamIndex: upstreamIndex + 1, on: connection, isTCP: isTCP)
                    }
                    upstream.cancel()
                }
            })
        }
        upstream.start(queue: queue)
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
