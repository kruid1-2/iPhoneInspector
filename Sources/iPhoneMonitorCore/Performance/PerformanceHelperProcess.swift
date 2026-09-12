import Darwin
import Foundation

public enum PerformanceHelperProcessEvent: Equatable, Sendable {
    case started(pid: Int32, location: PerformanceHelperLocation)
    case stdoutLine(String)
    case stderrLine(String)
    case stdoutClosed
    case stderrClosed
    case exited(status: Int32)
}

public struct PerformanceSystemErrorCode: Equatable, Sendable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

public struct PerformanceHelperLaunchFailure: Equatable, Sendable {
    public let detail: String
    public let errorCodes: [PerformanceSystemErrorCode]

    public init(error: Error) {
        let rootError = error as NSError
        detail = rootError.localizedDescription

        var codes: [PerformanceSystemErrorCode] = []
        var currentError: NSError? = rootError
        var visited: Set<ObjectIdentifier> = []
        while let current = currentError, codes.count < 8 {
            guard visited.insert(ObjectIdentifier(current)).inserted else { break }
            codes.append(PerformanceSystemErrorCode(domain: current.domain, code: current.code))
            currentError = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        errorCodes = codes
    }

    public var isFileAccessDenied: Bool {
        errorCodes.contains { errorCode in
            if errorCode.domain == NSPOSIXErrorDomain {
                return errorCode.code == Int(POSIXErrorCode.EACCES.rawValue)
                    || errorCode.code == Int(POSIXErrorCode.EPERM.rawValue)
            }
            if errorCode.domain == NSCocoaErrorDomain {
                return errorCode.code == CocoaError.Code.fileReadNoPermission.rawValue
                    || errorCode.code == CocoaError.Code.fileWriteNoPermission.rawValue
            }
            return false
        }
    }
}

public enum PerformanceHelperProcessError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case inputClosed
    case invalidCommand
    case launchFailed(PerformanceHelperLaunchFailure)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Performance Helper 已经在运行"
        case .notRunning: return "Performance Helper 尚未运行"
        case .inputClosed: return "Performance Helper stdin 已关闭"
        case .invalidCommand: return "无法编码 Helper 控制消息"
        case .launchFailed(let failure): return "Performance Helper 启动失败：\(failure.detail)"
        }
    }
}

public enum PerformanceHelperCommand: Sendable {
    case startSession(config: PerformanceMonitoringConfiguration, requestID: String)
    case markLag(note: String, requestID: String)
    case stopSession(requestID: String)
    case shutdown(requestID: String)

    fileprivate var object: [String: Any] {
        switch self {
        case .startSession(let config, let requestID):
            return ["type": "start_session", "config": config.helperPayload, "request_id": requestID]
        case .markLag(let note, let requestID):
            return ["type": "mark_lag", "note": String(note.prefix(256)), "request_id": requestID]
        case .stopSession(let requestID):
            return ["type": "stop_session", "request_id": requestID]
        case .shutdown(let requestID):
            return ["type": "shutdown", "request_id": requestID]
        }
    }
}

public protocol PerformanceHelperProcessControlling: AnyObject, Sendable {
    var events: AsyncStream<PerformanceHelperProcessEvent> { get }
    var processIdentifier: Int32? { get }
    var isRunning: Bool { get }
    func start(at location: PerformanceHelperLocation, arguments: [String]) throws
    func send(_ command: PerformanceHelperCommand) throws
    func terminateOwnedProcess()
}

public final class PerformanceHelperProcess: PerformanceHelperProcessControlling, @unchecked Sendable {
    public let events: AsyncStream<PerformanceHelperProcessEvent>

    private let continuation: AsyncStream<PerformanceHelperProcessEvent>.Continuation
    private let lock = NSLock()
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()

    public init() {
        var captured: AsyncStream<PerformanceHelperProcessEvent>.Continuation!
        events = AsyncStream { continuation in captured = continuation }
        continuation = captured
    }

    deinit {
        terminateOwnedProcess()
        continuation.finish()
    }

    public var processIdentifier: Int32? {
        lock.withLock { process?.processIdentifier }
    }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    public func start(at location: PerformanceHelperLocation, arguments: [String] = []) throws {
        let child = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        lock.lock()
        guard process == nil else {
            lock.unlock()
            throw PerformanceHelperProcessError.alreadyRunning
        }
        process = child
        inputHandle = inputPipe.fileHandleForWriting
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        child.executableURL = location.executableURL
        child.currentDirectoryURL = location.workingDirectoryURL
        child.arguments = arguments
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isError: false, handle: handle)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isError: true, handle: handle)
        }
        child.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            self?.flushPartialLines()
            self?.continuation.yield(.exited(status: process.terminationStatus))
            self?.continuation.finish()
            self?.lock.withLock {
                self?.inputHandle = nil
                self?.process = nil
            }
            AppLogger.performance.info(
                "helper termination handler status=\(process.terminationStatus, privacy: .public)"
            )
        }

        AppLogger.performance.info("helper stdout/stderr readers installed")

        do {
            try child.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lock.withLock {
                process = nil
                inputHandle = nil
            }
            let failure = PerformanceHelperLaunchFailure(error: error)
            let codes = failure.errorCodes
                .map { "\($0.domain):\($0.code)" }
                .joined(separator: ",")
            AppLogger.performance.error(
                "helper Process.run failed file_access_denied=\(failure.isFileAccessDenied, privacy: .public) codes=\(codes, privacy: .public)"
            )
            throw PerformanceHelperProcessError.launchFailed(failure)
        }
        AppLogger.performance.info("helper Process launched pid=\(child.processIdentifier, privacy: .public)")
        continuation.yield(.started(pid: child.processIdentifier, location: location))
    }

    public func send(_ command: PerformanceHelperCommand) throws {
        guard JSONSerialization.isValidJSONObject(command.object),
              var data = try? JSONSerialization.data(withJSONObject: command.object)
        else {
            throw PerformanceHelperProcessError.invalidCommand
        }
        data.append(0x0A)

        let handle: FileHandle? = lock.withLock {
            guard process?.isRunning == true else { return nil }
            return inputHandle
        }
        guard let handle else { throw PerformanceHelperProcessError.notRunning }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw PerformanceHelperProcessError.inputClosed
        }
    }

    public func terminateOwnedProcess() {
        let owned: Process? = lock.withLock { process }
        guard let owned, owned.isRunning else { return }
        let pid = owned.processIdentifier
        AppLogger.performance.info("terminating owned helper pid=\(pid, privacy: .public)")
        owned.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak owned] in
            guard let owned, owned.isRunning, owned.processIdentifier == pid else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    private func consume(_ data: Data, isError: Bool, handle: FileHandle) {
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            flushPartialLines()
            continuation.yield(isError ? .stderrClosed : .stdoutClosed)
            return
        }

        let lines: [String] = lock.withLock {
            if isError {
                errorBuffer.append(data)
                return Self.extractLines(from: &errorBuffer)
            }
            outputBuffer.append(data)
            return Self.extractLines(from: &outputBuffer)
        }
        for line in lines {
            if isError {
                continuation.yield(.stderrLine(AppLogger.redactedDiagnostic(line)))
            } else {
                continuation.yield(.stdoutLine(line))
            }
        }
    }

    private func flushPartialLines() {
        let partial: (String?, String?) = lock.withLock {
            let output = String(data: outputBuffer, encoding: .utf8)
            let error = String(data: errorBuffer, encoding: .utf8)
            outputBuffer.removeAll(keepingCapacity: false)
            errorBuffer.removeAll(keepingCapacity: false)
            return (output?.isEmpty == false ? output : nil, error?.isEmpty == false ? error : nil)
        }
        if let output = partial.0 { continuation.yield(.stdoutLine(output)) }
        if let error = partial.1 { continuation.yield(.stderrLine(AppLogger.redactedDiagnostic(error))) }
    }

    private static func extractLines(from buffer: inout Data) -> [String] {
        var result: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                result.append(line.trimmingCharacters(in: .newlines))
            } else {
                result.append("<invalid-utf8>")
            }
        }
        if buffer.count > 1_048_576 {
            buffer.removeAll(keepingCapacity: true)
            result.append("<line-exceeded-1MiB>")
        }
        return result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
