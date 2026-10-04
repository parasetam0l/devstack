import CryptoKit
import Foundation

/// One runtime pack this app version installs, pinned exactly: where to
/// download it, its SHA-256 and size, and the packs it needs. Pins come from
/// the pack.json that devstack-runtimes publishes with every pack
/// (scripts/pin-runtime.sh).
public struct RuntimePackPin: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var version: String
    public var packRevision: Int
    public var name: String
    public var url: URL
    public var sha256: String
    public var size: Int64
    public var requires: [String]
    public var minimumMacOS: String
    /// Other runtimes carried inside this pack, such as PHP extensions.
    public var contents: [String]

    public init(id: String, version: String, packRevision: Int, name: String, url: URL, sha256: String, size: Int64,
                requires: [String] = [], minimumMacOS: String = "15.0", contents: [String] = []) {
        self.id = id
        self.version = version
        self.packRevision = packRevision
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.requires = requires
        self.minimumMacOS = minimumMacOS
        self.contents = contents
    }
}

public struct RuntimePackCatalog: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var packs: [RuntimePackPin]

    public init(schemaVersion: Int = currentSchemaVersion, packs: [RuntimePackPin] = []) {
        self.schemaVersion = schemaVersion
        self.packs = packs
    }

    public func pin(for id: String) -> RuntimePackPin? {
        packs.first { $0.id == id }
    }

    /// The requested packs and everything they require, each listed after the
    /// packs it needs.
    public func installationOrder(for ids: [String]) throws -> [RuntimePackPin] {
        var ordered: [RuntimePackPin] = []
        var visiting: Set<String> = []
        func visit(_ id: String) throws {
            guard !ordered.contains(where: { $0.id == id }) else { return }
            guard let pin = pin(for: id) else { throw RuntimePackInstallError.unknownPack(id) }
            guard visiting.insert(id).inserted else { throw RuntimePackInstallError.dependencyCycle(id) }
            for requirement in pin.requires.sorted() { try visit(requirement) }
            visiting.remove(id)
            ordered.append(pin)
        }
        for id in ids { try visit(id) }
        return ordered
    }
}

public enum RuntimePackInstallError: LocalizedError, Equatable, Sendable {
    case unknownPack(String)
    case dependencyCycle(String)
    case insecureURL(String)
    case sizeMismatch(String)
    case checksumMismatch(String)
    case unexpectedRuntime(String)

    public var errorDescription: String? {
        switch self {
        case .unknownPack(let id): "This version of DevStack has no runtime pack \(id)."
        case .dependencyCycle(let id): "The runtime packs require each other in a cycle at \(id)."
        case .insecureURL(let url): "Runtime packs download only over HTTPS: \(url)"
        case .sizeMismatch(let name): "The download of \(name) has the wrong size."
        case .checksumMismatch(let name): "The download of \(name) does not match its pinned SHA-256."
        case .unexpectedRuntime(let name): "\(name) contains a different runtime than the one pinned."
        }
    }
}

/// Downloads pinned packs and installs them through the verifying importer,
/// replacing an installed version only once the new one has passed every
/// check.
public struct RuntimePackInstaller: Sendable {
    /// Marker written next to an installed pack, naming the pin it came from.
    public static let markerName = ".devstack-pack.json"

    public let verifier: RuntimePackVerifier
    /// Application Support/DevStack/Runtimes.
    public let runtimes: URL
    /// file: URLs are accepted only for local testing.
    public let allowsFileURLs: Bool

    public init(verifier: RuntimePackVerifier, runtimes: URL, allowsFileURLs: Bool = false) {
        self.verifier = verifier
        self.runtimes = runtimes
        self.allowsFileURLs = allowsFileURLs
    }

    /// The pin an installed runtime came from, when it was installed from a pack.
    public func installedPin(_ id: String) -> RuntimePackPin? {
        let marker = runtimes.appendingPathComponent(id).appendingPathComponent(Self.markerName)
        return (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode(RuntimePackPin.self, from: $0) }
    }

    public func isInstalled(_ pin: RuntimePackPin) -> Bool {
        installedPin(pin.id) == pin
    }

    /// Downloads, checks and installs one pack. `progress` receives the bytes
    /// downloaded so far.
    public func install(_ pin: RuntimePackPin, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        guard pin.url.scheme == "https" || (allowsFileURLs && pin.url.isFileURL) else {
            throw RuntimePackInstallError.insecureURL(pin.url.absoluteString)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: runtimes, withIntermediateDirectories: true)
        let work = runtimes.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let archive = work.appendingPathComponent("\(pin.name).devstack-runtime")
        try await PackDownload.fetch(pin.url, to: archive, progress: progress)
        let attributes = try fileManager.attributesOfItem(atPath: archive.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == pin.size else { throw RuntimePackInstallError.sizeMismatch(pin.name) }
        guard try Self.sha256(archive) == pin.sha256.lowercased() else { throw RuntimePackInstallError.checksumMismatch(pin.name) }

        // Signature, inventory, hashes, links, code signatures and Team ID.
        let staged = work.appendingPathComponent("runtimes", isDirectory: true)
        let manifest = try RuntimePackImporter(verifier: verifier).importArchive(archive, into: staged)
        guard manifest.id == pin.id, manifest.version == pin.version else { throw RuntimePackInstallError.unexpectedRuntime(pin.name) }
        let installed = staged.appendingPathComponent(pin.id, isDirectory: true)
        try JSONEncoder().encode(pin).write(to: installed.appendingPathComponent(Self.markerName))

        // Swap only after everything passed; the previous version is removed last.
        let destination = runtimes.appendingPathComponent(pin.id, isDirectory: true)
        let previous = work.appendingPathComponent("previous", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: previous)
        }
        do {
            try fileManager.moveItem(at: installed, to: destination)
        } catch {
            if fileManager.fileExists(atPath: previous.path) { try? fileManager.moveItem(at: previous, to: destination) }
            throw error
        }
    }

    public func remove(_ id: String) throws {
        let directory = runtimes.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A single download with progress, written straight to `destination`.
private final class PackDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: (@Sendable (Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    private init(destination: URL, progress: (@Sendable (Int64) -> Void)?) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: (@Sendable (Int64) -> Void)?) async throws {
        let download = PackDownload(destination: destination, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.lock()
                download.continuation = continuation
                download.lock.unlock()
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        // The temporary file disappears when this method returns.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
