import Darwin
import Foundation

/// The program listening on a TCP port, as far as this user can see. Without
/// root, lsof lists only this user's processes; that covers the servers an
/// old DevStack copy left running, or a Homebrew service.
public struct PortOwner: Hashable, Sendable {
    public let pid: Int32
    public let command: String
    public let executable: String?

    public init(pid: Int32, command: String, executable: String?) {
        self.pid = pid
        self.command = command
        self.executable = executable
    }

    /// A server from a DevStack runtime: one this copy lost track of, or one
    /// another copy (an old version) left running.
    public var isDevStackRuntime: Bool {
        guard let executable else { return false }
        return executable.contains("DevStack") && executable.contains("/Runtimes/")
    }

    /// "httpd (PID 812)".
    public var summary: String {
        "\(executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? command) (PID \(pid))"
    }

    public static func lookup(port: UInt16, runner: ProcessRunner = .init()) -> PortOwner? {
        guard let result = try? runner.run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                                           arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"], timeout: 5),
              result.exitCode == 0 else { return nil }
        var pid: Int32?
        var command: String?
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p"), pid == nil { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return PortOwner(pid: pid, command: command ?? "unknown", executable: HelperProcesses.executablePath(of: pid))
    }

    /// Asks the server to shut down the way DevStack stops its own.
    public func stop() {
        let signal: Int32 = switch command {
        case "postgres": SIGINT
        case "nginx": SIGQUIT
        default: SIGTERM
        }
        kill(pid, signal)
    }
}

/// A port a service needs, taken by another program.
public struct PortConflict: Hashable, Sendable {
    public let port: UInt16
    public let service: ServiceKind
    public let owner: PortOwner?

    public init(port: UInt16, service: ServiceKind, owner: PortOwner?) {
        self.port = port
        self.service = service
        self.owner = owner
    }

    /// "Port 8080 (Apache) is used by httpd (PID 812), a server another DevStack copy left running."
    public var description: String {
        let user = owner.map { owner in
            " by \(owner.summary)" + (owner.isDevStackRuntime ? ", a server another DevStack copy left running" : "")
        } ?? " by another program"
        return "Port \(port) (\(service.displayName)) is used\(user)."
    }

    public var recoveryAction: String {
        owner?.isDevStackRuntime == true
            ? "Stop it from Doctor, then start the stack again."
            : "Quit that program, or choose another port in Settings → Ports."
    }

    public var failure: ServiceFailure {
        ServiceFailure(message: description, recoveryAction: recoveryAction)
    }
}
