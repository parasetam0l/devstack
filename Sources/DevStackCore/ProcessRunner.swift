import Darwin
import Foundation

public struct CommandResult: Hashable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum CommandExecutionError: LocalizedError, Sendable {
    case timedOut(executable: String, seconds: TimeInterval)
    case nonZeroExit(executable: String, result: CommandResult)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let seconds):
            "\(executable) timed out after \(seconds) seconds."
        case .nonZeroExit(let executable, let result):
            "\(executable) exited with status \(result.exitCode): \(result.standardError)"
        }
    }
}

public struct ProcessRunner: Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 60
    ) throws -> CommandResult {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("devstack-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let stdoutURL = tempDirectory.appendingPathComponent("stdout")
        let stderrURL = tempDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.interrupt()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { process.terminate() }
            throw CommandExecutionError.timedOut(executable: executable.path, seconds: timeout)
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }

    public func runChecked(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 60
    ) throws -> CommandResult {
        let result = try run(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CommandExecutionError.nonZeroExit(executable: executable.path, result: result)
        }
        return result
    }
}

