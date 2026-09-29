import Foundation

public enum DatabaseManagerError: LocalizedError, Sendable {
    case unsafeDatabaseName(String)
    case sourceFileMissing(String)
    case dataDirectoryMissing(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeDatabaseName(let name): "Invalid database name: \(name)"
        case .sourceFileMissing(let path): "SQL source file does not exist: \(path)"
        case .dataDirectoryMissing(let path): "Database data directory does not exist: \(path)"
        }
    }
}

public struct DatabaseManager: Sendable {
    public let paths: DevStackPaths
    public let runtimeRoot: URL
    private let runner: ProcessRunner

    public init(paths: DevStackPaths, runtimeRoot: URL, runner: ProcessRunner = ProcessRunner()) {
        self.paths = paths
        self.runtimeRoot = runtimeRoot
        self.runner = runner
    }

    public func initializeIfNeeded(_ engine: DatabaseEngine) throws -> Bool {
        let dataDirectory = dataDirectory(for: engine)
        let initializedMarker = dataDirectory.appendingPathComponent("mysql", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: initializedMarker.path) else { return false }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let runtime = runtimeRoot.appendingPathComponent(engine.rawValue)
        _ = try runner.runChecked(
            executable: runtime.appendingPathComponent("bin/mysqld"),
            arguments: [
                "--no-defaults", "--initialize-insecure",
                "--basedir=\(runtime.path)", "--datadir=\(dataDirectory.path)"
            ],
            timeout: 300
        )
        return true
    }

    public func configureDevelopmentRootPassword(_ engine: DatabaseEngine) throws {
        let sql = engine == .mysql84
            ? "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'root'; FLUSH PRIVILEGES;"
            : "ALTER USER 'root'@'localhost' IDENTIFIED BY 'root'; FLUSH PRIVILEGES;"
        _ = try runner.runChecked(
            executable: client(engine, name: "mysql"),
            arguments: connectionArguments(passwordConfigured: false) + ["--execute", sql],
            timeout: 60
        )
    }

    public func ping(_ engine: DatabaseEngine) -> Bool {
        guard let result = try? runner.run(
            executable: client(engine, name: "mysqladmin"),
            arguments: connectionArguments(passwordConfigured: true) + ["ping"],
            environment: ["MYSQL_PWD": "root"],
            timeout: 5
        ) else { return false }
        return result.exitCode == 0
    }

    @discardableResult
    public func exportSQL(_ engine: DatabaseEngine, database: String? = nil, destination: URL? = nil) throws -> URL {
        if let database { try validateDatabaseName(database) }
        try FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        let target = destination ?? paths.backups.appendingPathComponent(backupFilename(engine: engine, database: database))
        var arguments = connectionArguments(passwordConfigured: true) + ["--single-transaction", "--routines", "--events", "--triggers"]
        if let database { arguments.append(database) } else { arguments.append("--all-databases") }
        let result = try runner.runChecked(
            executable: client(engine, name: "mysqldump"),
            arguments: arguments,
            environment: ["MYSQL_PWD": "root"],
            timeout: 3_600
        )
        try AtomicFileWriter.write(result.standardOutput, to: target, permissions: 0o600)
        return target
    }

    public func importSQL(_ engine: DatabaseEngine, source: URL, database: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { throw DatabaseManagerError.sourceFileMissing(source.path) }
        if let database { try validateDatabaseName(database) }
        let input = try Data(contentsOf: source, options: .mappedIfSafe)
        var arguments = connectionArguments(passwordConfigured: true)
        if let database { arguments.append(database) }
        _ = try runner.runChecked(
            executable: client(engine, name: "mysql"),
            arguments: arguments,
            standardInput: input,
            environment: ["MYSQL_PWD": "root"],
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
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private func client(_ engine: DatabaseEngine, name: String) -> URL {
        runtimeRoot.appendingPathComponent("\(engine.rawValue)/bin/\(name)")
    }

    private func dataDirectory(for engine: DatabaseEngine) -> URL {
        engine == .mysql57 ? paths.mysql57Data : paths.mysql84Data
    }

    private func connectionArguments(passwordConfigured: Bool) -> [String] {
        var result = ["--protocol=TCP", "--host=127.0.0.1", "--port=3306", "--user=root"]
        if !passwordConfigured { result.append("--skip-password") }
        return result
    }

    private func validateDatabaseName(_ name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DatabaseManagerError.unsafeDatabaseName(name)
        }
    }
}
