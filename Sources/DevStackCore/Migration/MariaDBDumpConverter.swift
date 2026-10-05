import Foundation

/// What converting a MariaDB export for MySQL changed or left out.
public struct DumpConversionReport: Hashable, Sendable {
    /// Kinds of changes, one sentence each.
    public var notes: Set<String> = []
    /// Statements left out, with the reason.
    public var skipped: [String] = []

    public init() {}
}

/// Rewrites a MariaDB export so MySQL accepts it. Only table definitions,
/// routine headers and session settings change; row data passes through
/// byte for byte.
public enum MariaDBDumpConverter {
    public struct State: Sendable {
        var inCreateTable = false
        var skippingStatement = false
        /// Inside an INSERT whose rows continue on the following lines.
        var inInsert = false
        /// Positions of generated columns per table: MariaDB exports their
        /// values, MySQL refuses them.
        var generatedColumns: [String: Set<Int>] = [:]
        var columnIndex = 0
        var insertTable = ""
        var table = ""
        public var report = DumpConversionReport()
        public init() {}
    }

    public static func convert(
        _ source: URL, to destination: URL, target: DatabaseEngine, renamed: (from: String, to: String)? = nil,
        progress: (Int64) -> Void = { _ in }, isCancelled: () -> Bool = { false }
    ) throws -> DumpConversionReport {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var state = State()
        var pending = Data()
        var buffer = Data()
        var consumed: Int64 = 0
        func flush(force: Bool) throws {
            if force || buffer.count > 4 << 20 {
                try output.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        func emit(_ line: Data) throws {
            if let converted = convert(lineData: line, state: &state, target: target, renamed: renamed) {
                buffer.append(converted)
                buffer.append(0x0A)
            }
            try flush(force: false)
        }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                try emit(pending[start..<newline])
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])
            consumed += Int64(chunk.count)
            progress(consumed)
        }
        if !pending.isEmpty { try emit(pending) }
        try flush(force: true)
        return state.report
    }

    private static let passthroughPrefixes = ["INSERT INTO ", "REPLACE INTO "].map { Data($0.utf8) }

    /// The table of `INSERT INTO `name` VALUES`.
    static func insertTableName(_ line: Data) -> String? {
        guard let open = line.firstIndex(of: 0x60) else { return nil }
        var index = line.index(after: open)
        var name = Data()
        while index < line.endIndex {
            if line[index] == 0x60 {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == 0x60 { name.append(0x60); index = line.index(after: next); continue }
                return String(data: name, encoding: .utf8)
            }
            name.append(line[index])
            index = line.index(after: index)
        }
        return nil
    }

    /// The line with the values at `positions` replaced by DEFAULT in every
    /// row, which MySQL computes for generated columns. Rows never span
    /// lines: the export escapes newlines inside values.
    static func defaultValues(at positions: Set<Int>, in line: Data, isHeader: Bool) -> Data {
        let bytes = [UInt8](line)
        var index = 0
        if isHeader {
            // Rows start after VALUES.
            guard let range = line.range(of: Data(" VALUES".utf8)) else { return line }
            index = range.upperBound - line.startIndex
        }
        var output = [UInt8](bytes[0..<index])
        output.reserveCapacity(bytes.count)
        var depth = 0
        var value = 0
        var valueStart = 0
        var kept: [[UInt8]] = []
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if let open = quote {
                if byte == 0x5C { index += 2; continue }
                if byte == open {
                    if index + 1 < bytes.count, bytes[index + 1] == open { index += 2; continue }
                    quote = nil
                }
                index += 1
                continue
            }
            switch byte {
            case 0x27, 0x22:
                quote = byte
            case 0x28:
                depth += 1
                if depth == 1 { value = 0; valueStart = index + 1; kept = [] }
            case 0x29:
                depth -= 1
                if depth == 0 {
                    kept.append(positions.contains(value) ? Array("DEFAULT".utf8) : Array(bytes[valueStart..<index]))
                    output.append(0x28)
                    for (offset, item) in kept.enumerated() {
                        if offset > 0 { output.append(0x2C) }
                        output.append(contentsOf: item)
                    }
                    output.append(0x29)
                    index += 1
                    continue
                }
            case 0x2C where depth == 1:
                kept.append(positions.contains(value) ? Array("DEFAULT".utf8) : Array(bytes[valueStart..<index]))
                value += 1
                valueStart = index + 1
            default:
                break
            }
            if depth == 0 { output.append(byte) }
            index += 1
        }
        return Data(output)
    }

    private static func endsStatement(_ line: Data) -> Bool {
        line.last { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D } == 0x3B
    }

    public static func convert(lineData: Data, state: inout State, target: DatabaseEngine, renamed: (from: String, to: String)?) -> Data? {
        // Row data passes untouched; newer exports put each row of an INSERT
        // on its own line, so the statement runs until a line ends in ";".
        let startsInsert = !state.inInsert && !state.skippingStatement && passthroughPrefixes.contains(where: { lineData.starts(with: $0) })
        if state.inInsert || startsInsert {
            if startsInsert { state.insertTable = insertTableName(lineData) ?? "" }
            state.inInsert = !endsStatement(lineData)
            guard let generated = state.generatedColumns[state.insertTable], !generated.isEmpty else { return lineData }
            state.report.notes.insert("Values of generated columns were left for MySQL to compute.")
            return defaultValues(at: generated, in: lineData, isHeader: startsInsert)
        }
        guard let line = String(data: lineData, encoding: .utf8) else { return state.skippingStatement ? nil : lineData }
        return convert(line: line, state: &state, target: target, renamed: renamed).map { Data($0.utf8) }
    }

    /// One line of the export, or nil to leave it out.
    public static func convert(line: String, state: inout State, target: DatabaseEngine, renamed: (from: String, to: String)? = nil) -> String? {
        if state.skippingStatement {
            if line.trimmingCharacters(in: .whitespaces).hasSuffix(";") { state.skippingStatement = false }
            return nil
        }
        // A client command of MariaDB's that MySQL's client rejects.
        if line.contains("enable the sandbox mode") { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("CREATE SEQUENCE") || upper.hasPrefix("/*!50001 CREATE SEQUENCE") || upper.contains("ENGINE=SEQUENCE") {
            let name = trimmed.firstMatch(of: /`((?:[^`]|``)+)`/).map { String($0.1) } ?? "a sequence"
            state.report.skipped.append("Sequence \(name): MySQL has no sequences.")
            if !trimmed.hasSuffix(";") { state.skippingStatement = true }
            return nil
        }
        if upper.hasPrefix("SELECT SETVAL(") || upper.hasPrefix("DO SETVAL(") || upper.hasPrefix("DROP SEQUENCE") { return nil }

        var result = line
        if upper.hasPrefix("CREATE TABLE") || upper.hasPrefix("/*!50001 CREATE TABLE") {
            state.inCreateTable = true
            state.table = trimmed.firstMatch(of: /`((?:[^`]|``)+)`/).map { String($0.1).replacingOccurrences(of: "``", with: "`") } ?? ""
            state.columnIndex = 0
            state.generatedColumns[state.table] = nil
        } else if state.inCreateTable {
            if trimmed.hasPrefix(")") {
                result = convertTableOptions(result, state: &state)
                state.inCreateTable = false
            } else {
                if trimmed.hasPrefix("`") {
                    if trimmed.contains(" GENERATED ALWAYS AS ") { state.generatedColumns[state.table, default: []].insert(state.columnIndex) }
                    state.columnIndex += 1
                }
                result = convertColumn(result, state: &state, target: target)
            }
        }

        // Views, routines, triggers and events run as the account that
        // imports them; the other server's accounts may not exist here.
        if result.contains("DEFINER=") {
            let rewritten = result.replacing(/DEFINER=`(?:[^`]|``)*`@`(?:[^`]|``)*`/, with: "DEFINER=CURRENT_USER")
            if rewritten != result { state.report.notes.insert("Views, routines and triggers now run as the account that imported them.") }
            result = rewritten
        }
        // Routines carry the SQL mode they were created with; MySQL rejects
        // modes it lacks, such as NO_AUTO_CREATE_USER on 8.4.
        if upper.contains("SET SQL_MODE") {
            result = result.replacing(/(?i)(SET\s+sql_mode\s*=\s*)'([^']*)'/) { "\($0.1)'\(MySQLSettings.sqlMode(String($0.2), for: target))'" }
        }
        // MariaDB marks its own syntax with six-digit version comments, which
        // MySQL would read as five-digit ones and run.
        result = result.replacing(/\/\*!(1\d{5})/) { "/*M!\($0.1)" }
        result = mapCharacterSets(result, target: target, state: &state)
        if let renamed, upper.hasPrefix("ALTER DATABASE") {
            result = result.replacingOccurrences(of: "ALTER DATABASE \(SQLText.identifier(renamed.from))", with: "ALTER DATABASE \(SQLText.identifier(renamed.to))")
        }
        return result
    }

    private static let textTypes: Set<String> = [
        "tinytext", "text", "mediumtext", "longtext", "tinyblob", "blob", "mediumblob", "longblob", "json",
        "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection"
    ]
    private static let timestampFunctions: Set<String> = ["current_timestamp", "now", "localtime", "localtimestamp"]

    static func convertColumn(_ line: String, state: inout State, target: DatabaseEngine) -> String {
        var result = line
        // Table-level CHECK constraints get per-table names such as
        // CONSTRAINT_1 in MariaDB; MySQL needs them unique per database.
        if result.contains("CHECK") {
            result = result.replacing(/CONSTRAINT `(?:[^`]|``)+` CHECK/, with: "CHECK")
        }
        // So do foreign keys created without a name: `1`, `2`, ...
        if result.contains("FOREIGN KEY") {
            result = result.replacing(/CONSTRAINT `\d+` FOREIGN KEY/, with: "FOREIGN KEY")
        }
        guard let column = result.firstMatch(of: /^(\s*`(?:[^`]|``)+`\s+)([A-Za-z0-9]+)/) else {
            // Index lines: MariaDB 10.6 can mark an index as ignored.
            return result.replacingOccurrences(of: " IGNORED", with: "")
        }
        let type = column.2.lowercased()
        switch type {
        case "uuid", "inet6", "inet4":
            let replacement = type == "uuid" ? "char(36)" : (type == "inet6" ? "varchar(45)" : "varchar(15)")
            result.replaceSubrange(column.2.startIndex..<column.2.endIndex, with: replacement)
            state.report.notes.insert("MariaDB's uuid and inet types became text columns.")
        default: break
        }
        if result.contains("PERSISTENT"), result.contains(" AS (") {
            result = result.replacing(/\bPERSISTENT\b/, with: "STORED")
        }
        if target == .mysql57, result.contains(" INVISIBLE") {
            result = result.replacingOccurrences(of: " INVISIBLE", with: "")
            state.report.notes.insert("Invisible columns became visible; MySQL 5.7 has none.")
        }
        guard let defaultRange = unquotedRange(of: " DEFAULT ", in: result) else { return result }
        let valueStart = defaultRange.upperBound
        guard let valueEnd = endOfValue(in: result, from: valueStart) else { return result }
        let value = String(result[valueStart..<valueEnd])
        if value.uppercased() == "NULL" { return result }

        let isTextType = textTypes.contains(type)
        let functionName = value.firstMatch(of: /^([a-z_]+)\(/).map { String($0.1).lowercased() }
        let needsExpression: Bool
        if isTextType {
            needsExpression = !value.hasPrefix("(")
        } else if let functionName {
            needsExpression = !timestampFunctions.contains(functionName)
        } else {
            needsExpression = false
        }
        guard needsExpression || (isTextType && target == .mysql57) else { return result }
        if target == .mysql57 {
            result.removeSubrange(defaultRange.lowerBound..<valueEnd)
            state.report.notes.insert("Column defaults MySQL 5.7 cannot hold (on TEXT and BLOB columns, or computed) were removed.")
        } else {
            result.replaceSubrange(valueStart..<valueEnd, with: "(\(value))")
            state.report.notes.insert("Column defaults on TEXT and BLOB columns, and computed ones, became MySQL expressions.")
        }
        return result
    }

    static func convertTableOptions(_ line: String, state: inout State) -> String {
        var result = line
        if result.contains("ENGINE=Aria") {
            result = result.replacingOccurrences(of: "ENGINE=Aria", with: "ENGINE=InnoDB")
            result = result.replacing(/\ ROW_FORMAT=(PAGE|FIXED)/, with: "")
            state.report.notes.insert("Aria tables became InnoDB tables.")
        }
        result = result.replacing(/\ ROW_FORMAT=PAGE/, with: "")
        result = result.replacing(/\ `?(PAGE_CHECKSUM|TRANSACTIONAL|PAGE_COMPRESSED|PAGE_COMPRESSION_LEVEL|ENCRYPTED|ENCRYPTION_KEY_ID|IETF_QUOTES|SEQUENCE)`?=('[^']*'|[^ *;]+)/, with: "")
        if result.contains("WITH SYSTEM VERSIONING") {
            result = result.replacingOccurrences(of: " WITH SYSTEM VERSIONING", with: "")
            state.report.notes.insert("System-versioned tables keep their current rows only.")
        }
        return result
    }

    /// Collations and character sets MySQL lacks, mapped to the closest it has.
    static func mapCharacterSets(_ line: String, target: DatabaseEngine, state: inout State) -> String {
        guard line.contains("nopad") || line.contains("uca1400") || (target == .mysql57 && line.contains("utf8mb3")) else { return line }
        var result = line.replacing(/\b([a-z0-9]+)_([a-z0-9_]*uca1400[a-z0-9_]*)\b/) { match -> String in
            let charset = String(match.1)
            let rest = String(match.2)
            let turkish = rest.contains("turkish")
            if charset == "utf8mb4" {
                if target == .mysql57 { return turkish ? "utf8mb4_turkish_ci" : "utf8mb4_unicode_520_ci" }
                if turkish { return "utf8mb4_tr_0900_ai_ci" }
                return rest.hasSuffix("as_cs") ? "utf8mb4_0900_as_cs" : (rest.hasSuffix("as_ci") ? "utf8mb4_0900_as_ci" : "utf8mb4_0900_ai_ci")
            }
            return "\(charset)_unicode_520_ci"
        }
        result = result.replacing(/\b([a-z0-9]+_[a-z0-9_]*)_nopad(_[a-z0-9]+)?\b/) { "\($0.1)\($0.2 ?? "")" }
        result = result.replacing(/\b([a-z0-9]+)_nopad_bin\b/) { "\($0.1)_bin" }
        if target == .mysql57 { result = result.replacing(/\butf8mb3/, with: "utf8") }
        if result != line { state.report.notes.insert("MariaDB-only collations were mapped to the closest MySQL ones.") }
        return result
    }

    /// The range of `needle` outside quoted strings and identifiers.
    static func unquotedRange(of needle: String, in line: String) -> Range<String.Index>? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == "\\", open == "'" { index = line.index(after: index); if index < line.endIndex { index = line.index(after: index) }; continue }
                if character == open { quote = nil }
            } else if character == "'" || character == "`" || character == "\"" {
                quote = character
            } else if line[index...].hasPrefix(needle) {
                return index..<line.index(index, offsetBy: needle.count)
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Where a DEFAULT value ends: after a quoted string, a balanced
    /// parenthesis group or function call, or a bare word.
    static func endOfValue(in line: String, from start: String.Index) -> String.Index? {
        guard start < line.endIndex else { return nil }
        var index = start
        if line[index] == "'" {
            index = line.index(after: index)
            while index < line.endIndex {
                if line[index] == "\\" { index = line.index(after: index) }
                else if line[index] == "'" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "'" { index = next } else { return next }
                }
                if index < line.endIndex { index = line.index(after: index) }
            }
            return nil
        }
        // A word, then an optional parenthesised argument list.
        while index < line.endIndex, line[index].isLetter || line[index].isNumber || line[index] == "_" || line[index] == "." || line[index] == "-" {
            index = line.index(after: index)
        }
        if index < line.endIndex, line[index] == "(" {
            var depth = 0
            var quote: Character?
            while index < line.endIndex {
                let character = line[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "'" || character == "`" {
                    quote = character
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 { return line.index(after: index) }
                }
                index = line.index(after: index)
            }
            return nil
        }
        return index > start ? index : nil
    }
}
