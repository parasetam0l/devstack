import Foundation

public extension SiteDefinition {
    /// The built-in default site. It always exists so that localhost, 127.0.0.1
    /// and unmatched hostnames land on a real page instead of the web server's
    /// compiled-in default (or the first unrelated vhost).
    static func defaultSite(paths: DevStackPaths, phpRuntimeID: String = "php-8.5") -> SiteDefinition {
        SiteDefinition(
            name: "localhost",
            hostname: "localhost",
            documentRoot: paths.defaultSiteRoot.path,
            tlsEnabled: true,
            phpRuntimeID: phpRuntimeID,
            logs: SiteLogPaths(
                access: paths.logs.appendingPathComponent("site-localhost-access.log").path,
                error: paths.logs.appendingPathComponent("site-localhost-error.log").path
            )
        )
    }
}

/// Placeholder entry point written into new vhost document roots so a fresh
/// site answers with something meaningful instead of a directory listing or a
/// 403. Existing index files are never overwritten.
public enum DefaultSiteContent {
    @discardableResult
    public static func ensurePlaceholderIndex(
        in documentRoot: URL,
        hostname: String,
        isDefaultSite: Bool,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: documentRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        for name in ["index.php", "index.html", "index.htm"] where fileManager.fileExists(atPath: documentRoot.appendingPathComponent(name).path) {
            return false
        }
        do {
            try AtomicFileWriter.write(
                placeholderIndexPHP(hostname: hostname, documentRoot: documentRoot.path, isDefaultSite: isDefaultSite),
                to: documentRoot.appendingPathComponent("index.php"),
                permissions: 0o644,
                fileManager: fileManager
            )
            return true
        } catch {
            return false
        }
    }

    static func placeholderIndexPHP(hostname: String, documentRoot: String, isDefaultSite: Bool) -> String {
        let heading = isDefaultSite ? "Your local stack is running" : "It works!"
        let detail = isDefaultSite
            ? "<p>Add and manage sites in the <strong>DevStack</strong> app; this default site answers on <strong>localhost</strong> and <strong>127.0.0.1</strong>.</p>"
            : "<p>Replace <code>index.php</code> in this folder with your project files.</p>"
        return """
        <?php
        // DevStack placeholder. Replace this file with your project's entry point.
        ?><!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(hostname)) — DevStack</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f5f7; color: #1d1d1f; }
        @media (prefers-color-scheme: dark) { body { background: #161617; color: #f5f5f7; } }
        main { max-width: 34rem; padding: 2.5rem; }
        .badge { font-size: .72rem; font-weight: 600; letter-spacing: .1em; text-transform: uppercase; color: #6e6e73; }
        h1 { font-size: 1.9rem; margin: .4rem 0 1rem; }
        p { line-height: 1.55; }
        code { background: rgba(127, 127, 127, .16); padding: .1rem .35rem; border-radius: .3rem; font-size: .85em; }
        </style>
        </head>
        <body>
        <main>
        <span class="badge">DevStack</span>
        <h1>\(heading)</h1>
        <p><strong>\(escape(hostname))</strong> is served from <code>\(escape(documentRoot))</code>.</p>
        <p>PHP <?= PHP_VERSION ?> is ready.</p>
        \(detail)
        </main>
        </body>
        </html>
        """
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
