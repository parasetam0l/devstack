import Darwin
import Foundation

public enum MariaDBReaderError: LocalizedError, Sendable {
    case serverExited(String)
    case serverTimedOut(String)
    case dumpFailed(String, String)
    case upgradeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .upgradeFailed(let detail): "Couldn't upgrade the system tables: \(detail)"
        case .serverExited(let log): "MariaDB stopped while starting. Its log ends with:\n\(log)"
        case .serverTimedOut(let log): "MariaDB did not become ready in time. Its log ends with:\n\(log)"
        case .dumpFailed(let database, let detail): "Couldn't export \(database): \(detail)"
        }
    }

    /// The log suggests InnoDB could not recover its data, which a recovery
    /// mode may get past.
    public var suggestsRecovery: Bool {
        let log: String
        switch self {
        case .serverExited(let text), .serverTimedOut(let text): log = text.lowercased()
        case .dumpFailed, .upgradeFailed: return false
        }
        return log.contains("innodb") && (log.contains("corrupt") || log.contains("recovery") || log.contains("redo log")
            || log.contains("plugin 'innodb' init function returned error") || log.contains("assertion"))
    }
}

/// The server and client programs of the other app's MariaDB.
public struct MariaDBTools: Sendable {
    public var mysqld: URL
    public var mysql: URL
    public var mysqldump: URL
    public var baseDirectory: URL

    public init(mysqld: URL, mysql: URL, mysqldump: URL, baseDirectory: URL) {
        self.mysqld = mysqld
        self.mysql = mysql
        self.mysqldump = mysqldump
        self.baseDirectory = baseDirectory
    }

    public init(installation: XAMPPInstallation) {
        self.init(mysqld: installation.mysqld, mysql: installation.mysqlClient, mysqldump: installation.mysqldump, baseDirectory: installation.root)
    }

    /// mysql_upgrade, beside the client.
    var upgrade: URL? {
        let bin = mysql.deletingLastPathComponent()
        return ["mysql_upgrade", "mariadb-upgrade"].map { bin.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The folder holding english/errmsg.sys, which the server needs for its
    /// messages.
    var messagesDirectory: URL? {
        let share = baseDirectory.appendingPathComponent("share", isDirectory: true)
        for candidate in [share, share.appendingPathComponent("mysql"), share.appendingPathComponent("mariadb")]
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("english/errmsg.sys").path) {
            return candidate
        }
        return nil
    }
}

/// A private MariaDB server on a copy of another app's data folder. It has
/// no network port (so ports held by Docker or DevStack don't matter) and no
/// grant tables (so the other app's root password doesn't matter), and it
/// only ever sees the copy.
public final class TemporaryMariaDB: @unchecked Sendable {
    public let tools: MariaDBTools
    public let dataDirectory: URL
    public let workDirectory: URL
    public let socket: URL
    private let serverSettings: [(key: String, value: String)]
    private let lock = NSLock()
    private var process: Process?

    /// Settings from the other app's my.cnf that decide how the data files
    /// are read; everything else (ports, paths, users, logging) is DevStack's.
    static let carriedSettings: Set<String> = [
        "innodb_data_file_path", "innodb_log_file_size", "innodb_log_files_in_group", "innodb_page_size",
        "innodb_file_per_table", "innodb_checksum_algorithm", "innodb_undo_tablespaces", "innodb_default_row_format",
        "character_set_server", "collation_server", "lower_case_table_names", "sql_mode", "default_storage_engine",
        "plugin_dir", "aria_log_file_size"
    ]

    public init(tools: MariaDBTools, dataDirectory: URL, workDirectory: URL, socket: URL, serverSettings: [(key: String, value: String)] = []) {
        self.tools = tools
        self.dataDirectory = dataDirectory
        self.workDirectory = workDirectory
        self.socket = socket
        self.serverSettings = serverSettings
    }

    public var logFile: URL { workDirectory.appendingPathComponent("mariadb.log") }
    var defaultsFile: URL { workDirectory.appendingPathComponent("mariadb.cnf") }

    public func defaults(forceRecovery: Int = 0, checkPasswords: Bool = false) -> String {
        var lines = [
            "[mysqld]",
            "basedir=\(tools.baseDirectory.path)",
            "datadir=\(dataDirectory.path)",
            "innodb_data_home_dir=\(dataDirectory.path)",
            "innodb_log_group_home_dir=\(dataDirectory.path)",
            "socket=\(socket.path)",
            "pid-file=\(workDirectory.appendingPathComponent("mariadb.pid").path)",
            "log-error=\(logFile.path)",
            "tmpdir=\(workDirectory.appendingPathComponent("tmp").path)",
            "skip-networking",
            "loose-skip-log-bin",
            "loose-skip-slave-start",
            "loose-skip-name-resolve",
            "loose-innodb_buffer_pool_size=256M",
            "max_allowed_packet=1G"
        ]
        if let messages = tools.messagesDirectory { lines.append("lc-messages-dir=\(messages.path)") }
        for setting in serverSettings where Self.carriedSettings.contains(INIFile.optionName(setting.key)) {
            let name = INIFile.optionName(setting.key)
            if name == "plugin_dir", !FileManager.default.fileExists(atPath: setting.value) { continue }
            lines.append(setting.value.isEmpty ? name : "\(name)=\(setting.value)")
        }
        // Without grant tables any password works, but the server hides
        // events; with them, root must sign in without one.
        if !checkPasswords { lines.append("skip-grant-tables") }
        if forceRecovery > 0 { lines.append("innodb_force_recovery=\(forceRecovery)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Starts the server and waits until it answers. InnoDB replays its log
    /// first when the other app did not stop cleanly, which can take a while.
    public func start(forceRecovery: Int = 0, checkPasswords: Bool = false, timeout: TimeInterval = 600, isCancelled: () -> Bool = { false }) throws {
        try FileManager.default.createDirectory(at: workDirectory.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: socket)
        try defaults(forceRecovery: forceRecovery, checkPasswords: checkPasswords).write(to: defaultsFile, atomically: true, encoding: .utf8)
        // The copy carries the other server's lock and pid files.
        for name in ["mysql.sock", "mysql.sock.lock"] { try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(name)) }
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)) ?? [] where entry.hasSuffix(".pid") {
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(entry))
        }

        let process = Process()
        process.executableURL = tools.mysqld
        process.arguments = ["--defaults-file=\(defaultsFile.path)"]
        process.standardInput = FileHandle.nullDevice
        let outputURL = URL(fileURLWithPath: logFile.path + ".out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        lock.withLock { self.process = process }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCancelled() { stop(); throw CancellationError() }
            if !process.isRunning {
                try? output.close()
                throw MariaDBReaderError.serverExited(logTail())
            }
            if FileManager.default.fileExists(atPath: socket.path), (try? query("SELECT 1", timeout: 15)) == [["1"]] {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        stop()
        throw MariaDBReaderError.serverTimedOut(logTail())
    }

    /// Stops the server cleanly, or forcibly after a minute.
    public func stop() {
        guard let process = lock.withLock({ self.process }) else { return }
        if process.isRunning {
            kill(process.processIdentifier, SIGTERM)
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        lock.withLock { self.process = nil }
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    /// The server's own version, such as "10.4.28-MariaDB".
    public func version() -> String? { (try? query("SELECT VERSION()"))?.first?.first }

    /// The data's system tables are older than the server: XAMPP was
    /// updated without mysql_upgrade, so mysql.proc and mysql.event have an
    /// old layout and routines and events can't be read.
    public func systemTablesNeedUpgrade() -> Bool {
        let recorded = ["mysql_upgrade_info", "mariadb_upgrade_info"]
            .compactMap { try? String(contentsOf: dataDirectory.appendingPathComponent($0), encoding: .utf8) }.first
        if let recorded, let server = version(), MariaDBVersion.majorMinor(recorded) != MariaDBVersion.majorMinor(server) {
            return true
        }
        return (try? query("SELECT COUNT(*) FROM information_schema.ROUTINES")) == nil
    }

    /// Brings the copy's system tables up to the server's version with
    /// XAMPP's own mysql_upgrade. Only the mysql database changes, and only
    /// in the copy. Afterwards the server checks passwords, so it needs a
    /// restart in the wanted mode.
    public func upgradeSystemTables() throws {
        guard let upgrade = tools.upgrade else { throw MariaDBReaderError.upgradeFailed("mysql_upgrade is missing.") }
        let result = try ProcessRunner().run(executable: upgrade, arguments: [
            "--no-defaults", "--socket=\(socket.path)", "--user=root", "--force", "--upgrade-system-tables"
        ], timeout: 900)
        guard result.exitCode == 0 else {
            let output = (result.standardError + "\n" + result.standardOutput).split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
            throw MariaDBReaderError.upgradeFailed(output)
        }
    }

    private var clientArguments: [String] {
        ["--no-defaults", "--socket=\(socket.path)", "--user=root", "--default-character-set=utf8mb4"]
    }

    /// Rows of a query, as the client prints them in batch mode.
    public func query(_ sql: String, timeout: TimeInterval = 600) throws -> [[String]] {
        let result = try ProcessRunner().runChecked(executable: tools.mysql,
                                                    arguments: clientArguments + ["--batch", "--skip-column-names", "--execute", sql],
                                                    timeout: timeout)
        return MySQLBatchOutput.rows(result.standardOutput)
    }

    /// Exports `database` to `file`. Tables the server cannot read are left
    /// out and returned as warnings instead of stopping the export.
    public func dump(_ database: String, to file: URL, progress: @escaping (Int64) -> Void = { _ in },
                     isCancelled: () -> Bool = { false }) throws -> [String] {
        let arguments = clientArguments + [
            "--force", "--single-transaction", "--routines", "--triggers", "--events", "--hex-blob",
            "--skip-dump-date", "--max-allowed-packet=1G", database
        ]
        let result = try StreamingCommand.run(executable: tools.mysqldump, arguments: arguments, outputFile: file,
            poll: { progress(FileSize.of(file)) },
            isCancelled: isCancelled)
        let warnings = result.standardError.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.lowercased().contains("using a password on the command line") && !$0.contains("Deprecated program name") }
        guard result.exitCode == 0 || (result.exitCode == 2 && fileHasContent(file)) else {
            throw MariaDBReaderError.dumpFailed(database, warnings.suffix(5).joined(separator: "\n"))
        }
        return warnings
    }

    private func fileHasContent(_ file: URL) -> Bool { FileSize.of(file) > 0 }

    /// The end of the server's log, for error messages.
    public func logTail(lines: Int = 25) -> String {
        let text = [logFile, URL(fileURLWithPath: logFile.path + ".out")]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}

/// Counts that show a database arrived whole.
public struct DatabaseSnapshot: Codable, Hashable, Sendable {
    /// Rows per base table.
    public var tables: [String: Int64]
    public var views: Int
    public var routines: Int
    public var triggers: Int
    public var events: Int
    public var bytes: Int64
    public var characterSet: String?
    public var collation: String?
    /// Tables the server could not read, with its error.
    public var unreadable: [String: String]

    public init(tables: [String: Int64] = [:], views: Int = 0, routines: Int = 0, triggers: Int = 0, events: Int = 0,
                bytes: Int64 = 0, characterSet: String? = nil, collation: String? = nil, unreadable: [String: String] = [:]) {
        self.tables = tables
        self.views = views
        self.routines = routines
        self.triggers = triggers
        self.events = events
        self.bytes = bytes
        self.characterSet = characterSet
        self.collation = collation
        self.unreadable = unreadable
    }

    public var rows: Int64 { tables.values.reduce(0, +) }

    /// What differs in `imported` from this snapshot, one line each.
    public func differences(from imported: DatabaseSnapshot) -> [String] {
        var result: [String] = []
        for (table, rows) in tables.sorted(by: { $0.key < $1.key }) {
            guard let arrived = imported.tables[table] else { result.append("Table \(table) is missing"); continue }
            if arrived != rows { result.append("Table \(table) has \(arrived) of \(rows) rows") }
        }
        if imported.views < views { result.append("\(views - imported.views) of \(views) views are missing") }
        if imported.routines < routines { result.append("\(routines - imported.routines) of \(routines) procedures and functions are missing") }
        if imported.triggers < triggers { result.append("\(triggers - imported.triggers) of \(triggers) triggers are missing") }
        if imported.events < events { result.append("\(events - imported.events) of \(events) events are missing") }
        return result
    }
}

public enum DatabaseInspector {
    /// Counts tables, rows, views, routines, triggers and events of
    /// `database` through `run`, which executes SQL and returns rows.
    /// `mariaDBSource` counts routines and events in mysql.proc and
    /// mysql.event, which MariaDB fills even while information_schema can't
    /// show them (grant tables skipped, or system tables from an older
    /// version).
    public static func snapshot(of database: String, mariaDBSource: Bool = false, run: (String) throws -> [[String]]) throws -> DatabaseSnapshot {
        let name = SQLText.literal(database)
        var snapshot = DatabaseSnapshot()
        let schema = try run("SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = \(name)")
        snapshot.characterSet = schema.first?.first
        snapshot.collation = schema.first.flatMap { $0.count > 1 ? $0[1] : nil }
        let tables = try run("SELECT TABLE_NAME, TABLE_TYPE, IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0) FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(name)")
        var baseTables: [String] = []
        for row in tables where row.count >= 3 {
            if row[1] == "VIEW" { snapshot.views += 1 } else if row[1] != "SEQUENCE" { baseTables.append(row[0]) }
            snapshot.bytes += Int64(row[2]) ?? 0
        }
        func count(_ sql: String) -> Int { (try? run(sql))?.first?.first.flatMap { Int($0) } ?? 0 }
        snapshot.routines = count(mariaDBSource ? "SELECT COUNT(*) FROM mysql.proc WHERE db = \(name) AND type IN ('FUNCTION', 'PROCEDURE')"
                                                : "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(name)")
        snapshot.triggers = count("SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(name)")
        snapshot.events = count(mariaDBSource ? "SELECT COUNT(*) FROM mysql.event WHERE db = \(name)"
                                              : "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(name)")

        // Exact row counts, forty tables a query; a table the server cannot
        // read is counted on its own so the others still count.
        let qualified = { (table: String) in "\(SQLText.identifier(database)).\(SQLText.identifier(table))" }
        for start in stride(from: 0, to: baseTables.count, by: 40) {
            let group = Array(baseTables[start..<min(start + 40, baseTables.count)])
            let sql = group.map { "SELECT \(SQLText.literal($0)), COUNT(*) FROM \(qualified($0))" }.joined(separator: " UNION ALL ")
            if let rows = try? run(sql) {
                for row in rows where row.count == 2 { snapshot.tables[row[0]] = Int64(row[1]) ?? 0 }
            } else {
                for table in group {
                    do {
                        let rows = try run("SELECT COUNT(*) FROM \(qualified(table))")
                        snapshot.tables[table] = Int64(rows.first?.first ?? "0") ?? 0
                    } catch {
                        snapshot.unreadable[table] = Self.serverMessage(error)
                    }
                }
            }
        }
        return snapshot
    }

    /// The server's own words from a failed client run.
    public static func serverMessage(_ error: Error) -> String {
        if case CommandExecutionError.nonZeroExit(_, let result) = error {
            let line = result.standardError.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") } ?? Substring(result.standardError)
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return error.localizedDescription
    }
}

/// An account of the other app's server that projects may sign in with.
public struct MariaDBAccount: Hashable, Sendable {
    public var user: String
    public var host: String
    /// "" for no password, "*…" for a mysql_native_password hash, nil when
    /// the password cannot be carried over (another sign-in plugin).
    public var passwordHash: String?
    /// Privileges on every database; ["ALL PRIVILEGES"] for all of them.
    public var globalPrivileges: [String]
    /// Privileges per database.
    public var databasePrivileges: [String: [String]]

    public init(user: String, host: String, passwordHash: String?, globalPrivileges: [String] = [], databasePrivileges: [String: [String]] = [:]) {
        self.user = user
        self.host = host
        self.passwordHash = passwordHash
        self.globalPrivileges = globalPrivileges
        self.databasePrivileges = databasePrivileges
    }

    public var title: String { "\(user)@\(host)" }
    public var needsNativePassword: Bool { passwordHash.map { !$0.isEmpty } ?? false }
}

public enum MariaDBAccounts {
    static let privilegeColumns: [(column: String, privilege: String)] = [
        ("Select_priv", "SELECT"), ("Insert_priv", "INSERT"), ("Update_priv", "UPDATE"), ("Delete_priv", "DELETE"),
        ("Create_priv", "CREATE"), ("Drop_priv", "DROP"), ("References_priv", "REFERENCES"), ("Index_priv", "INDEX"),
        ("Alter_priv", "ALTER"), ("Create_tmp_table_priv", "CREATE TEMPORARY TABLES"), ("Lock_tables_priv", "LOCK TABLES"),
        ("Create_view_priv", "CREATE VIEW"), ("Show_view_priv", "SHOW VIEW"), ("Create_routine_priv", "CREATE ROUTINE"),
        ("Alter_routine_priv", "ALTER ROUTINE"), ("Execute_priv", "EXECUTE"), ("Event_priv", "EVENT"), ("Trigger_priv", "TRIGGER")
    ]

    /// Accounts that belong to the server, XAMPP or phpMyAdmin rather than to
    /// projects.
    public static func isSystemAccount(_ user: String) -> Bool {
        user.isEmpty || user == "root" || user == "pma" || user == "PUBLIC" || user == "mariadb.sys" || user.hasPrefix("mysql.")
    }

    /// Whether root signs in with a password on the other server.
    public static func rootHasPassword(run: (String) throws -> [[String]]) -> Bool? {
        guard let rows = try? run("SELECT IFNULL(plugin, ''), IFNULL(authentication_string, ''), IFNULL(Password, '') FROM mysql.user WHERE User = 'root' AND Host = 'localhost'"),
              let row = rows.first, row.count == 3 else { return nil }
        return !(row[1].isEmpty && row[2].isEmpty) || !["", "mysql_native_password"].contains(row[0])
    }

    public static func read(run: (String) throws -> [[String]]) throws -> [MariaDBAccount] {
        let columns = privilegeColumns.map(\.column).joined(separator: ", ")
        var accounts: [MariaDBAccount] = []
        for row in try run("SELECT User, Host, IFNULL(plugin, ''), IFNULL(authentication_string, ''), IFNULL(Password, ''), IFNULL(is_role, 'N'), \(columns) FROM mysql.user") where row.count == 6 + privilegeColumns.count {
            guard !isSystemAccount(row[0]), row[5] != "Y" else { continue }
            let hash: String?
            switch row[2] {
            case "", "mysql_native_password": hash = row[3].isEmpty ? row[4] : row[3]
            default: hash = nil
            }
            let granted = zip(privilegeColumns, row[6...]).filter { $0.1 == "Y" }.map(\.0.privilege)
            accounts.append(MariaDBAccount(user: row[0], host: row[1], passwordHash: hash,
                                           globalPrivileges: granted.count == privilegeColumns.count ? ["ALL PRIVILEGES"] : granted))
        }
        for row in try run("SELECT User, Host, Db, \(columns) FROM mysql.db") where row.count == 3 + privilegeColumns.count {
            guard let index = accounts.firstIndex(where: { $0.user == row[0] && $0.host == row[1] }) else { continue }
            // mysql.db escapes _ and % in exact names; a pattern grants many.
            let database = row[2].replacingOccurrences(of: "\\_", with: "_").replacingOccurrences(of: "\\%", with: "%")
            let granted = zip(privilegeColumns, row[3...]).filter { $0.1 == "Y" }.map(\.0.privilege)
            accounts[index].databasePrivileges[database] = granted.count == privilegeColumns.count ? ["ALL PRIVILEGES"] : granted
        }
        return accounts.filter { !$0.globalPrivileges.isEmpty || !$0.databasePrivileges.isEmpty }
    }

    /// Statements that recreate `account` on MySQL with its privileges on
    /// the imported databases (`renamed` maps old names to new ones).
    public static func statements(for account: MariaDBAccount, renamed: [String: String]) -> [String] {
        guard let hash = account.passwordHash else { return [] }
        let who = "\(SQLText.literal(account.user))@\(SQLText.literal(account.host))"
        var statements = [hash.isEmpty
            ? "CREATE USER IF NOT EXISTS \(who) IDENTIFIED BY ''"
            : "CREATE USER IF NOT EXISTS \(who) IDENTIFIED WITH mysql_native_password AS \(SQLText.literal(hash))"]
        if !account.globalPrivileges.isEmpty {
            statements.append("GRANT \(account.globalPrivileges.joined(separator: ", ")) ON *.* TO \(who)")
        }
        for (database, privileges) in account.databasePrivileges.sorted(by: { $0.key < $1.key }) where !privileges.isEmpty {
            guard let target = renamed[database] else { continue }
            statements.append("GRANT \(privileges.joined(separator: ", ")) ON \(SQLText.identifier(target)).* TO \(who)")
        }
        return statements
    }
}

public enum Rosetta {
    /// Whether this Mac runs Intel programs: Rosetta is installed, or the
    /// Mac is an Intel one.
    public static var isAvailable: Bool {
        guard MachO.currentArchitecture == "arm64" else { return true }
        let result = try? ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/arch"), arguments: ["-x86_64", "/usr/bin/true"], timeout: 20)
        return result?.exitCode == 0
    }

    /// The command that installs Rosetta, run as an administrator. It accepts
    /// Apple's license for Rosetta, which the wizard says before running it.
    public static let installCommand = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
}

public enum XAMPPProcesses {
    /// The servers running from `installation`, as "Apache (PID 12)".
    public static func running(_ installation: XAMPPInstallation) -> [String] {
        let root = installation.root.resolvingSymlinksInPath().path + "/"
        var result: [String] = []
        for (name, title) in [("httpd", "Apache"), ("mysqld", "MariaDB"), ("mariadbd", "MariaDB"), ("proftpd", "ProFTPD")] {
            guard let output = try? ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-x", name], timeout: 5) else { continue }
            for pid in output.standardOutput.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }) {
                guard let path = HelperProcesses.executablePath(of: pid), URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root) else { continue }
                result.append("\(title) (PID \(pid))")
            }
        }
        return result
    }
}

public enum MariaDBVersion {
    /// "10.1" from "10.1.8-MariaDB".
    public static func majorMinor(_ version: String) -> String? {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-").first?.split(separator: ".") ?? []
        return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : nil
    }
}

public enum FileSize {
    /// The current size of a file being written. A URL's resource values
    /// are cached after the first read, so they would keep the old size.
    public static func of(_ file: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
