import Darwin
import Foundation

/// A long-running command that reports progress and stops when cancelled:
/// a dump writing to a file, or a client reading SQL from one.
enum StreamingCommand {
    /// Runs `executable`. With `inputFile`, its contents are fed to the
    /// command's standard input and `inputProgress` receives the bytes sent;
    /// with `outputFile`, standard output goes there. `poll` runs about ten
    /// times a second while the command runs.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        inputFile: URL? = nil,
        outputFile: URL? = nil,
        inputProgress: (@Sendable (Int64) -> Void)? = nil,
        poll: () -> Void = {},
        isCancelled: () -> Bool = { false },
        timeout: TimeInterval = 24 * 3_600
    ) throws -> CommandResult {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("devstack-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdoutURL = outputFile ?? scratch.appendingPathComponent("stdout")
        let stderrURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        let pipe = inputFile == nil ? nil : Pipe()
        if let pipe { process.standardInput = pipe } else { process.standardInput = FileHandle.nullDevice }
        try process.run()

        // Feed the input on its own thread: writing blocks while the command
        // works through what it has, and fails rather than signals once the
        // command has exited.
        let feeder: Thread?
        if let inputFile, let pipe {
            let descriptor = pipe.fileHandleForWriting.fileDescriptor
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            let source = inputFile
            let report = inputProgress
            feeder = Thread {
                defer { try? pipe.fileHandleForWriting.close() }
                guard let handle = try? FileHandle(forReadingFrom: source) else { return }
                defer { try? handle.close() }
                var sent: Int64 = 0
                while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    let complete = chunk.withUnsafeBytes { buffer -> Bool in
                        var offset = 0
                        while offset < buffer.count {
                            let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                            if written < 0 { if errno == EINTR { continue }; return false }
                            offset += written
                        }
                        return true
                    }
                    guard complete else { return }
                    sent += Int64(chunk.count)
                    report?(sent)
                }
            }
            feeder?.start()
        } else {
            feeder = nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        var cancelled = false
        while process.isRunning {
            if isCancelled() { cancelled = true; break }
            if Date() > deadline { break }
            poll()
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            if cancelled { throw CancellationError() }
            throw CommandExecutionError.timedOut(executable: executable.path, seconds: timeout)
        }
        process.waitUntilExit()
        _ = feeder
        poll()
        try? stdout.synchronize()
        let errorText = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
        return CommandResult(exitCode: process.terminationStatus,
                             standardOutput: outputFile == nil ? String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self) : "",
                             standardError: errorText)
    }
}

/// SQL text helpers.
public enum SQLText {
    /// A string literal: 'it''s'.
    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// An identifier: `my``table`.
    public static func identifier(_ value: String) -> String {
        "`" + value.replacingOccurrences(of: "`", with: "``") + "`"
    }
}
