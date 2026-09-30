import Darwin
import Foundation

public struct PostgreSQLManager: Sendable {
    public let paths: DevStackPaths
    public let runtime: URL
    public let port: UInt16
    private let runner: ProcessRunner
    public var environment: [String: String] {
        RuntimeEnvironment.openssl(at: opensslRuntime).merging([
            "PGHOST": "127.0.0.1", "PGPORT": "\(port)", "PGUSER": "devstack",
            "PGPASSWORD": "devstack", "PGDATABASE": "postgres", "PGCONNECT_TIMEOUT": "5",
            "PGPASSFILE": paths.generatedPostgreSQL.appendingPathComponent("pgpass").path,
            "PGSERVICEFILE": paths.generatedPostgreSQL.appendingPathComponent("pg_service.conf").path,
            "PGSSLROOTCERT": paths.certificates.appendingPathComponent("DevStack-Local-CA.pem").path,
            "PGSSLCERT": paths.generatedPostgreSQL.appendingPathComponent("client.pem").path,
            "PGSSLKEY": paths.generatedPostgreSQL.appendingPathComponent("client-key.pem").path,
            "LC_ALL": "en_US.UTF-8"
        ]) { _, new in new }
    }
    private let opensslRuntime: URL

    public init(paths: DevStackPaths, runtime: URL, opensslRuntime: URL? = nil, runner: ProcessRunner = ProcessRunner(), port: UInt16 = ServicePorts.postgresqlFallback) {
        self.paths = paths; self.runtime = runtime; self.port = port; self.runner = runner
        self.opensslRuntime = opensslRuntime ?? paths.builtInRuntimes.appendingPathComponent("openssl-3.5")
    }

    @discardableResult public func initializeIfNeeded() throws -> Bool {
        if FileManager.default.fileExists(atPath: paths.postgresql18Data.appendingPathComponent("PG_VERSION").path) { return false }
        try paths.createRequiredDirectories()
        // Initialize beside the final directory so an interrupted initdb is never reused.
        let staged = paths.databases.appendingPathComponent(".postgresql-init-\(UUID().uuidString)")
        let password = paths.generatedPostgreSQL.appendingPathComponent(".password-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged); try? FileManager.default.removeItem(at: password) }
        try AtomicFileWriter.write("devstack\n", to: password, permissions: 0o600)
        _ = try runner.runChecked(executable: runtime.appendingPathComponent("bin/initdb"),
            arguments: ["-D", staged.path, "-L", runtime.appendingPathComponent("share").path,
                "-U", "devstack", "--pwfile", password.path, "--auth-host=scram-sha-256", "--auth-local=scram-sha-256",
                "--encoding=UTF8", "--locale=en_US.UTF-8"], environment: environment, timeout: 120)
        try FileManager.default.moveItem(at: staged, to: paths.postgresql18Data)
        return true
    }

    public func writeConfiguration() throws {
        try paths.createRequiredDirectories()
        func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "''") + "'" }
        let configuration = """
        data_directory = \(quote(paths.postgresql18Data.path))
        hba_file = \(quote(paths.postgresql18Data.appendingPathComponent("pg_hba.conf").path))
        ident_file = \(quote(paths.postgresql18Data.appendingPathComponent("pg_ident.conf").path))
        listen_addresses = '127.0.0.1'
        port = \(port)
        unix_socket_directories = \(quote(paths.sockets.path))
        unix_socket_permissions = 0700
        max_connections = 32
        shared_buffers = '64MB'
        work_mem = '4MB'
        maintenance_work_mem = '64MB'
        huge_pages = off
        password_encryption = 'scram-sha-256'
        dynamic_library_path = \(quote(runtime.appendingPathComponent("lib").path))
        log_destination = 'stderr'
        logging_collector = off
        log_line_prefix = '%m [%p] '
        ssl = on
        ssl_cert_file = \(quote(paths.certificate(for: "postgresql.localhost").path))
        ssl_key_file = \(quote(paths.privateKey(for: "postgresql.localhost").path))
        ssl_min_protocol_version = 'TLSv1.2'
        """
        try AtomicFileWriter.write(configuration, to: configurationFile, permissions: 0o600)
        try AtomicFileWriter.write("127.0.0.1:\(port):*:devstack:devstack\n", to: paths.generatedPostgreSQL.appendingPathComponent("pgpass"), permissions: 0o600)
        try AtomicFileWriter.write("", to: paths.generatedPostgreSQL.appendingPathComponent("pg_service.conf"), permissions: 0o600)
    }
    public var configurationFile: URL { paths.generatedPostgreSQL.appendingPathComponent("postgresql.conf") }
    public var specification: ServiceSpecification {
        ServiceSpecification(kind: .postgresql18, executable: runtime.appendingPathComponent("bin/postgres"),
            arguments: ["-D", paths.postgresql18Data.path, "-c", "config_file=\(configurationFile.path)"], environment: environment,
            logFile: paths.logs.appendingPathComponent("postgresql-18.log"), readinessProbe: .tcpLoopback(port: port), readinessTimeout: 30)
    }
    public func query(_ sql: String, database: String = "postgres") throws -> String {
        try runner.runChecked(executable: runtime.appendingPathComponent("bin/psql"),
            arguments: ["-X", "-w", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-d", database, "-c", sql], environment: environment, timeout: 30).standardOutput
    }
    public func ping() -> Bool { (try? query("SELECT 1").trimmingCharacters(in: .whitespacesAndNewlines)) == "1" }
    public func backupFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "postgresql-18-all-databases-\(formatter.string(from: date)).sql"
    }
    @discardableResult public func exportSQL(destination: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let target = destination ?? paths.backups.appendingPathComponent(backupFilename())
        let staged = target.deletingLastPathComponent().appendingPathComponent(".postgresql-export-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: staged) }
        // Skip password hashes; the managed account keeps its existing credentials on restore.
        _ = try runner.runChecked(executable: runtime.appendingPathComponent("bin/pg_dumpall"),
            arguments: ["--no-password", "--no-role-passwords", "--clean", "--if-exists", "--exclude-database=template1"], standardOutputFile: staged, environment: environment, timeout: 3600)
        let filtered = target.deletingLastPathComponent().appendingPathComponent(".postgresql-filtered-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: filtered) }
        try filterManagedRoleDeclarations(source: staged, destination: filtered)
        guard rename(filtered.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return target
    }
    private func filterManagedRoleDeclarations(source: URL, destination: URL) throws {
        // Restoring cannot drop the account performing the restore. Preserve that
        // account while the upstream dump restores all other roles and databases.
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var pending = Data()
        let omitted = Set(["DROP ROLE IF EXISTS devstack;", "CREATE ROLE devstack;"])
        while let block = try input.read(upToCount: 65_536), !block.isEmpty {
            pending.append(block)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                if !omitted.contains(String(decoding: line, as: UTF8.self)) { try output.write(contentsOf: pending.prefix(through: newline)) }
                pending.removeSubrange(...newline)
            }
            if pending.count > 1_048_576 { try output.write(contentsOf: pending); pending.removeAll(keepingCapacity: true) }
        }
        if !pending.isEmpty { try output.write(contentsOf: pending) }
        try output.synchronize()
    }

    public func importSQL(source: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { throw DatabaseManagerError.sourceFileMissing(source.path) }
        _ = try runner.runChecked(executable: runtime.appendingPathComponent("bin/psql"),
            arguments: ["-X", "-w", "-d", "template1", "-v", "ON_ERROR_STOP=1"], standardInputFile: source, environment: environment, timeout: 3600)
    }
}
