import Foundation

public enum DatabaseImportError: LocalizedError, Sendable {
    case statementFailed(message: String, line: Int?, statement: String?)

    public var errorDescription: String? {
        switch self {
        case .statementFailed(let message, let line, let statement):
            var text = message
            if let line { text += " (line \(line))" }
            if let statement, !statement.isEmpty { text += "\n\(statement)" }
            return text
        }
    }
}

/// Loads converted exports into DevStack's MySQL and checks what arrived.
public struct DatabaseImporter: Sendable {
    public let manager: DatabaseManager
    public let engine: DatabaseEngine

    public init(manager: DatabaseManager, engine: DatabaseEngine) {
        self.manager = manager
        self.engine = engine
    }

    /// Databases that exist already, so imports never land on them unasked.
    public func existingDatabases() throws -> Set<String> {
        Set(try manager.query(engine, "SHOW DATABASES").compactMap(\.first))
    }

    /// Creates `database` (replacing it when asked) and runs `file` in it.
    public func importDump(_ file: URL, into database: String, characterSet: String?, collation: String?, replace: Bool,
                           progress: @escaping @Sendable (Int64) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        var create = "CREATE DATABASE \(SQLText.identifier(database))"
        if let characterSet, characterSet.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil {
            create += " CHARACTER SET \(characterSet == "utf8mb3" && engine == .mysql57 ? "utf8" : characterSet)"
            if let collation, collation.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil {
                var state = MariaDBDumpConverter.State()
                create += " COLLATE \(MariaDBDumpConverter.mapCharacterSets(collation, target: engine, state: &state))"
            }
        }
        let drop = replace ? "DROP DATABASE IF EXISTS \(SQLText.identifier(database)); " : ""
        _ = try manager.query(engine, drop + create)

        let client = manager.clientInvocation(engine)
        let arguments = client.arguments + [
            "--default-character-set=utf8mb4", "--max-allowed-packet=1G",
            "--init-command=SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO,NO_ENGINE_SUBSTITUTION'",
            database
        ]
        let result = try StreamingCommand.run(executable: client.executable, arguments: arguments, environment: client.environment,
                                              inputFile: file, inputProgress: progress, isCancelled: isCancelled)
        guard result.exitCode == 0 else { throw Self.failure(result.standardError, file: file) }
    }

    public func snapshot(_ database: String) throws -> DatabaseSnapshot {
        try DatabaseInspector.snapshot(of: database) { try manager.query(engine, $0) }
    }

    /// Creates the accounts with their privileges; returns a reason for each
    /// one that could not be created.
    public func createAccounts(_ accounts: [MariaDBAccount], renamed: [String: String]) -> [String: String] {
        var failures: [String: String] = [:]
        for account in accounts {
            let statements = MariaDBAccounts.statements(for: account, renamed: renamed)
            guard !statements.isEmpty else {
                failures[account.title] = "Its password uses a sign-in method MySQL lacks; set one with ALTER USER."
                continue
            }
            do { _ = try manager.query(engine, statements.joined(separator: "; ")) }
            catch { failures[account.title] = DatabaseInspector.serverMessage(error) }
        }
        return failures
    }

    /// Changes root's password, signing in with the current one.
    public func setRootPassword(_ password: String) throws {
        guard MySQLSettings.isUsablePassword(password) else { throw DatabaseManagerError.unusablePassword }
        let plugin = engine == .mysql84 ? " WITH caching_sha2_password" : ""
        _ = try manager.query(engine, "ALTER USER 'root'@'localhost' IDENTIFIED\(plugin) BY \(SQLText.literal(password)); FLUSH PRIVILEGES")
    }

    /// The client's error with the statement it stopped at.
    public static func failure(_ standardError: String, file: URL) -> DatabaseImportError {
        let message = standardError.split(whereSeparator: \.isNewline).first { $0.hasPrefix("ERROR") }.map(String.init)
            ?? standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = message.firstMatch(of: /at line (\d+)/).flatMap { Int($0.1) }
        var statement: String?
        if let line, let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            var current = 1
            var pending = Data()
            reading: while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                pending.append(chunk)
                var start = pending.startIndex
                while let newline = pending[start...].firstIndex(of: 0x0A) {
                    if current == line {
                        statement = String(decoding: pending[start..<newline].prefix(400), as: UTF8.self)
                        break reading
                    }
                    current += 1
                    start = pending.index(after: newline)
                }
                pending = Data(pending[start...])
            }
        }
        return .statementFailed(message: message.replacing(#/^ERROR \d+ \([0-9A-Z]+\)( at line \d+)?: /#, with: ""), line: line, statement: statement)
    }
}
