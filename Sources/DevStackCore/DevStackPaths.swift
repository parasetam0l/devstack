import Foundation
import CryptoKit
import Darwin

public struct DevStackPaths: Sendable {
    public let applicationSupport: URL
    public let logs: URL
    public let builtInRuntimes: URL

    public init(
        applicationSupport: URL? = nil,
        logs: URL? = nil,
        builtInRuntimes: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let supportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logsBase = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Logs")
        self.applicationSupport = applicationSupport ?? supportBase.appendingPathComponent("DevStack", isDirectory: true)
        self.logs = logs ?? logsBase.appendingPathComponent("DevStack", isDirectory: true)
        self.builtInRuntimes = builtInRuntimes ?? Bundle.main.resourceURL?.appendingPathComponent("Runtimes", isDirectory: true) ?? URL(fileURLWithPath: "/Applications/DevStack.app/Contents/Resources/Runtimes")
    }

    public var configurationFile: URL { applicationSupport.appendingPathComponent("configuration.json") }
    public var generated: URL { applicationSupport.appendingPathComponent("Generated", isDirectory: true) }
    public var generatedApache: URL { generated.appendingPathComponent("Apache", isDirectory: true) }
    public var generatedNginx: URL { generated.appendingPathComponent("Nginx", isDirectory: true) }
    public var generatedPHP: URL { generated.appendingPathComponent("PHP", isDirectory: true) }
    public var phpMyAdmin: URL { applicationSupport.appendingPathComponent("phpMyAdmin", isDirectory: true) }
    public var importedRuntimes: URL { applicationSupport.appendingPathComponent("Runtimes", isDirectory: true) }
    public var databases: URL { applicationSupport.appendingPathComponent("Databases", isDirectory: true) }
    public var mysql57Data: URL { databases.appendingPathComponent("mysql-5.7", isDirectory: true) }
    public var mysql84Data: URL { databases.appendingPathComponent("mysql-8.4", isDirectory: true) }
    public var sockets: URL {
        let digest = SHA256.hash(data: Data(applicationSupport.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp/devstack-\(getuid())-\(digest)", isDirectory: true)
    }
    public var certificates: URL { applicationSupport.appendingPathComponent("Certificates", isDirectory: true) }
    public var mailpit: URL { applicationSupport.appendingPathComponent("Mailpit", isDirectory: true) }
    public var mailpitDatabase: URL { mailpit.appendingPathComponent("mailpit.db") }
    public var backups: URL { applicationSupport.appendingPathComponent("Backups", isDirectory: true) }

    public func phpSocket(runtimeID: String, siteID: UUID) -> URL {
        sockets.appendingPathComponent("\(runtimeID.replacingOccurrences(of: "php-", with: "p").replacingOccurrences(of: ".", with: ""))-\(siteID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()).sock")
    }

    public func certificate(for hostname: String) -> URL {
        certificates.appendingPathComponent("sites/\(hostname).pem")
    }

    public func privateKey(for hostname: String) -> URL {
        certificates.appendingPathComponent("sites/\(hostname)-key.pem")
    }

    public func createRequiredDirectories(fileManager: FileManager = .default) throws {
        let directories = [
            applicationSupport, logs, generated, generatedApache, generatedPHP, generatedNginx,
            generatedPHP.appendingPathComponent("conf.d", isDirectory: true),
            importedRuntimes, databases, sockets, certificates, phpMyAdmin,
            phpMyAdmin.appendingPathComponent("tmp", isDirectory: true),
            certificates.appendingPathComponent("sites", isDirectory: true), mailpit, backups
        ]
        var socketInfo = stat()
        if lstat(sockets.path, &socketInfo) == 0 {
            guard socketInfo.st_uid == getuid(), socketInfo.st_mode & S_IFMT == S_IFDIR else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "DevStack's socket directory has unexpected ownership or is a symlink."])
            }
        } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard lstat(sockets.path, &socketInfo) == 0, socketInfo.st_uid == getuid(), socketInfo.st_mode & S_IFMT == S_IFDIR,
              chmod(sockets.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
}
