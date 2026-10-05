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

/// An Apache `Alias`: a URL path served from a folder.
public struct ApacheAlias: Hashable, Sendable {
    /// "/project1"
    public var path: String
    public var directory: String

    public init(path: String, directory: String) {
        self.path = path
        self.directory = directory
    }
}

/// An Apache `<VirtualHost>` block.
public struct ApacheVirtualHost: Hashable, Sendable {
    /// Lowercased, without a port; "" when the block names none.
    public var serverName: String
    public var aliases: [String]
    public var documentRoot: String
    /// The ports it listens on, from `<VirtualHost *:80 *:8080>`.
    public var ports: [String]
    /// `Alias` lines inside the block.
    public var pathAliases: [ApacheAlias]

    public init(serverName: String, aliases: [String] = [], documentRoot: String, ports: [String] = [], pathAliases: [ApacheAlias] = []) {
        self.serverName = serverName
        self.aliases = aliases
        self.documentRoot = documentRoot
        self.ports = ports
        self.pathAliases = pathAliases
    }
}

/// What an Apache configuration serves, read from httpd.conf and every file
/// it includes.
public struct ApacheSetup: Hashable, Sendable {
    /// The main DocumentRoot, outside any virtual host.
    public var documentRoot: String?
    public var virtualHosts: [ApacheVirtualHost] = []
    /// `Alias` lines outside virtual hosts.
    public var aliases: [ApacheAlias] = []
    /// `AliasMatch` patterns, which are regular expressions and not carried.
    public var aliasMatches: [String] = []
    /// The files read, in order.
    public var files: [String] = []

    public init() {}
}

public enum ApacheConfiguration {
    /// Reads `file` and everything it includes the way Apache does: paths
    /// relative to ServerRoot, `Include` and `IncludeOptional` with
    /// wildcards, `Define` variables and continued lines. An installation
    /// moved after it was set up (/Applications/XAMPP renamed XAMPP82) still
    /// names its old ServerRoot; paths under it are read as under
    /// `serverRoot`.
    public static func load(_ file: URL, serverRoot: URL, fileManager: FileManager = .default) -> ApacheSetup {
        var setup = ApacheSetup()
        var state = ParseState(serverRoot: serverRoot)
        state.installation = serverRoot.standardizedFileURL.path
        read(file, state: &state, setup: &setup, depth: 0, fileManager: fileManager)
        return setup
    }

    /// Reads configuration text on its own, without following includes.
    public static func parse(_ text: String, serverRoot: URL) -> ApacheSetup {
        var setup = ApacheSetup()
        var state = ParseState(serverRoot: serverRoot)
        parse(text, state: &state, setup: &setup, depth: 0, fileManager: .default, follow: false)
        return setup
    }

    /// The virtual hosts with a name and a document root, one per name; the
    /// example hosts XAMPP ships are left out.
    public static func virtualHosts(_ text: String) -> [ApacheVirtualHost] {
        var named: [ApacheVirtualHost] = []
        for host in parse(text, serverRoot: URL(fileURLWithPath: "/")).virtualHosts
        where !host.serverName.isEmpty && !host.documentRoot.isEmpty && !named.contains(where: { $0.serverName == host.serverName }) {
            named.append(host)
        }
        return named
    }

    private struct ParseState {
        var serverRoot: URL
        /// Where the installation really is, and the ServerRoot its
        /// configuration names when that differs.
        var installation: String?
        var movedFrom: String?
        var variables: [String: String] = [:]
        var visited: Set<String> = []
        var host: ApacheVirtualHost?
    }

    private static func read(_ file: URL, state: inout ParseState, setup: inout ApacheSetup, depth: Int, fileManager: FileManager) {
        let path = file.standardizedFileURL.path
        guard depth < 16, !state.visited.contains(path),
              let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else { return }
        state.visited.insert(path)
        setup.files.append(path)
        parse(text, state: &state, setup: &setup, depth: depth, fileManager: fileManager, follow: true)
    }

    private static func parse(_ text: String, state: inout ParseState, setup: inout ApacheSetup, depth: Int, fileManager: FileManager, follow: Bool) {
        var pending = ""
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = pending + rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\\") {
                pending = String(line.dropLast()) + " "
                continue
            }
            pending = ""
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let words = tokens(line).map { substitute($0, state.variables) }
            guard let directive = words.first?.lowercased() else { continue }
            let arguments = Array(words.dropFirst())
            switch directive {
            case "serverroot":
                guard let value = arguments.first else { continue }
                let named = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
                if let installation = state.installation, named != installation {
                    state.movedFrom = named
                } else {
                    state.serverRoot = URL(fileURLWithPath: value, isDirectory: true)
                }
            case "define":
                if arguments.count >= 2 { state.variables[arguments[0]] = arguments[1] }
            case "include", "includeoptional":
                guard follow, let pattern = arguments.first else { continue }
                for file in expand(resolve(pattern, state), fileManager: fileManager) {
                    read(file, state: &state, setup: &setup, depth: depth + 1, fileManager: fileManager)
                }
            case "<virtualhost":
                let ports = arguments.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ">")) }
                    .compactMap { $0.split(separator: ":").last.map(String.init) }.filter { !$0.isEmpty }
                state.host = ApacheVirtualHost(serverName: "", documentRoot: "", ports: ports)
            case "</virtualhost>":
                if let host = state.host, !host.serverName.contains("dummy-host") { setup.virtualHosts.append(host) }
                state.host = nil
            case "servername":
                if let value = arguments.first {
                    // "http://shop.test:80" and "shop.test:80" name shop.test.
                    var name = value.lowercased()
                    if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
                    state.host?.serverName = String(name.split(separator: ":").first ?? "")
                }
            case "serveralias":
                state.host?.aliases += arguments.map { $0.lowercased() }
            case "documentroot":
                guard let value = arguments.first else { continue }
                let root = resolve(value, state).path
                if state.host != nil { state.host?.documentRoot = root } else { setup.documentRoot = root }
            case "alias":
                guard arguments.count >= 2 else { continue }
                let alias = ApacheAlias(path: arguments[0], directory: resolve(arguments[1], state).path)
                if state.host != nil { state.host?.pathAliases.append(alias) } else { setup.aliases.append(alias) }
            case "aliasmatch":
                if arguments.count >= 2 { setup.aliasMatches.append("\(arguments[0]) → \(arguments[1])") }
            default:
                break
            }
        }
    }

    /// Words of a directive, with double-quoted words kept whole.
    static func tokens(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var hasWord = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                hasWord = true
            } else if character.isWhitespace, !quoted {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }

    private static func substitute(_ word: String, _ variables: [String: String]) -> String {
        guard word.contains("${") else { return word }
        var result = word
        for (name, value) in variables { result = result.replacingOccurrences(of: "${\(name)}", with: value) }
        return result
    }

    private static func resolve(_ path: String, _ state: ParseState) -> URL {
        var path = path
        if let moved = state.movedFrom, let installation = state.installation, path == moved || path.hasPrefix(moved + "/") {
            path = installation + path.dropFirst(moved.count)
        }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : state.serverRoot.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    /// The files an Include names: one file, every file in a folder, or the
    /// matches of a wildcard in the last part of the path.
    private static func expand(_ url: URL, fileManager: FileManager) -> [URL] {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        if !name.contains("*") && !name.contains("?") && !name.contains("[") {
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            guard isDirectory.boolValue else { return [url] }
            return ((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                .map { url.appendingPathComponent($0) }
        }
        let folder = url.deletingLastPathComponent()
        return ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            .filter { fnmatch(name, $0, 0) == 0 }
            .map { folder.appendingPathComponent($0) }
    }
}
