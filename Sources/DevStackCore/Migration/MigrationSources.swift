import Foundation

/// Another local development app DevStack imports projects and databases
/// from. XAMPP is the first; the others are listed so the wizard shows where
/// imports are headed.
public enum MigrationSourceKind: String, CaseIterable, Identifiable, Sendable {
    case xampp, mamp, mampPro, herd, valet, local

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xampp: "XAMPP"
        case .mamp: "MAMP"
        case .mampPro: "MAMP PRO"
        case .herd: "Laravel Herd"
        case .valet: "Laravel Valet"
        case .local: "Local"
        }
    }

    public var detail: String {
        switch self {
        case .xampp: "Projects in htdocs and its virtual hosts, MariaDB databases and PHP settings."
        case .mamp: "Projects in htdocs and MySQL databases."
        case .mampPro: "Hosts, MySQL databases and PHP versions."
        case .herd: "Parked and linked sites."
        case .valet: "Parked and linked sites."
        case .local: "WordPress sites and their databases."
        }
    }

    /// Whether DevStack can import from it yet.
    public var isSupported: Bool { self == .xampp }

    /// Where the app lives when it is installed, for its icon and the
    /// "found" label.
    public func installedLocation(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  fileManager: FileManager = .default) -> URL? {
        let candidates: [URL]
        switch self {
        case .xampp: candidates = XAMPPInstallation.find(fileManager: fileManager).map(\.managerApplication)
        case .mamp: candidates = [URL(fileURLWithPath: "/Applications/MAMP/MAMP.app")]
        case .mampPro: candidates = [URL(fileURLWithPath: "/Applications/MAMP PRO.app"), URL(fileURLWithPath: "/Applications/MAMP PRO/MAMP PRO.app")]
        case .herd: candidates = [URL(fileURLWithPath: "/Applications/Herd.app")]
        case .valet: candidates = [home.appendingPathComponent(".config/valet")]
        case .local: candidates = [URL(fileURLWithPath: "/Applications/Local.app")]
        }
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}

/// One XAMPP installation: the folder holding `xamppfiles`, as the
/// installer leaves it in /Applications. Nothing here is ever changed.
public struct XAMPPInstallation: Identifiable, Hashable, Sendable {
    /// The `xamppfiles` folder.
    public let root: URL
    /// "8.2.4"; XAMPP's version follows its PHP version.
    public let version: String?
    public let htdocs: URL
    public let dataDirectory: URL

    public var id: String { root.path }
    /// The folder in Applications, such as /Applications/XAMPP.
    public var location: URL { root.deletingLastPathComponent() }
    public var title: String { version.map { "XAMPP \($0)" } ?? "XAMPP" }
    public var managerApplication: URL { root.appendingPathComponent("manager-osx.app") }

    public var mysqld: URL { root.appendingPathComponent("sbin/mysqld") }
    public var mysqlClient: URL { root.appendingPathComponent("bin/mysql") }
    public var mysqldump: URL { root.appendingPathComponent("bin/mysqldump") }
    public var php: URL { root.appendingPathComponent("bin/php") }
    public var phpINI: URL { root.appendingPathComponent("etc/php.ini") }
    public var httpdConfiguration: URL { root.appendingPathComponent("etc/httpd.conf") }
    public var virtualHostsConfiguration: URL { root.appendingPathComponent("etc/extra/httpd-vhosts.conf") }
    public var mysqlConfiguration: URL { root.appendingPathComponent("etc/my.cnf") }

    /// The PHP version, "8.2" from "8.2.4".
    public var phpVersion: String? {
        guard let version else { return nil }
        let parts = version.split(separator: ".")
        return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : nil
    }

    public init(root: URL, version: String?, htdocs: URL, dataDirectory: URL) {
        self.root = root
        self.version = version
        self.htdocs = htdocs
        self.dataDirectory = dataDirectory
    }

    public init?(root: URL, fileManager: FileManager = .default) {
        let properties = (try? String(contentsOf: root.appendingPathComponent("properties.ini"), encoding: .utf8))
            .map { INIFile.settings($0).reduce(into: [String: String]()) { $0[$1.key] = $1.value } } ?? [:]
        let htdocs = properties["apache_htdocs_directory"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root.appendingPathComponent("htdocs", isDirectory: true)
        guard fileManager.fileExists(atPath: root.appendingPathComponent("xampp").path) || !properties.isEmpty,
              fileManager.fileExists(atPath: htdocs.path) else { return nil }
        self.root = root
        self.htdocs = htdocs
        // "8.2.4-0" is XAMPP 8.2.4, build 0.
        self.version = properties["base_stack_version"].map { String($0.split(separator: "-").first ?? Substring($0)) }
        let configuredData = (try? String(contentsOf: root.appendingPathComponent("etc/my.cnf"), encoding: .utf8))
            .flatMap { INIFile.settings($0, section: "mysqld").last { INIFile.optionName($0.key) == "datadir" }?.value }
        let data = configuredData ?? properties["mysql_data_directory"]
        self.dataDirectory = data.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root.appendingPathComponent("var/mysql", isDirectory: true)
    }

    /// Every installation in `applications`, such as /Applications/XAMPP and
    /// a renamed copy beside it.
    public static func find(applications: URL = URL(fileURLWithPath: "/Applications"), fileManager: FileManager = .default) -> [XAMPPInstallation] {
        let entries = (try? fileManager.contentsOfDirectory(at: applications, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { XAMPPInstallation(root: $0.appendingPathComponent("xamppfiles", isDirectory: true), fileManager: fileManager) }
            .sorted { $0.location.lastPathComponent.localizedStandardCompare($1.location.lastPathComponent) == .orderedAscending }
    }

    /// XAMPP-VM keeps its files and databases inside a Linux virtual machine.
    public static func virtualMachineFound(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".bitnami/stackman/machines/xampp").path)
    }

    /// The settings XAMPP's MariaDB reads from my.cnf.
    public func mysqlServerSettings() -> [(key: String, value: String)] {
        guard let text = try? String(contentsOf: mysqlConfiguration, encoding: .utf8) else { return [] }
        return INIFile.settings(text, section: "mysqld")
    }
}

/// php.ini, my.cnf and properties.ini style files.
public enum INIFile {
    /// The active settings in file order; with `section`, only that
    /// section's. Comments (`;`, `#`) and blank lines are skipped, quotes
    /// around values removed. A bare option such as `skip-networking` has an
    /// empty value.
    public static func settings(_ text: String, section: String? = nil) -> [(key: String, value: String)] {
        var current: String?
        var result: [(key: String, value: String)] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            if let section, current != section.lowercased() { continue }
            let key: String
            var value: String
            if let equals = line.firstIndex(of: "=") {
                key = line[..<equals].trimmingCharacters(in: .whitespaces)
                value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            } else {
                key = line
                value = ""
            }
            // A trailing comment after an unquoted value.
            if !value.hasPrefix("\""), !value.hasPrefix("'"), let comment = value.range(of: " ;") ?? value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            result.append((key, value))
        }
        return result
    }

    /// MySQL treats dashes and underscores in option names alike.
    public static func optionName(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "-", with: "_")
    }
}

/// An Apache `<VirtualHost>` block.
public struct ApacheVirtualHost: Hashable, Sendable {
    public var serverName: String
    public var aliases: [String]
    public var documentRoot: String

    public init(serverName: String, aliases: [String] = [], documentRoot: String) {
        self.serverName = serverName
        self.aliases = aliases
        self.documentRoot = documentRoot
    }
}

public enum ApacheConfiguration {
    /// Whether httpd.conf includes the virtual hosts file; XAMPP ships it
    /// commented out.
    public static func includesVirtualHosts(_ httpdConfiguration: String) -> Bool {
        httpdConfiguration.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.lowercased().hasPrefix("include") && trimmed.contains("httpd-vhosts.conf")
        }
    }

    /// The virtual hosts with a name and a document root, one per name; the
    /// example hosts XAMPP ships are left out.
    public static func virtualHosts(_ text: String) -> [ApacheVirtualHost] {
        var hosts: [ApacheVirtualHost] = []
        var current: (name: String?, aliases: [String], root: String?)?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("<virtualhost") {
                current = (nil, [], nil)
            } else if lower.hasPrefix("</virtualhost") {
                if let block = current, let name = block.name, let root = block.root,
                   !name.contains("dummy-host"), !hosts.contains(where: { $0.serverName == name }) {
                    hosts.append(ApacheVirtualHost(serverName: name, aliases: block.aliases, documentRoot: root))
                }
                current = nil
            } else if current != nil {
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                switch parts[0].lowercased() {
                case "servername": current?.name = value.split(separator: ":").first.map(String.init)?.lowercased()
                case "serveralias": current?.aliases += value.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                case "documentroot": current?.root = value
                default: break
                }
            }
        }
        return hosts
    }
}
