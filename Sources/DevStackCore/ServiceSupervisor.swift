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
    private struct ProcessRecord: Codable {
        let pid: Int32
        let executable: String
        let uid: UInt32
        let startedSeconds: UInt64
        let startedMicroseconds: UInt64
    }
    private var records: [ServiceKind: ProcessRecord] = [:]
    private let recordsURL: URL?
    private var processes: [ServiceKind: Process] = [:]
    private var logHandles: [ServiceKind: FileHandle] = [:]
    private var states: [ServiceKind: ServiceState] = Dictionary(
        uniqueKeysWithValues: ServiceKind.allCases.map { ($0, ServiceState(service: $0)) }
    )

    public init(recordsURL: URL? = nil) {
        self.recordsURL = recordsURL
        if let recordsURL, let data = try? Data(contentsOf: recordsURL),
           let saved = try? JSONDecoder().decode([ServiceKind: ProcessRecord].self, from: data) {
            records = saved
        }
    }

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
        if states[specification.kind]?.phase == .running { return }
        transition(specification.kind, to: .starting)

        do {
            if case .tcpLoopback(let port) = specification.readinessProbe, probe(specification.readinessProbe) {
                throw PortConflict(port: port, service: specification.kind, owner: PortOwner.lookup(port: port)).failure
            }
            try FileManager.default.createDirectory(at: specification.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            // O_APPEND: when the log is truncated by rotation, the service keeps
            // writing at the new end instead of its old offset, which would
            // leave a zero-filled gap.
            let descriptor = open(specification.logFile.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

            let process = Process()
            process.executableURL = specification.executable
            process.arguments = specification.arguments
            process.environment = ProcessInfo.processInfo.environment.merging(specification.environment) { _, new in new }
            process.currentDirectoryURL = specification.currentDirectory
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()

            guard let record = processRecord(pid: process.processIdentifier, executable: specification.executable) else {
                process.terminate()
                throw ServiceFailure(message: "Could not verify service process ownership.")
            }
            records[specification.kind] = record
            persistRecords(for: specification.kind)
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
            records.removeValue(forKey: specification.kind)
            persistRecords(for: specification.kind)
            try? logHandles.removeValue(forKey: specification.kind)?.close()
            var failure = (error as? ServiceFailure) ?? ServiceFailure(message: error.localizedDescription)
            if let data = try? Data(contentsOf: specification.logFile) {
                failure.logExcerpt = String(decoding: data.suffix(2_000), as: UTF8.self)
            }
            states[specification.kind] = ServiceState(service: specification.kind, phase: .failed, failure: failure)
            throw failure
        }
    }

    public func stop(_ service: ServiceKind, timeout: TimeInterval = 8) async {
        reconcile(service)
        guard let record = records[service], owns(record) else {
            transition(service, to: .stopped)
            return
        }
        transition(service, to: .stopping, pid: record.pid)
        kill(record.pid, service == .nginx ? SIGQUIT : service == .postgresql18 ? SIGINT : SIGTERM)
        let deadline = Date().addingTimeInterval(timeout)
        while owns(record) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if owns(record) { kill(record.pid, SIGKILL) }
        // Foundation's waitUntilExit can stall on a cooperative executor after
        // repeated launches. Ownership polling above is the bounded exit check.
        let killDeadline = Date().addingTimeInterval(2)
        while owns(record) && Date() < killDeadline { try? await Task.sleep(for: .milliseconds(50)) }
        if owns(record) {
            states[service] = ServiceState(service: service, phase: .failed, pid: record.pid,
                failure: ServiceFailure(message: "The service did not exit after its shutdown deadline.", recoveryAction: "Inspect its log before retrying Stop."))
            return
        }
        processes.removeValue(forKey: service)
        records.removeValue(forKey: service)
        persistRecords(for: service)
        try? logHandles.removeValue(forKey: service)?.close()
        transition(service, to: .stopped)
    }

    /// Front to back: the web servers stop taking requests before the PHP
    /// pools, mail and databases behind them go away.
    public func stopAll() async {
        for service in ServiceKind.allCases.sorted(by: { Self.shutdownTier($0) < Self.shutdownTier($1) }) {
            await stop(service)
        }
    }

    private static func shutdownTier(_ service: ServiceKind) -> Int {
        switch service {
        case .apache, .nginx: 0
        case .php74, .php84, .php85: 1
        case .mailpit: 2
        case .mysql57, .mysql84, .postgresql18: 3
        }
    }

    public func reload(_ service: ServiceKind) throws {
        reconcile(service)
        guard let record = records[service], owns(record) else { return }
        guard kill(record.pid, service.phpRuntimeID == nil ? SIGHUP : SIGUSR2) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func processRecord(pid: Int32, executable: URL) -> ProcessRecord? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == MemoryLayout<proc_bsdinfo>.size, info.pbi_uid == getuid() else { return nil }
        return ProcessRecord(pid: pid, executable: executable.resolvingSymlinksInPath().path, uid: info.pbi_uid,
                             startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    private func owns(_ record: ProcessRecord) -> Bool {
        guard let actual = processRecord(pid: record.pid, executable: URL(fileURLWithPath: record.executable)),
              actual.uid == record.uid, actual.startedSeconds == record.startedSeconds,
              actual.startedMicroseconds == record.startedMicroseconds else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(record.pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == record.executable
    }

    private func persistRecords(for service: ServiceKind) {
        guard let recordsURL else { return }
        var saved = records
        if let data = try? Data(contentsOf: recordsURL), let latest = try? JSONDecoder().decode([ServiceKind: ProcessRecord].self, from: data) {
            saved = latest
            saved[service] = records[service]
        }
        do { try AtomicFileWriter.write(try JSONEncoder().encode(saved), to: recordsURL, permissions: 0o600) }
        catch { /* A failed write cannot authorize signalling a different process. */ }
    }

    private func wasStoppedByAnotherSupervisor(_ service: ServiceKind) -> Bool {
        guard let recordsURL, let data = try? Data(contentsOf: recordsURL),
              let saved = try? JSONDecoder().decode([ServiceKind: ProcessRecord].self, from: data) else { return false }
        return saved[service] == nil
    }

    private func reconcile(_ service: ServiceKind) {
        guard let process = processes[service] else {
            if let record = records[service] {
                if owns(record) {
                    if states[service]?.phase != .stopping {
                        states[service] = ServiceState(service: service, phase: .running, pid: record.pid)
                    }
                } else {
                    records.removeValue(forKey: service)
                    persistRecords(for: service)
                    transition(service, to: .stopped)
                }
            }
            return
        }
        if !process.isRunning {
            let externallyStopped = wasStoppedByAnotherSupervisor(service)
            let code = process.terminationStatus
            processes.removeValue(forKey: service)
            records.removeValue(forKey: service)
            persistRecords(for: service)
            try? logHandles.removeValue(forKey: service)?.close()
            if states[service]?.phase == .stopping || code == 0 || externallyStopped {
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
            return PortAvailability.isListening(port)
        }
    }
}
