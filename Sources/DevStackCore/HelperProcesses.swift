import Darwin
import Foundation
import Security

/// The DevStack helpers running on this Mac. Every DevStack copy registers
/// its helper under the same launchd label and runs it from inside its own
/// app bundle, so a helper running from another copy (an old version, or one
/// signed by another team) takes the label and the privileged ports, and this
/// copy's helper cannot start.
public enum HelperProcesses {
    public struct Running: Hashable, Sendable {
        public let pid: Int32
        public let executable: String

        public init(pid: Int32, executable: String) {
            self.pid = pid
            self.executable = executable
        }

        /// The app bundle the helper runs from.
        public var applicationPath: String? {
            executable.range(of: "/Contents/Library/LaunchServices/").map { String(executable[..<$0.lowerBound]) }
        }
    }

    public static func running(runner: ProcessRunner = .init()) -> [Running] {
        guard let result = try? runner.run(executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                                           arguments: ["-x", "DevStackPrivilegedHelper"], timeout: 5) else { return [] }
        return result.standardOutput.split(whereSeparator: \.isNewline).compactMap { Int32($0) }.compactMap { pid in
            // Readable for root processes too; no privileges needed.
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return Running(pid: pid, executable: String(cString: buffer))
        }
    }

    /// Helpers that do not run from `application`.
    public static func others(than application: URL, runner: ProcessRunner = .init()) -> [Running] {
        let own = application.resolvingSymlinksInPath().path + "/"
        return running(runner: runner).filter { helper in
            !URL(fileURLWithPath: helper.executable).resolvingSymlinksInPath().path.hasPrefix(own)
        }
    }

    /// The signing Team ID of an app bundle, when it has one.
    public static func teamIdentifier(ofApplicationAt path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
