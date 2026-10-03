import Darwin
import Foundation

/// Size limits, tail reading and naming for the files in DevStack's log
/// directory.
public enum LogFiles {
    public static let rotationThreshold: UInt64 = 10 * 1_024 * 1_024

    /// Copies every `*.log` larger than `threshold` to `*.log.1`, replacing the
    /// previous copy, and truncates the original in place.
    ///
    /// Truncating instead of renaming keeps running servers writing to the
    /// same file without a reopen signal. Apache, nginx, PHP-FPM and MySQL open
    /// their logs with O_APPEND, as does the supervisor for captured output,
    /// so writers continue at the new end. Lines written between the copy and
    /// the truncation are lost, which is acceptable for development logs.
    @discardableResult
    public static func rotateOversized(in directory: URL, threshold: UInt64 = rotationThreshold, fileManager: FileManager = .default) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var rotated: [URL] = []
        for name in names.sorted() where name.hasSuffix(".log") {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? UInt64, size > threshold else { continue }
            let archive = directory.appendingPathComponent(name + ".1")
            try? fileManager.removeItem(at: archive)
            guard (try? fileManager.copyItem(at: url, to: archive)) != nil,
                  truncate(url.path, 0) == 0 else { continue }
            rotated.append(url)
        }
        return rotated
    }

    /// The last `maximumBytes` of a log, starting at a line boundary, or nil
    /// when the file does not exist.
    public static func tail(of url: URL, maximumBytes: Int = 192 * 1_024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maximumBytes) ? end - UInt64(maximumBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.readToEnd() else { return nil }
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        // A writer without O_APPEND that outlived a truncation leaves a
        // zero-filled gap; skip it rather than render NUL characters.
        data.removeAll { $0 == 0 }
        return String(decoding: data, as: UTF8.self)
    }

    public enum Group: Int, Comparable, Sendable {
        case services, sites, other
        public static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Entry: Hashable, Identifiable, Sendable {
        public var id: String { fileName }
        public let fileName: String
        public let title: String
        public let group: Group
        /// The service whose state the log view shows next to this file.
        public let service: ServiceKind?
    }

    /// Readable titles for the log files present in the directory. Site logs
    /// are named after their site; logs of removed sites are listed as other.
    public static func entries(fileNames: [String], sites: [SiteDefinition]) -> [Entry] {
        var siteLogs: [String: (SiteDefinition, Bool)] = [:]
        for site in sites {
            siteLogs[URL(fileURLWithPath: site.logs.access).lastPathComponent] = (site, true)
            siteLogs[URL(fileURLWithPath: site.logs.error).lastPathComponent] = (site, false)
        }
        return fileNames.filter { $0.hasSuffix(".log") }.map { name in
            if let (site, access) = siteLogs[name] {
                return Entry(fileName: name, title: "\(site.hostname) — \(access ? "access" : "errors")", group: .sites, service: nil)
            }
            if let (title, service) = serviceLog(name) {
                return Entry(fileName: name, title: title, group: .services, service: service)
            }
            return Entry(fileName: name, title: name, group: .other, service: nil)
        }.sorted { ($0.group, $0.title) < ($1.group, $1.title) }
    }

    /// The most useful log to open for a service.
    public static func primaryLog(for service: ServiceKind) -> String {
        switch service {
        case .apache: "apache-error.log"
        case .php74, .php84, .php85: "\(service.rawValue)-fpm.log"
        default: "\(service.rawValue).log"
        }
    }

    private static func serviceLog(_ name: String) -> (String, ServiceKind)? {
        let base = String(name.dropLast(".log".count))
        switch base {
        case "apache": return ("Apache — output", .apache)
        case "apache-error": return ("Apache — errors", .apache)
        case "nginx": return ("Nginx — errors", .nginx)
        case "nginx-access": return ("Nginx — access", .nginx)
        case "mailpit": return ("Mailpit", .mailpit)
        default: break
        }
        for service in ServiceKind.allCases {
            guard base.hasPrefix(service.rawValue) else { continue }
            let label = service.displayName
            switch base.dropFirst(service.rawValue.count) {
            case "": return (service.phpRuntimeID == nil ? label : "\(label) — output", service)
            case "-fpm": return ("\(label) — FPM", service)
            case "-php": return ("\(label) — PHP errors", service)
            default: continue
            }
        }
        return nil
    }
}
