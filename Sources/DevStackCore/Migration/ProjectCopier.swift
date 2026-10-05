import Darwin
import Foundation

public struct FileCopyProgress: Hashable, Sendable {
    public var files: Int
    public var totalFiles: Int
    public var bytes: Int64
    public var totalBytes: Int64
    /// The file being copied, relative to the project.
    public var current: String

    public init(files: Int = 0, totalFiles: Int = 0, bytes: Int64 = 0, totalBytes: Int64 = 0, current: String = "") {
        self.files = files
        self.totalFiles = totalFiles
        self.bytes = bytes
        self.totalBytes = totalBytes
        self.current = current
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : (totalFiles > 0 ? min(1, Double(files) / Double(totalFiles)) : 0)
    }
}

/// A file that could not be copied, usually for lack of permission.
public struct FileCopyFailure: Hashable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Copies project folders. Files are cloned where the volume allows, so a
/// copy from /Applications to the home folder takes no extra space; the
/// source is only read.
public enum ProjectCopier {
    /// Copies `source` to `destination`, which must not exist yet, through a
    /// hidden staging folder beside it, so an interrupted copy never looks
    /// finished. Files that cannot be read are skipped and returned.
    public static func copyFolder(
        _ source: URL, to destination: URL, totals: (files: Int, bytes: Int64),
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (FileCopyProgress) -> Void,
        fileManager: FileManager = .default
    ) throws -> [FileCopyFailure] {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".devstack-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: staging) } }

        var state = FileCopyProgress(totalFiles: totals.files, totalBytes: totals.bytes)
        var failures: [FileCopyFailure] = []
        let base = source.resolvingSymlinksInPath().standardizedFileURL
        var lastReport = Date.distantPast
        guard let enumerator = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [],
                                                      errorHandler: { url, error in
                                                          failures.append(FileCopyFailure(path: url.path, reason: error.localizedDescription))
                                                          return true
                                                      }) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: source.path])
        }
        for case let url as URL in enumerator {
            if isCancelled() { throw CancellationError() }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = staging.appendingPathComponent(relative)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            do {
                if values?.isSymbolicLink == true {
                    let link = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                    try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                    state.files += 1
                } else if values?.isDirectory == true {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try copyFile(url, to: target)
                    state.files += 1
                    state.bytes += Int64(values?.fileSize ?? 0)
                }
            } catch {
                failures.append(FileCopyFailure(path: url.path, reason: error.localizedDescription))
            }
            if Date().timeIntervalSince(lastReport) > 0.1 {
                state.current = relative
                progress(state)
                lastReport = Date()
            }
        }
        if isCancelled() { throw CancellationError() }
        guard rename(staging.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        finished = true
        state.current = ""
        progress(state)
        return failures
    }

    /// Copies files from `source` into `destination`, keeping files already
    /// there unless they are DevStack's placeholder page. Returns the names
    /// left out because they exist.
    public static func copyFiles(_ names: [String], from source: URL, into destination: URL, fileManager: FileManager = .default) throws -> (kept: [String], failures: [FileCopyFailure]) {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var kept: [String] = []
        var failures: [FileCopyFailure] = []
        for name in names {
            let target = destination.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                guard DefaultSiteContent.isPlaceholder(at: target) else { kept.append(name); continue }
                try? fileManager.removeItem(at: target)
            }
            do { try copyFile(source.appendingPathComponent(name), to: target) }
            catch { failures.append(FileCopyFailure(path: source.appendingPathComponent(name).path, reason: error.localizedDescription)) }
        }
        return (kept, failures)
    }

    /// Clones the file when the volume supports it, else copies its data,
    /// mode and dates. The copy belongs to the current user.
    static func copyFile(_ source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_CLONE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            let code = errno
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: source.path])
        }
    }
}
