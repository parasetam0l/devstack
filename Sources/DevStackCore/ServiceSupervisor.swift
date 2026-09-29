import Darwin
import Foundation

public enum ReadinessProbe: Hashable, Sendable {
    case processAlive
    case fileExists(URL)
    case tcpLoopback(port: UInt16)
}

public struct ServiceSpecification: Sendable {
    public var kind: ServiceKind
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var logFile: URL
    public var readinessProbe: ReadinessProbe
    public var readinessTimeout: TimeInterval

    public init(
        kind: ServiceKind,
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        logFile: URL,
        readinessProbe: ReadinessProbe = .processAlive,
        readinessTimeout: TimeInterval = 10
    ) {
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.logFile = logFile
        self.readinessProbe = readinessProbe
        self.readinessTimeout = readinessTimeout
    }
}

public actor ServiceSupervisor {
    private var processes: [ServiceKind: Process] = [:]
    private var logHandles: [ServiceKind: FileHandle] = [:]
    private var states: [ServiceKind: ServiceState] = Dictionary(
        uniqueKeysWithValues: ServiceKind.allCases.map { ($0, ServiceState(service: $0)) }
    )

    public init() {}

    public func state(for service: ServiceKind) -> ServiceState {
        reconcile(service)
        return states[service] ?? ServiceState(service: service)
    }

    public func allStates() -> [ServiceState] {
        for service in ServiceKind.allCases { reconcile(service) }
        return ServiceKind.allCases.compactMap { states[$0] }
    }

    public func start(_ specification: ServiceSpecification) async throws {
        reconcile(specification.kind)
        if processes[specification.kind]?.isRunning == true { return }
        transition(specification.kind, to: .starting)

        do {
            try FileManager.default.createDirectory(at: specification.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: specification.logFile.path) {
                FileManager.default.createFile(atPath: specification.logFile.path, contents: nil)
            }
            let logHandle = try FileHandle(forWritingTo: specification.logFile)
            try logHandle.seekToEnd()

            let process = Process()
            process.executableURL = specification.executable
            process.arguments = specification.arguments
            process.environment = ProcessInfo.processInfo.environment.merging(specification.environment) { _, new in new }
            process.currentDirectoryURL = specification.currentDirectory
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()

            processes[specification.kind] = process
            logHandles[specification.kind] = logHandle
            let deadline = Date().addingTimeInterval(specification.readinessTimeout)
            while Date() < deadline {
                if !process.isRunning {
                    throw ServiceFailure(
                        message: "Service exited before it became ready.",
                        exitCode: process.terminationStatus,
                        failedProbe: String(describing: specification.readinessProbe),
                        recoveryAction: "Open the service log and validate generated configuration."
                    )
                }
                if probe(specification.readinessProbe) {
                    states[specification.kind] = ServiceState(service: specification.kind, phase: .running, pid: process.processIdentifier)
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ServiceFailure(
                message: "Service did not become ready in time.",
                failedProbe: String(describing: specification.readinessProbe),
                recoveryAction: "Check for port conflicts and review the service log."
            )
        } catch {
            if let process = processes.removeValue(forKey: specification.kind), process.isRunning {
                process.terminate()
            }
            try? logHandles.removeValue(forKey: specification.kind)?.close()
            let failure = (error as? ServiceFailure) ?? ServiceFailure(message: error.localizedDescription)
            states[specification.kind] = ServiceState(service: specification.kind, phase: .failed, failure: failure)
            throw failure
        }
    }

    public func stop(_ service: ServiceKind, timeout: TimeInterval = 8) {
        guard let process = processes[service] else {
            transition(service, to: .stopped)
            return
        }
        transition(service, to: .stopping, pid: process.processIdentifier)
        if process.isRunning { process.interrupt() }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        processes.removeValue(forKey: service)
        try? logHandles.removeValue(forKey: service)?.close()
        transition(service, to: .stopped)
    }

    public func stopAll() {
        for service in ServiceKind.allCases.reversed() { stop(service) }
    }

    private func reconcile(_ service: ServiceKind) {
        guard let process = processes[service] else { return }
        if !process.isRunning {
            let code = process.terminationStatus
            processes.removeValue(forKey: service)
            try? logHandles.removeValue(forKey: service)?.close()
            if states[service]?.phase == .stopping || code == 0 {
                transition(service, to: .stopped)
            } else {
                states[service] = ServiceState(
                    service: service,
                    phase: .failed,
                    failure: ServiceFailure(message: "Service exited unexpectedly.", exitCode: code)
                )
            }
        }
    }

    private func transition(_ service: ServiceKind, to phase: ServicePhase, pid: Int32? = nil) {
        states[service] = ServiceState(service: service, phase: phase, pid: pid)
    }

    private func probe(_ probe: ReadinessProbe) -> Bool {
        switch probe {
        case .processAlive:
            return true
        case .fileExists(let url):
            return FileManager.default.fileExists(atPath: url.path)
        case .tcpLoopback(let port):
            return canConnectToLoopback(port: port)
        }
    }

    private func canConnectToLoopback(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

