import Foundation

/// Updates the copied project's own settings that point at the other app:
/// a renamed database, MySQL's port and the site's address. Only the copy
/// changes, and each edited file keeps a backup beside it.
public enum ProjectSettingsUpdater {
    public static let backupSuffix = ".xampp-backup"

    /// What WordPress's wp-config.php says.
    public struct WordPressSettings: Hashable, Sendable {
        public var database: String?
        public var tablePrefix: String
        public var host: String?
    }

    public static func wordPressSettings(in project: URL) -> WordPressSettings? {
        guard let text = try? String(contentsOf: project.appendingPathComponent("wp-config.php"), encoding: .utf8) else { return nil }
        let prefix = text.firstMatch(of: /\$table_prefix\s*=\s*['"]([A-Za-z0-9_]+)['"]/).map { String($0.1) } ?? "wp_"
        return WordPressSettings(database: defineValue("DB_NAME", in: text), tablePrefix: prefix, host: defineValue("DB_HOST", in: text))
    }

    /// The database a project's .env names.
    public static func dotEnvDatabase(in project: URL) -> String? {
        guard let text = try? String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        return envValue("DB_DATABASE", in: text)
    }

    /// Applies the changes and returns one line per file changed.
    public static func update(project: URL, renamedDatabases: [String: String], mysqlPort: UInt16, newURL: String,
                              oldURLs: [String]) throws -> [String] {
        var changes: [String] = []
        let wpConfig = project.appendingPathComponent("wp-config.php")
        if var text = try? String(contentsOf: wpConfig, encoding: .utf8) {
            let original = text
            if let database = defineValue("DB_NAME", in: text), let renamed = renamedDatabases[database] {
                text = replaceDefine("DB_NAME", with: renamed, in: text)
            }
            // An explicit port of 3306 would reach whatever else holds it.
            if let host = defineValue("DB_HOST", in: text), let port = host.split(separator: ":").last.flatMap({ UInt16($0) }),
               host.contains(":"), port != mysqlPort {
                text = replaceDefine("DB_HOST", with: "\(host.split(separator: ":").first ?? "127.0.0.1"):\(mysqlPort)", in: text)
            }
            for name in ["WP_HOME", "WP_SITEURL"] where defineValue(name, in: text).map({ value in oldURLs.contains { value.hasPrefix($0) } }) == true {
                text = replaceDefine(name, with: newURL, in: text)
            }
            if text != original {
                try backUpAndWrite(text, to: wpConfig)
                changes.append("wp-config.php: database settings and address")
            }
        }
        let dotEnv = project.appendingPathComponent(".env")
        if var text = try? String(contentsOf: dotEnv, encoding: .utf8) {
            let original = text
            if let database = envValue("DB_DATABASE", in: text), let renamed = renamedDatabases[database] {
                text = replaceEnv("DB_DATABASE", with: renamed, in: text)
            }
            if let port = envValue("DB_PORT", in: text).flatMap({ UInt16($0) }), port != mysqlPort,
               envValue("DB_CONNECTION", in: text).map({ $0 == "mysql" || $0 == "mariadb" }) ?? true {
                text = replaceEnv("DB_PORT", with: String(mysqlPort), in: text)
            }
            if let url = envValue("APP_URL", in: text), oldURLs.contains(where: { url.hasPrefix($0) }) {
                text = replaceEnv("APP_URL", with: newURL, in: text)
            }
            if text != original {
                try backUpAndWrite(text, to: dotEnv)
                changes.append(".env: database settings and APP_URL")
            }
        }
        return changes
    }

    static func defineValue(_ name: String, in text: String) -> String? {
        for match in text.matches(of: /define\(\s*['"]([A-Z_]+)['"]\s*,\s*['"]([^'"]*)['"]\s*\)/) where match.1 == name {
            return String(match.2)
        }
        return nil
    }

    static func replaceDefine(_ name: String, with value: String, in text: String) -> String {
        text.replacing(/define\(\s*['"]([A-Z_]+)['"]\s*,\s*['"]([^'"]*)['"]\s*\)/) { match in
            match.1 == name ? "define( '\(name)', '\(value.replacingOccurrences(of: "'", with: "\\'"))' )" : String(match.0)
        }
    }

    static func envValue(_ name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(name + "=") else { continue }
            return String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func replaceEnv(_ name: String, with value: String, in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(name + "=") ? "\(name)=\(value)" : String(line)
        }.joined(separator: "\n")
    }

    private static func backUpAndWrite(_ text: String, to file: URL) throws {
        let backup = URL(fileURLWithPath: file.path + backupSuffix)
        if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: file, to: backup) }
        try AtomicFileWriter.write(text, to: file, permissions: 0o644)
    }
}

/// Replaces a WordPress site's old address with its new one throughout its
/// database, keeping PHP-serialized values valid. It runs as a PHP script
/// with DevStack's PHP, as WP-CLI's search-replace does.
public enum WordPressAddressUpdate {
    /// Old → new pairs, longest first so "localhost/shop2" is not caught by
    /// "localhost/shop"; JSON-escaped forms are included.
    public static func pairs(oldURLs: [String], newURL: String) -> [[String]] {
        var pairs: [[String]] = []
        for old in Set(oldURLs.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) where old != newURL {
            pairs.append([old, newURL])
            pairs.append([old.replacingOccurrences(of: "/", with: "\\/"), newURL.replacingOccurrences(of: "/", with: "\\/")])
        }
        return pairs.sorted { $0[0].count > $1[0].count }
    }

    public static let script = #"""
    <?php
    // DevStack: replace a WordPress site's old address in its database.
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $db = new mysqli(getenv('DS_HOST'), getenv('DS_USER'), getenv('DS_PASSWORD'), getenv('DS_DATABASE'), (int) getenv('DS_PORT'));
    $db->set_charset('utf8mb4');
    $pairs = json_decode(getenv('DS_PAIRS'), true);
    $prefix = getenv('DS_PREFIX');
    $patterns = [];
    foreach ($pairs as $pair) { $patterns[] = ['~' . preg_quote($pair[0], '~') . '(?![A-Za-z0-9_.-])~', $pair[1], $pair[0]]; }

    function ds_replace($value, $patterns, &$changed) {
        if (is_string($value)) {
            $data = @unserialize($value, ['allowed_classes' => false]);
            if (($data !== false || $value === 'b:0;') && !is_object($data)) {
                $replaced = ds_replace($data, $patterns, $changed);
                return $replaced === $data ? $value : serialize($replaced);
            }
            foreach ($patterns as $pattern) {
                if (strpos($value, $pattern[2]) === false) { continue; }
                $value = preg_replace($pattern[0], $pattern[1], $value, -1, $count);
                if ($count > 0) { $changed = true; }
            }
            return $value;
        }
        if (is_array($value)) {
            foreach ($value as $key => $item) { $value[$key] = ds_replace($item, $patterns, $changed); }
        }
        return $value;
    }

    $rows = 0;
    $like = $db->real_escape_string(str_replace('_', '\_', $prefix)) . '%';
    $tables = $db->query("SHOW TABLES LIKE '" . $like . "'");
    while ($table = $tables->fetch_row()) {
        $name = $table[0];
        $columns = $db->query("SHOW COLUMNS FROM `" . str_replace('`', '``', $name) . "`");
        $key = null; $texts = [];
        while ($column = $columns->fetch_assoc()) {
            if ($column['Key'] === 'PRI' && $key === null) { $key = $column['Field']; }
            if (preg_match('/char|text/i', $column['Type'])) { $texts[] = $column['Field']; }
        }
        if ($key === null || !$texts) { continue; }
        foreach ($texts as $field) {
            $conditions = [];
            foreach ($pairs as $pair) { $conditions[] = "`$field` LIKE '%" . $db->real_escape_string(addcslashes($pair[0], '%_\\')) . "%'"; }
            $result = $db->query("SELECT `$key`, `$field` FROM `$name` WHERE " . implode(' OR ', $conditions));
            $update = $db->prepare("UPDATE `$name` SET `$field` = ? WHERE `$key` = ?");
            while ($row = $result->fetch_row()) {
                $changed = false;
                $value = ds_replace($row[1], $patterns, $changed);
                if ($changed) { $update->bind_param('ss', $value, $row[0]); $update->execute(); $rows++; }
            }
        }
    }
    echo $rows;
    """#
}
