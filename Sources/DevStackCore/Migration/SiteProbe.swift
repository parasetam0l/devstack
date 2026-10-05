import Foundation

/// Requests an imported site from DevStack's web server and reads what its
/// error log says, to tell whether it works.
public enum SiteProbe {
    public struct Response: Hashable, Sendable {
        public var status: Int?
        public var redirect: String?
        public var error: String?
    }

    /// Requests `path` on `host` from the web server listening on 127.0.0.1
    /// at `port`, whatever the host resolves to. Certificates are not
    /// checked here; trust is a check of its own.
    public static func request(host: String, port: UInt16, path: String = "/", https: Bool = true, timeout: TimeInterval = 30) -> Response {
        let scheme = https ? "https" : "http"
        let url = "\(scheme)://\(host):\(port)\(path.hasPrefix("/") ? path : "/" + path)"
        guard let result = try? ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
            "--silent", "--show-error", "--insecure", "--output", "/dev/null", "--max-time", String(Int(timeout)),
            "--resolve", "\(host):\(port):127.0.0.1", "--write-out", "%{http_code} %{redirect_url}", url
        ], timeout: timeout + 5) else {
            return Response(error: "The request did not finish.")
        }
        let parts = result.standardOutput.split(separator: " ", maxSplits: 1).map(String.init)
        let status = parts.first.flatMap { Int($0) }
        return Response(status: status == 0 ? nil : status, redirect: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil,
                        error: result.exitCode == 0 ? nil : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func size(of file: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
    }

    /// Lines written to `file` after `offset`.
    public static func lines(in file: URL, after offset: UInt64) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: 256 * 1_024)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// What the log says went wrong, in a sentence a developer can act on.
    public static func diagnosis(_ lines: [String]) -> String? {
        let relevant = lines.filter { line in
            let lower = line.lowercased()
            return (lower.contains("fatal") || lower.contains("error") || lower.contains("warning")) && !lower.contains("deprecated")
        }
        guard let line = relevant.last else { return nil }
        let lower = line.lowercased()
        if lower.contains("access denied for user") {
            return "MySQL refused the project's login. Use the login on the Database page, or turn on root without a password."
        }
        if lower.contains("unknown database") { return "The project uses a database that isn't in DevStack's MySQL." }
        if lower.contains("connection refused") || lower.contains("no such file or directory") && lower.contains("mysql")
            || lower.contains("php_network_getaddresses") {
            return "The project can't reach MySQL. Check the host and port in its settings."
        }
        if lower.contains("call to undefined function") { return "A PHP function is missing: \(trimmed(line))" }
        return trimmed(line)
    }

    private static func trimmed(_ line: String) -> String {
        // Drop the timestamp and process prefix PHP-FPM and Apache add.
        let message = line.replacing(/^\[[^\]]*\]\s*/, with: "").replacing(/^(\[[^\]]*\]\s*)+/, with: "")
        return message.count > 220 ? String(message.prefix(220)) + "…" : message
    }
}
