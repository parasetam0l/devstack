import Darwin
import Foundation

public enum AtomicFileWriter {
    public static func write(_ data: Data, to destination: URL, permissions: mode_t = 0o600, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            guard chmod(temporary.path, permissions) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public static func write(_ string: String, to destination: URL, permissions: mode_t = 0o600, fileManager: FileManager = .default) throws {
        try write(Data(string.utf8), to: destination, permissions: permissions, fileManager: fileManager)
    }
}

