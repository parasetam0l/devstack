import Darwin
import Foundation

public enum ProjectFramework: String, Hashable, Sendable {
    case laravel, symfony, wordpress, codeIgniter, drupal, yii, plainPHP, staticSite

    public var title: String {
        switch self {
        case .laravel: "Laravel"
        case .symfony: "Symfony"
        case .wordpress: "WordPress"
        case .codeIgniter: "CodeIgniter"
        case .drupal: "Drupal"
        case .yii: "Yii"
        case .plainPHP: "PHP"
        case .staticSite: "Static"
        }
    }
}

/// A project found in the other app.
public struct MigrationProject: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A folder in htdocs; it is copied.
        case folder
        /// A folder elsewhere that Apache served through an Alias or a
        /// virtual host; it stays where it is unless it is copied.
        case external
        /// Files directly in htdocs; they go to the localhost site.
        case looseFiles([String])
    }

    public var id: String
    public var name: String
    public var source: URL
    public var kind: Kind
    public var framework: ProjectFramework
    /// The web root inside the project: "" for the folder itself, or a
    /// subfolder such as "public".
    public var webRoot: String
    /// The virtual host name it answered to.
    public var virtualHost: String?
    /// The localhost/<path> it answered at through an Apache Alias.
    public var localhostPath: String?
    /// macOS lets DevStack read the folder; Desktop, Documents and
    /// Downloads need the user's permission first.
    public var readable: Bool
    public var files: Int
    public var bytes: Int64

    public init(id: String, name: String, source: URL, kind: Kind, framework: ProjectFramework, webRoot: String,
                virtualHost: String? = nil, localhostPath: String? = nil, readable: Bool = true, files: Int = 0, bytes: Int64 = 0) {
        self.id = id
        self.name = name
        self.source = source
        self.kind = kind
        self.framework = framework
        self.webRoot = webRoot
        self.virtualHost = virtualHost
        self.localhostPath = localhostPath
        self.readable = readable
        self.files = files
        self.bytes = bytes
    }

    /// The addresses it had: under localhost for a folder in htdocs or an
    /// Alias, and its virtual host name.
    public var originalURLs: [String] {
        var urls: [String] = []
        for path in [kind == .folder ? name : nil, localhostPath].compactMap({ $0 }) {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            urls += ["http://localhost/\(encoded)", "https://localhost/\(encoded)", "http://127.0.0.1/\(encoded)"]
        }
        if let virtualHost { urls += ["http://\(virtualHost)", "https://\(virtualHost)"] }
        return urls
    }
}

public struct MigrationDatabase: Identifiable, Hashable, Sendable {
    public var name: String
    /// XAMPP's empty sample database.
    public var isSample: Bool
    public var id: String { name }

    public init(name: String, isSample: Bool = false) {
        self.name = name
        self.isSample = isSample
    }
}

/// What an XAMPP installation holds, read without changing anything.
public struct XAMPPInventory: Sendable {
    public var installation: XAMPPInstallation
    /// The folder Apache served at localhost: XAMPP's htdocs, or the
    /// DocumentRoot httpd.conf sets instead.
    public var htdocs: URL
    public var projects: [MigrationProject]
    public var databases: [MigrationDatabase]
    /// The data folder is readable without an administrator password.
    public var dataReadable: Bool
    /// Bytes of the data folder that could be measured: all of it when it is
    /// readable, else only its shared files.
    public var dataBytes: Int64
    public var serverArchitectures: Set<String>
    public var virtualHostsIncluded: Bool
    public var phpINI: String?
    /// XAMPP's own pages in htdocs, which are not imported.
    public var skippedDefaults: [String]
    /// Apache settings that don't carry over, one sentence each.
    public var notes: [String]

    public init(installation: XAMPPInstallation, projects: [MigrationProject] = [], databases: [MigrationDatabase] = [],
                dataReadable: Bool = true, dataBytes: Int64 = 0, serverArchitectures: Set<String> = ["arm64"],
                virtualHostsIncluded: Bool = false, phpINI: String? = nil, skippedDefaults: [String] = [], notes: [String] = []) {
        self.installation = installation
        self.htdocs = installation.htdocs
        self.notes = notes
        self.projects = projects
        self.databases = databases
        self.dataReadable = dataReadable
        self.dataBytes = dataBytes
        self.serverArchitectures = serverArchitectures
        self.virtualHostsIncluded = virtualHostsIncluded
        self.phpINI = phpINI
        self.skippedDefaults = skippedDefaults
    }

    public var projectBytes: Int64 { projects.filter { $0.kind != .external }.reduce(0) { $0 + $1.bytes } }

    /// The server only runs through Rosetta on this Mac.
    public var serverNeedsRosetta: Bool {
        MachO.currentArchitecture == "arm64" && !serverArchitectures.isEmpty && !serverArchitectures.contains("arm64")
    }
}

public enum XAMPPScanner {
    /// XAMPP's own pages in htdocs.
    static let defaultEntries: Set<String> = ["applications.html", "bitnami.css", "dashboard", "favicon.ico", "img", "webalizer", "xampp", "forbidden", "restricted"]
    /// Databases that belong to the server or to XAMPP's phpMyAdmin.
    static let systemDatabases: Set<String> = ["mysql", "performance_schema", "information_schema", "sys", "phpmyadmin"]

    public static func scan(_ installation: XAMPPInstallation, fileManager: FileManager = .default,
                            progress: (String) -> Void = { _ in }) -> XAMPPInventory {
        var inventory = XAMPPInventory(installation: installation)
        progress("Reading Apache's configuration…")
        let apache = ApacheConfiguration.load(installation.httpdConfiguration, serverRoot: installation.root, fileManager: fileManager)
        inventory.virtualHostsIncluded = !apache.virtualHosts.isEmpty
        inventory.phpINI = try? String(contentsOf: installation.phpINI, encoding: .utf8)
        inventory.serverArchitectures = MachO.architectures(of: installation.mysqld)

        // httpd.conf may serve localhost from somewhere other than htdocs.
        let configuredRoot = apache.documentRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
        let htdocs = (configuredRoot ?? installation.htdocs).resolvingSymlinksInPath().standardizedFileURL
        inventory.htdocs = htdocs
        let entries = ((try? fileManager.contentsOfDirectory(at: htdocs, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var looseFiles: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if defaultEntries.contains(name.lowercased()) || (name == "index.php" && isXAMPPIndex(entry)) {
                inventory.skippedDefaults.append(name)
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else {
                looseFiles.append(name)
                continue
            }
            progress("Measuring \(name)…")
            let detected = ProjectDetector.detect(at: entry, fileManager: fileManager)
            let size = FolderSize.measure(entry, fileManager: fileManager)
            inventory.projects.append(MigrationProject(id: entry.path, name: name, source: entry, kind: .folder,
                                                       framework: detected.framework, webRoot: detected.webRoot,
                                                       files: size.files, bytes: size.bytes))
        }
        if !looseFiles.isEmpty {
            let size = looseFiles.reduce(into: (files: 0, bytes: Int64(0))) { total, name in
                total.files += 1
                total.bytes += Int64((try? htdocs.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            inventory.projects.append(MigrationProject(id: htdocs.path + "/", name: "Files in htdocs", source: htdocs, kind: .looseFiles(looseFiles),
                                                       framework: .plainPHP, webRoot: "", files: size.files, bytes: size.bytes))
        }

        addApacheProjects(apache, installation: installation, htdocs: htdocs, to: &inventory, fileManager: fileManager, progress: progress)

        progress("Reading the databases…")
        let data = installation.dataDirectory
        let dataEntries = (try? fileManager.contentsOfDirectory(at: data, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        var readable = fileManager.isReadableFile(atPath: data.path)
        for entry in dataEntries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                let name = DatabaseFolderName.decode(entry.lastPathComponent)
                guard !entry.lastPathComponent.hasPrefix("#"), !systemDatabases.contains(name.lowercased()), name != "lost+found" else { continue }
                if access(entry.path, R_OK | X_OK) != 0 { readable = false }
                inventory.databases.append(MigrationDatabase(name: name, isSample: name == "test"))
            } else {
                inventory.dataBytes += Int64(values?.fileSize ?? 0)
                if access(entry.path, R_OK) != 0 { readable = false }
            }
        }
        inventory.databases.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        inventory.dataReadable = readable && !dataEntries.isEmpty
        if inventory.dataReadable { inventory.dataBytes = FolderSize.measure(data, fileManager: fileManager).bytes }
        return inventory
    }

    static let webRootNames: Set<String> = ["public", "web", "public_html", "htdocs", "www"]
    static let localhostNames: Set<String> = ["", "localhost", "127.0.0.1", "::1"]

    /// Projects Apache served from folders outside htdocs, through Alias
    /// lines (at localhost/<path>) and virtual hosts (at their own name),
    /// one per folder; and virtual hosts on folders in htdocs.
    static func addApacheProjects(_ apache: ApacheSetup, installation: XAMPPInstallation, htdocs: URL, to inventory: inout XAMPPInventory,
                                  fileManager: FileManager, progress: (String) -> Void) {
        let xampp = installation.root.resolvingSymlinksInPath().standardizedFileURL
        func resolved(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL }
        func inside(_ url: URL, _ folder: URL) -> Bool { url.path == folder.path || url.path.hasPrefix(folder.path + "/") }
        /// XAMPP's own aliases (phpMyAdmin, icons, the manual) and hosts.
        func belongsToXAMPP(_ url: URL) -> Bool { inside(url, xampp) && !inside(url, htdocs) }

        var external: [String: Int] = [:]
        func project(serving served: URL) -> Int {
            if let index = external[served.path] { return index }
            let isWebRoot = webRootNames.contains(served.lastPathComponent.lowercased())
            let folder = isWebRoot ? served.deletingLastPathComponent() : served
            progress("Reading \(folder.lastPathComponent)…")
            let readable = FolderAccess.state(of: folder) == .readable
            let detected = readable ? ProjectDetector.detect(at: folder, fileManager: fileManager) : (framework: ProjectFramework.plainPHP, webRoot: "")
            let size = readable ? FolderSize.measure(folder, fileManager: fileManager) : (files: 0, bytes: Int64(0))
            inventory.projects.append(MigrationProject(id: served.path, name: folder.lastPathComponent, source: folder, kind: .external,
                                                       framework: detected.framework, webRoot: isWebRoot ? served.lastPathComponent : "",
                                                       readable: readable, files: size.files, bytes: size.bytes))
            external[served.path] = inventory.projects.count - 1
            return inventory.projects.count - 1
        }

        // Hosts on htdocs, or named localhost, are localhost: their Alias
        // lines are localhost's.
        var localhostAliases = apache.aliases
        var hosts: [ApacheVirtualHost] = []
        for host in apache.virtualHosts {
            if host.documentRoot.isEmpty || resolved(host.documentRoot).path == htdocs.path || localhostNames.contains(host.serverName) {
                localhostAliases += host.pathAliases
            } else if !hosts.contains(where: { $0.serverName == host.serverName }) {
                hosts.append(host)
            }
        }

        for alias in localhostAliases {
            let target = resolved(alias.directory)
            let path = alias.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, !belongsToXAMPP(target) else { continue }
            if inside(target, htdocs) {
                inventory.notes.append("Alias \(alias.path) served \(target.path.dropFirst(htdocs.path.count + 1)) in htdocs; DevStack serves that folder at its own name.")
                continue
            }
            guard FolderAccess.state(of: target) != .missing else {
                inventory.notes.append("Alias \(alias.path) pointed to \(target.path), which no longer exists.")
                continue
            }
            let index = project(serving: target)
            if inventory.projects[index].localhostPath == nil { inventory.projects[index].localhostPath = path }
        }

        for host in hosts {
            let root = resolved(host.documentRoot)
            guard !belongsToXAMPP(root) else { continue }
            if !host.aliases.isEmpty {
                inventory.notes.append("\(host.serverName) also answered to \(host.aliases.joined(separator: ", ")); a DevStack site has one name.")
            }
            if let port = host.ports.first(where: { !["80", "443", "*"].contains($0) }) {
                inventory.notes.append("\(host.serverName) listened on port \(port); in DevStack it answers on DevStack's web ports.")
            }
            if !host.pathAliases.isEmpty {
                inventory.notes.append("\(host.serverName) had Alias lines (\(host.pathAliases.map(\.path).joined(separator: ", "))), which don't carry over.")
            }
            if inside(root, htdocs) {
                let relative = root.path.dropFirst(htdocs.path.count + 1)
                let folder = String(relative.split(separator: "/").first ?? "")
                if let index = inventory.projects.firstIndex(where: { $0.kind == .folder && $0.name == folder }), inventory.projects[index].virtualHost == nil {
                    inventory.projects[index].virtualHost = host.serverName
                    inventory.projects[index].webRoot = String(relative.dropFirst(folder.count).drop { $0 == "/" })
                }
                continue
            }
            guard FolderAccess.state(of: root) != .missing else {
                inventory.notes.append("\(host.serverName) pointed to \(root.path), which no longer exists.")
                continue
            }
            let index = project(serving: root)
            if inventory.projects[index].virtualHost == nil { inventory.projects[index].virtualHost = host.serverName }
        }
        for pattern in apache.aliasMatches where !pattern.contains(xampp.path) {
            inventory.notes.append("AliasMatch \(pattern) is a pattern and doesn't carry over.")
        }
    }

    /// XAMPP's index.php only sends visitors to its dashboard.
    private static func isXAMPPIndex(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.count < 2_000 else { return false }
        return text.contains("/dashboard/")
    }
}

/// How a project is laid out, from the files at its top.
public enum ProjectDetector {
    public static func detect(at folder: URL, fileManager: FileManager = .default) -> (framework: ProjectFramework, webRoot: String) {
        func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: folder.appendingPathComponent(path).path) }
        let hasRootIndex = exists("index.php") || exists("index.html") || exists("index.htm")
        if exists("artisan"), exists("public/index.php") { return (.laravel, "public") }
        if exists("bin/console"), exists("public/index.php") { return (.symfony, "public") }
        if exists("spark"), exists("public/index.php") { return (.codeIgniter, "public") }
        if exists("wp-config.php") || exists("wp-load.php") { return (.wordpress, "") }
        if exists("web/core/lib/Drupal.php") { return (.drupal, "web") }
        if exists("core/lib/Drupal.php") { return (.drupal, "") }
        if exists("yii"), exists("web/index.php") { return (.yii, "web") }
        if exists("system/core/CodeIgniter.php") { return (.codeIgniter, "") }
        if !hasRootIndex, exists("public/index.php") { return (.plainPHP, "public") }
        if !hasRootIndex, exists("web/index.php") { return (.plainPHP, "web") }
        let topLevel = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        if !topLevel.contains(where: { $0.lowercased().hasSuffix(".php") }), exists("index.html") || exists("index.htm") {
            return (.staticSite, "")
        }
        return (.plainPHP, "")
    }
}

public enum FolderAccess {
    public enum State: Equatable, Sendable { case readable, unreadable, missing }

    /// Whether a folder exists and can be listed. macOS refuses folders in
    /// Desktop, Documents and Downloads until the user allows DevStack; the
    /// first try asks.
    public static func state(of folder: URL) -> State {
        var info = stat()
        if stat(folder.path, &info) != 0 { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil ? .readable : .unreadable
    }
}

public enum FolderSize {
    /// Files and bytes under `folder`, symbolic links counted as files and
    /// not followed. Unreadable folders count as empty.
    public static func measure(_ folder: URL, fileManager: FileManager = .default) -> (files: Int, bytes: Int64) {
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
                                                      options: [], errorHandler: { _, _ in true }) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]) else { continue }
            if values.isDirectory == true, values.isSymbolicLink != true { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }
}

/// MariaDB and MySQL store a database named "my-db" in a folder named
/// "my@002ddb".
public enum DatabaseFolderName {
    public static func decode(_ folder: String) -> String {
        var result = ""
        var characters = Array(folder)
        var index = 0
        while index < characters.count {
            if characters[index] == "@", index + 4 < characters.count,
               let value = UInt32(String(characters[(index + 1)...(index + 4)]), radix: 16), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
                index += 5
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        characters.removeAll()
        return result
    }

    public static func encode(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if (scalar.value < 0x80 && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")) {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(format: "@%04x", scalar.value)
            }
        }
        return result
    }
}

public enum MachO {
    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    /// The architectures an executable contains, from its header.
    public static func architectures(of url: URL) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 4_096), header.count >= 8 else { return [] }
        try? handle.close()
        let bytes = [UInt8](header)
        func big(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func little(_ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return bytes[offset..<(offset + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        func name(_ cpu: UInt32) -> String? {
            switch cpu {
            case 0x0100_0007: "x86_64"
            case 0x0100_000C: "arm64"
            case 7: "i386"
            default: nil
            }
        }
        switch big(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let count = Int(big(4))
            let stride = big(0) == 0xCAFE_BABF ? 32 : 20
            return Set((0..<min(count, 16)).compactMap { name(big(8 + $0 * stride)) })
        case 0xCFFA_EDFE, 0xCEFA_EDFE:
            return name(little(4)).map { [$0] } ?? []
        default:
            return []
        }
    }
}

public enum MigrationNaming {
    /// "atasarim-v2 kopyası 10" → "atasarim-v2-kopyasi-10".
    public static func slug(_ name: String) -> String {
        let latin = name.applyingTransform(StringTransform("Any-Latin; Latin-ASCII; Lower"), reverse: false) ?? name.lowercased()
        var result = ""
        for scalar in latin.unicodeScalars {
            if scalar.value < 0x80, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "site" : String(trimmed.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A .localhost name for a project; names ending in .test or .localhost
    /// are kept, others (.local belongs to Bonjour, .dev is a real domain)
    /// trade their last label for .localhost.
    /// With `keepDomains` (the helper can serve any name), a virtual host
    /// keeps its own name, except .local, which belongs to Bonjour.
    public static func hostname(for project: MigrationProject, keepDomains: Bool = false, taken: Set<String>) -> String {
        var base: String
        if keepDomains, let host = project.virtualHost, !host.hasSuffix(".local"),
           let valid = try? HostnameValidator.validateSite(host) {
            base = valid
        } else if let host = project.virtualHost, !host.isEmpty {
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") {
                base = host
            } else {
                let labels = host.split(separator: ".").map(String.init)
                let kept = labels.count > 1 ? labels.dropLast() : labels[...]
                base = kept.filter { $0 != "www" }.map(slug).joined(separator: ".") + ".localhost"
                if base == ".localhost" { base = slug(project.name) + ".localhost" }
            }
        } else {
            base = slug(project.name) + ".localhost"
        }
        return unique(base, taken: taken) { name, number in
            let parts = name.split(separator: ".", maxSplits: 1)
            return "\(parts[0])-\(number).\(parts.count > 1 ? String(parts[1]) : "localhost")"
        }
    }

    /// A folder name not yet used in `parent`.
    public static func folder(named name: String, in parent: URL, taken: Set<String> = [], fileManager: FileManager = .default) -> URL {
        let chosen = unique(name, taken: taken.union(((try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []).map { $0.lowercased() })) { name, number in
            number == 2 ? "\(name)-xampp" : "\(name)-xampp-\(number - 1)"
        }
        return parent.appendingPathComponent(chosen, isDirectory: true)
    }

    /// "shop" → "shop_xampp" when "shop" is taken.
    public static func databaseName(_ name: String, taken: Set<String>) -> String {
        unique(name, taken: taken) { name, number in number == 2 ? "\(name)_xampp" : "\(name)_xampp\(number - 1)" }
    }

    private static func unique(_ name: String, taken: Set<String>, variant: (String, Int) -> String) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(name.lowercased()) else { return name }
        var number = 2
        while lowered.contains(variant(name, number).lowercased()) { number += 1 }
        return variant(name, number)
    }
}

public enum PHPVersionMapping {
    /// The DevStack PHP closest to `version` ("8.2"): the oldest one at or
    /// above it, else the newest one below it.
    public static func runtimeID(for version: String?, available: [String]) -> String? {
        func number(_ text: Substring) -> (Int, Int)? {
            let parts = text.split(separator: ".").compactMap { Int($0) }
            return parts.count >= 2 ? (parts[0], parts[1]) : nil
        }
        let runtimes = available.compactMap { id -> (id: String, version: (Int, Int))? in
            guard id.hasPrefix("php-"), let version = number(id.dropFirst(4)) else { return nil }
            return (id, version)
        }.sorted { $0.version < $1.version }
        guard let version, let wanted = number(Substring(version)) else { return runtimes.last?.id }
        return runtimes.first { $0.version >= wanted }?.id ?? runtimes.last?.id
    }
}

public enum PHPSettingsImport {
    /// DevStack's per-site limits raised to XAMPP's where XAMPP allowed more,
    /// so nothing that ran there hits a lower limit.
    public static func overrides(fromPHPINI text: String?, base: PHPSiteOverrides = PHPSiteOverrides()) -> PHPSiteOverrides {
        guard let text else { return base }
        let values = INIFile.settings(text).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        var result = base
        if let value = values["memory_limit"] { result.memoryLimit = larger(size: value, than: base.memoryLimit) }
        if let value = values["upload_max_filesize"] { result.uploadMaxFilesize = larger(size: value, than: base.uploadMaxFilesize) }
        if let value = values["post_max_size"] { result.postMaxSize = larger(size: value, than: base.postMaxSize) }
        if let value = values["max_execution_time"].flatMap(Int.init) {
            result.maxExecutionTime = value == 0 || base.maxExecutionTime == 0 ? 0 : max(value, base.maxExecutionTime)
        }
        if let value = values["max_input_vars"].flatMap(Int.init) { result.maxInputVars = max(value, base.maxInputVars) }
        return result
    }

    /// Bytes of a php.ini size ("512M", "1G", "-1" for no limit).
    public static func bytes(_ size: String) -> Int64? {
        let trimmed = size.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed == "-1" { return .max }
        let multiplier: Int64
        switch trimmed.last {
        case "K": multiplier = 1 << 10
        case "M": multiplier = 1 << 20
        case "G": multiplier = 1 << 30
        default: multiplier = 1
        }
        let digits = multiplier == 1 ? trimmed : String(trimmed.dropLast())
        return Int64(digits).map { $0 * multiplier }
    }

    private static func larger(size: String, than base: String) -> String {
        guard let value = bytes(size), let current = bytes(base), value > current,
              size.range(of: "^-?[0-9]+[KMGkmg]?$", options: .regularExpression) != nil else { return base }
        return size.uppercased()
    }
}
