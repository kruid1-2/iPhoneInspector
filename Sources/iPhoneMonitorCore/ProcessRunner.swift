import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let output: String
    public let errorOutput: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let cancelled: Bool
    public let duration: TimeInterval
    public let outputTruncated: Bool

    public init(
        output: String,
        errorOutput: String,
        exitCode: Int32,
        timedOut: Bool,
        cancelled: Bool = false,
        duration: TimeInterval = 0,
        outputTruncated: Bool = false
    ) {
        self.output = output
        self.errorOutput = errorOutput
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.duration = duration
        self.outputTruncated = outputTruncated
    }

    public var succeeded: Bool {
        exitCode == 0 && !timedOut && !cancelled
    }

    public var conciseError: String {
        if cancelled { return "命令已取消" }
        if timedOut { return "命令执行超时" }
        let trimmed = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "命令退出状态：\(exitCode)" : String(trimmed.prefix(800))
    }
}

public typealias ProcessResult = CommandResult

public final class CommandRunner: @unchecked Sendable {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 15,
        maximumOutputBytes: Int = 16 * 1_024 * 1_024
    ) async -> CommandResult {
        let execution = CommandExecution(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )

        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                execution.run()
            }.value
        } onCancel: {
            execution.cancel()
        }

        AppLogger.command.info(
            "Command \(URL(fileURLWithPath: executable).lastPathComponent, privacy: .public) finished code=\(result.exitCode) timeout=\(result.timedOut) cancelled=\(result.cancelled) duration=\(result.duration, format: .fixed(precision: 2))s"
        )
        return result
    }
}

public enum ProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) async -> ProcessResult {
        await CommandRunner().run(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }
}

private final class CommandExecution: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    init(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let runningProcess = process
        lock.unlock()

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    func run() -> CommandResult {
        let startedAt = Date()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let termination = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in termination.signal() }

        lock.lock()
        self.process = process
        let cancelledBeforeStart = cancellationRequested
        lock.unlock()

        guard !cancelledBeforeStart else {
            return CommandResult(
                output: "",
                errorOutput: "",
                exitCode: -1,
                timedOut: false,
                cancelled: true,
                duration: Date().timeIntervalSince(startedAt)
            )
        }

        do {
            try process.run()
        } catch {
            return CommandResult(
                output: "",
                errorOutput: error.localizedDescription,
                exitCode: -1,
                timedOut: false,
                cancelled: false,
                duration: Date().timeIntervalSince(startedAt)
            )
        }

        let ioGroup = DispatchGroup()
        let dataLock = NSLock()
        var outputData = Data()
        var errorData = Data()
        var outputWasTruncated = false
        var errorWasTruncated = false

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.readLimited(
                outputPipe.fileHandleForReading,
                maximumBytes: self.maximumOutputBytes
            )
            dataLock.lock()
            outputData = result.data
            outputWasTruncated = result.truncated
            dataLock.unlock()
            ioGroup.leave()
        }

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let result = Self.readLimited(
                errorPipe.fileHandleForReading,
                maximumBytes: self.maximumOutputBytes
            )
            dataLock.lock()
            errorData = result.data
            errorWasTruncated = result.truncated
            dataLock.unlock()
            ioGroup.leave()
        }

        let didTimeOut = termination.wait(timeout: .now() + timeout) == .timedOut
        if didTimeOut, process.isRunning {
            process.terminate()
            _ = termination.wait(timeout: .now() + 2)
        }

        if process.isRunning {
            process.interrupt()
            _ = termination.wait(timeout: .now() + 1)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + 1)
        }

        ioGroup.wait()
        dataLock.lock()
        let finalOutput = outputData
        let finalError = errorData
        let wasTruncated = outputWasTruncated || errorWasTruncated
        dataLock.unlock()

        lock.lock()
        let wasCancelled = cancellationRequested
        self.process = nil
        lock.unlock()

        return CommandResult(
            output: String(data: finalOutput, encoding: .utf8) ?? "",
            errorOutput: String(data: finalError, encoding: .utf8) ?? "",
            exitCode: process.isRunning ? -1 : process.terminationStatus,
            timedOut: didTimeOut,
            cancelled: wasCancelled,
            duration: Date().timeIntervalSince(startedAt),
            outputTruncated: wasTruncated
        )
    }

    private static func readLimited(
        _ handle: FileHandle,
        maximumBytes: Int
    ) -> (data: Data, truncated: Bool) {
        var stored = Data()
        var truncated = false
        while true {
            guard
                let chunk = try? handle.read(upToCount: 64 * 1_024),
                !chunk.isEmpty
            else { break }
            if stored.count < maximumBytes {
                let remaining = maximumBytes - stored.count
                stored.append(chunk.prefix(remaining))
                if chunk.count > remaining {
                    truncated = true
                }
            } else {
                truncated = true
            }
        }
        return (stored, truncated)
    }
}
