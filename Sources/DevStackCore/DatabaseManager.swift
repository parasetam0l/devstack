import Darwin
import Foundation

public enum DatabaseManagerError: LocalizedError, Sendable {
    case engineNotSelected
    case unsafeDatabaseName(String)
    case sourceFileMissing(String)
    case dataDirectoryMissing(String)
    case unusablePassword

    public var errorDescription: String? {
        switch self {
        case .engineNotSelected: "Select a MySQL version before using its database tools."
        case .unsafeDatabaseName(let name): "Invalid database name: \(name)"
        case .sourceFileMissing(let path): "SQL source file does not exist: \(path)"
        case .dataDirectoryMissing(let path): "Database data directory does not exist: \(path)"
        case .unusablePassword: "The MySQL root password may only use printable characters without quotes, backslashes, backticks or $."
        }
    }
}

public struct DatabaseManager: Sendable {
    public let paths: DevStackPaths
    public let runtimeRoot: URL
    public let port: UInt16
    /// The development root password; empty for none.
    public let rootPassword: String
    private let runner: ProcessRunner
    private let environment: [String: String]

    public init(paths: DevStackPaths, runtimeRoot: URL, runner: ProcessRunner = ProcessRunner(), opensslRuntime: URL? = nil,
                port: UInt16 = ServicePorts.mysqlFallback, rootPassword: String = "root") {
        self.paths = paths
        self.runtimeRoot = runtimeRoot
        self.runner = runner
        self.port = port
        self.rootPassword = rootPassword
        self.environment = RuntimeEnvironment.openssl(at: opensslRuntime ?? runtimeRoot.appendingPathComponent("openssl-3.5"))
    }

    public func initializeIfNeeded(_ engine: DatabaseEngine) throws -> Bool {
        guard engine != .none else { throw DatabaseManagerError.engineNotSelected }
        let dataDirectory = dataDirectory(for: engine)
        let initializedMarker = dataDirectory.appendingPathComponent("mysql", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: initializedMarker.path) else {
            return !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent(".devstack-root-configured").path)
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let runtime = runtimeRoot.appendingPathComponent(engine.rawValue)
        _ = try runner.runChecked(
            executable: runtime.appendingPathComponent("bin/mysqld"),
            arguments: [
                "--no-defaults", "--initialize-insecure",
                "--basedir=\(runtime.path)", "--datadir=\(dataDirectory.path)"
            ],
            environment: environment, timeout: 300
        )
        return true
    }

    public func configureDevelopmentRootPassword(_ engine: DatabaseEngine) throws {
        guard engine != .none else { throw DatabaseManagerError.engineNotSelected }
        let marker = dataDirectory(for: engine).appendingPathComponent(".devstack-root-configured")
        if ping(engine) { try AtomicFileWriter.write("configured\n", to: marker, permissions: 0o600); return }
        guard MySQLSettings.isUsablePassword(rootPassword) || rootPassword.isEmpty else { throw DatabaseManagerError.unusablePassword }
        let sql = engine == .mysql84
            ? "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '\(rootPassword)'; FLUSH PRIVILEGES;"
            : "ALTER USER 'root'@'localhost' IDENTIFIED BY '\(rootPassword)'; FLUSH PRIVILEGES;"
        _ = try runner.runChecked(
            executable: client(engine, name: "mysql"),
            arguments: connectionArguments(engine, passwordConfigured: false) + ["--execute", sql],
            environment: environment, timeout: 60
        )
        try AtomicFileWriter.write("configured\n", to: marker, permissions: 0o600)
    }

    public func ping(_ engine: DatabaseEngine) -> Bool {
        guard engine != .none else { return false }
        guard let result = try? runner.run(
            executable: client(engine, name: "mysql"),
            arguments: connectionArguments(engine, passwordConfigured: true) + ["--batch", "--skip-column-names", "--execute", "SELECT 1"],
            environment: passwordEnvironment,
            timeout: 5
        ) else { return false }
        return result.exitCode == 0 && result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    @discardableResult
    public func exportSQL(_ engine: DatabaseEngine, database: String? = nil, destination: URL? = nil) throws -> URL {
        guard engine != .none else { throw DatabaseManagerError.engineNotSelected }
        if let database { try validateDatabaseName(database) }
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let target = destination ?? paths.backups.appendingPathComponent(backupFilename(engine: engine, database: database))
        var arguments = connectionArguments(engine, passwordConfigured: true) + ["--single-transaction", "--routines", "--events", "--triggers"]
        if let database { arguments.append(database) } else { arguments.append("--all-databases") }
        let staged = target.deletingLastPathComponent().appendingPathComponent(".devstack-export-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try runner.runChecked(
            executable: client(engine, name: "mysqldump"),
            arguments: arguments,
            standardOutputFile: staged,
            environment: passwordEnvironment,
            timeout: 3_600
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        guard rename(staged.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return target
    }

    public func importSQL(_ engine: DatabaseEngine, source: URL, database: String? = nil) throws {
        guard engine != .none else { throw DatabaseManagerError.engineNotSelected }
        guard FileManager.default.fileExists(atPath: source.path) else { throw DatabaseManagerError.sourceFileMissing(source.path) }
        if let database { try validateDatabaseName(database) }
        var arguments = connectionArguments(engine, passwordConfigured: true)
        if let database { arguments.append(database) }
        _ = try runner.runChecked(
            executable: client(engine, name: "mysql"),
            arguments: arguments,
            standardInputFile: source,
            environment: passwordEnvironment,
            timeout: 3_600
        )
    }

    public func backupFilename(engine: DatabaseEngine, database: String?, date: Date = Date()) -> String {
        let scope = database ?? "all-databases"
        return "\(engine.rawValue)-\(scope)-\(timestamp(date)).sql"
    }

    public func archiveDataDirectoryName(engine: DatabaseEngine, date: Date = Date()) -> String {
        "\(engine.rawValue)-data-\(timestamp(date))"
    }

    public func dataDirectoryURL(_ engine: DatabaseEngine) -> URL {
        dataDirectory(for: engine)
    }

    @discardableResult
    public func archiveDataDirectory(_ engine: DatabaseEngine, date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let source = dataDirectory(for: engine)
        guard fileManager.fileExists(atPath: source.path) else {
            throw DatabaseManagerError.dataDirectoryMissing(source.path)
        }
        try fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let destination = paths.backups.appendingPathComponent(archiveDataDirectoryName(engine: engine, date: date), isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try fileManager.moveItem(at: source, to: destination)
        return destination
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    /// Runs `sql` as root and returns the rows, tab-separated as the
    /// client prints them in batch mode.
    public func query(_ engine: DatabaseEngine, _ sql: String, database: String? = nil, timeout: TimeInterval = 600) throws -> [[String]] {
        guard engine != .none else { throw DatabaseManagerError.engineNotSelected }
        var arguments = connectionArguments(engine, passwordConfigured: true) + ["--batch", "--skip-column-names", "--default-character-set=utf8mb4", "--execute", sql]
        if let database { arguments.append(database) }
        let result = try runner.runChecked(executable: client(engine, name: "mysql"), arguments: arguments, environment: passwordEnvironment, timeout: timeout)
        return MySQLBatchOutput.rows(result.standardOutput)
    }

    /// The client and the arguments that connect it as root, for callers that
    /// stream SQL themselves.
    public func clientInvocation(_ engine: DatabaseEngine) -> (executable: URL, arguments: [String], environment: [String: String]) {
        (client(engine, name: "mysql"), connectionArguments(engine, passwordConfigured: true), passwordEnvironment)
    }

    private var passwordEnvironment: [String: String] {
        rootPassword.isEmpty ? environment : environment.merging(["MYSQL_PWD": rootPassword]) { _, new in new }
    }

    private func client(_ engine: DatabaseEngine, name: String) -> URL {
        runtimeRoot.appendingPathComponent("\(engine.rawValue)/bin/\(name)")
    }

    private func dataDirectory(for engine: DatabaseEngine) -> URL {
        engine == .mysql57 ? paths.mysql57Data : paths.mysql84Data
    }

    private func connectionArguments(_ engine: DatabaseEngine, passwordConfigured: Bool) -> [String] {
        var result = ["--no-defaults",
            "--character-sets-dir=\(runtimeRoot.appendingPathComponent("\(engine.rawValue)/share/charsets").path)",
            "--plugin-dir=\(runtimeRoot.appendingPathComponent("\(engine.rawValue)/lib/plugin").path)",
            "--protocol=TCP", "--host=127.0.0.1", "--port=\(port)", "--user=root"]
        if !passwordConfigured || rootPassword.isEmpty { result.append("--skip-password") }
        return result
    }

    private func validateDatabaseName(_ name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DatabaseManagerError.unsafeDatabaseName(name)
        }
    }
}

/// Rows of the mysql client's batch output: one line per row, tab-separated,
/// with tabs, newlines and backslashes in values escaped.
public enum MySQLBatchOutput {
    public static func rows(_ output: String) -> [[String]] {
        output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
        }
    }

    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "0": result.append("\0")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
