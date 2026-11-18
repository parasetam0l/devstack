import Foundation

public enum SQLDumpFileError: LocalizedError, Sendable, Equatable {
    case notSQL(String)
    case noDumpInArchive(String)
    case severalDumpsInArchive(String, [String])

    public var errorDescription: String? {
        switch self {
        case .notSQL(let name):
            "\(name) is not a SQL dump. Choose a .sql file, or a .zip or .gz archive that holds one."
        case .noDumpInArchive(let name):
            "\(name) holds no .sql file."
        case .severalDumpsInArchive(let name, let dumps):
            "\(name) holds several SQL files (\(dumps.joined(separator: ", "))). Unzip it and import them one at a time."
        }
    }
}

/// A SQL dump chosen for import: plain SQL, or a ZIP or gzip archive holding
/// one, told apart by content so a misnamed archive still imports.
public enum SQLDumpFile {
    public enum Format: Equatable, Sendable { case sql, zip, gzip, binary }

    public static func format(of file: URL) throws -> Format {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4_096) ?? Data()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) || head.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if head.starts(with: [0x1F, 0x8B]) { return .gzip }
        return head.contains(0) ? .binary : .sql
    }

    /// Runs `body` with a plain SQL file: `source` itself, or what its archive
    /// holds, unpacked into a private temporary file removed afterwards.
    public static func withPlainSQL<T>(_ source: URL, runner: ProcessRunner = ProcessRunner(), _ body: (URL) throws -> T) throws -> T {
        let name = source.lastPathComponent
        let format = try format(of: source)
        switch format {
        case .sql: return try body(source)
        case .binary: throw SQLDumpFileError.notSQL(name)
        case .zip, .gzip: break
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devstack-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let unpacked = directory.appendingPathComponent("dump.sql")
        if format == .zip {
            let entry = try dumpEntry(in: source, runner: runner)
            _ = try runner.runChecked(executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                                      arguments: ["-p", source.path, escapedPattern(entry)], standardOutputFile: unpacked, timeout: 3_600)
        } else {
            _ = try runner.runChecked(executable: URL(fileURLWithPath: "/usr/bin/gzip"),
                                      arguments: ["-dc", source.path], standardOutputFile: unpacked, timeout: 3_600)
        }
        guard try Self.format(of: unpacked) == .sql else { throw SQLDumpFileError.notSQL(name) }
        return try body(unpacked)
    }

    /// The one SQL file in a ZIP archive, skipping Finder's metadata.
    private static func dumpEntry(in archive: URL, runner: ProcessRunner) throws -> String {
        let listing = try runner.runChecked(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", archive.path])
        let files = listing.standardOutput.split(whereSeparator: \.isNewline).map(String.init).filter { entry in
            let base = (entry as NSString).lastPathComponent
            return !entry.hasSuffix("/") && !entry.hasPrefix("__MACOSX/") && !base.hasPrefix("._") && base != ".DS_Store"
        }
        let dumps = files.filter { $0.lowercased().hasSuffix(".sql") }
        if dumps.count > 1 { throw SQLDumpFileError.severalDumpsInArchive(archive.lastPathComponent, dumps.sorted()) }
        guard let entry = dumps.first ?? (files.count == 1 ? files[0] : nil) else {
            throw SQLDumpFileError.noDumpInArchive(archive.lastPathComponent)
        }
        return entry
    }

    /// unzip reads entry names as wildcards; this matches `entry` literally.
    private static func escapedPattern(_ entry: String) -> String {
        entry.reduce(into: "") { pattern, character in
            if "\\*?[]".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
    }
}
