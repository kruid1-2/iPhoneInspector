import Foundation

public enum PerformanceMonitorServiceError: LocalizedError, Equatable, Sendable {
    case invalidTransition(from: PerformanceSessionState, action: String)
    case timedOut(String)
    case helperLocation(PerformanceHelperLocatorError)
    case helperProcess(PerformanceHelperProcessError)
    case helperError(String)
    case processExited(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let state, let action):
            return "当前状态 \(state.label) 不允许执行 \(action)"
        case .timedOut(let action):
            return "等待 \(action) 超时"
        case .helperLocation(let error):
            return error.localizedDescription
        case .helperProcess(let error):
            return error.localizedDescription
        case .helperError(let detail):
            return detail
        case .processExited(let status):
            return "Performance Helper 意外退出（状态 \(status)）"
        }
    }
}

public enum PerformanceMonitorServiceEvent: Equatable, Sendable {
    case stateChanged(PerformanceSessionState)
    case helperLocated(PerformanceHelperLocation.Source)
    case helperStarted(pid: Int32)
    case message(PerformanceMessage)
    case stderr(String)
    case compatibilityWarning(String)
    case processExited(status: Int32, expected: Bool)
}

public actor PerformanceMonitorService {
    public nonisolated let events: AsyncStream<PerformanceMonitorServiceEvent>

    public private(set) var state: PerformanceSessionState = .idle
    public private(set) var activeSessionID: String?
    public private(set) var helperPID: Int32?
    public private(set) var lastHelperLocation: PerformanceHelperLocation?

    private let continuation: AsyncStream<PerformanceMonitorServiceEvent>.Continuation
    private let locator: any PerformanceHelperLocating
    private let processFactory: @Sendable () -> any PerformanceHelperProcessControlling
    private let decoder: PerformanceJSONLDecoder
    private let processArguments: [String]
    private let helperReadyTimeout: TimeInterval

    private var helperProcess: (any PerformanceHelperProcessControlling)?
    private var processTask: Task<Void, Never>?
    private var previousSequence: UInt64?
    private var previousMonotonicNS: UInt64?
    private var sessionEndedSeen = false
    private var helperShutdownSeen = false
    private var processExited = false
    private var expectedProcessExit = false
    private var latestError: PerformanceMonitorServiceError?
    private var helperLaunchStartedNS: UInt64?
    private var sessionStartCommandNS: UInt64?

    public init(
        locator: any PerformanceHelperLocating = PerformanceHelperLocator(),
        processFactory: @escaping @Sendable () -> any PerformanceHelperProcessControlling = {
            PerformanceHelperProcess()
        },
        decoder: PerformanceJSONLDecoder = PerformanceJSONLDecoder(),
        processArguments: [String] = [],
        helperReadyTimeout: TimeInterval = 30
    ) {
        var captured: AsyncStream<PerformanceMonitorServiceEvent>.Continuation!
        events = AsyncStream { value in captured = value }
        continuation = captured
        self.locator = locator
        self.processFactory = processFactory
        self.decoder = decoder
        self.processArguments = processArguments
        self.helperReadyTimeout = helperReadyTimeout
    }

    public var requiresShutdown: Bool {
        helperProcess != nil || state != .idle
    }

    public func startMonitoring(config: PerformanceMonitoringConfiguration) async throws {
        AppLogger.performance.info("startMonitoring requested state=\(self.state.rawValue, privacy: .public)")
        switch state {
        case .idle, .helperFailed, .connectionLost:
            try await startHelper()
        case .helperReady:
            break
        default:
            throw PerformanceMonitorServiceError.invalidTransition(from: state, action: "开始监控")
        }

        guard state == .helperReady, let helperProcess else {
            throw latestError ?? PerformanceMonitorServiceError.helperError("Helper 未进入就绪状态")
        }
        sessionEndedSeen = false
        activeSessionID = nil
        setState(.startingSession)
        do {
            try helperProcess.send(
                .startSession(config: config, requestID: "swift-start-\(UUID().uuidString)")
            )
            sessionStartCommandNS = DispatchTime.now().uptimeNanoseconds
            AppLogger.performance.info("start_session sent")
        } catch let error as PerformanceHelperProcessError {
            await abnormalCleanup(reason: "start_session 写入失败：\(error.localizedDescription)")
            throw PerformanceMonitorServiceError.helperProcess(error)
        } catch {
            await abnormalCleanup(reason: "start_session 写入失败：\(error.localizedDescription)")
            throw PerformanceMonitorServiceError.helperError(error.localizedDescription)
        }
        do {
            try await waitFor("session_started", timeout: 35) { self.state == .monitoring }
        } catch {
            await abnormalCleanup(
                reason: "start_session 未建立会话：\(error.localizedDescription)",
                finalState: .helperFailed
            )
            throw error
        }
    }

    public func markLag(note: String) async throws {
        guard state == .monitoring, let helperProcess, helperProcess.isRunning else {
            throw PerformanceMonitorServiceError.invalidTransition(from: state, action: "标记卡顿")
        }
        do {
            try helperProcess.send(
                .markLag(note: note, requestID: "swift-mark-\(UUID().uuidString)")
            )
        } catch {
            await abnormalCleanup(
                reason: "mark_lag 写入失败：\(error.localizedDescription)",
                finalState: .connectionLost
            )
            throw PerformanceMonitorServiceError.helperError(error.localizedDescription)
        }
    }

    public func stopMonitoring() async throws {
        guard state == .monitoring, let helperProcess else {
            throw PerformanceMonitorServiceError.invalidTransition(from: state, action: "停止监控")
        }
        setState(.stoppingSession)
        sessionEndedSeen = false
        do {
            try helperProcess.send(.stopSession(requestID: "swift-stop-\(UUID().uuidString)"))
        } catch {
            await abnormalCleanup(reason: error.localizedDescription, finalState: .connectionLost)
            throw PerformanceMonitorServiceError.helperError(error.localizedDescription)
        }

        do {
            try await waitFor("session_ended", timeout: 20) { self.sessionEndedSeen }
            try await shutdownReadyHelper()
        } catch {
            await abnormalCleanup(reason: error.localizedDescription, finalState: .connectionLost)
            throw error
        }
    }

    public func shutdown() async {
        switch state {
        case .idle:
            return
        case .monitoring:
            do {
                try await stopMonitoring()
            } catch {
                await abnormalCleanup(reason: error.localizedDescription)
            }
        case .helperReady:
            do {
                try await shutdownReadyHelper()
            } catch {
                await abnormalCleanup(reason: error.localizedDescription)
            }
        default:
            await abnormalCleanup(reason: "应用生命周期要求关闭尚未完成启动的 Helper")
        }
    }

    private func startHelper() async throws {
        helperLaunchStartedNS = DispatchTime.now().uptimeNanoseconds
        lastHelperLocation = nil
        AppLogger.performance.info("helper launch requested")
        setState(.locatingHelper)
        let location: PerformanceHelperLocation
        do {
            location = try locator.locate()
        } catch let error as PerformanceHelperLocatorError {
            latestError = .helperLocation(error)
            setState(.helperFailed)
            throw latestError!
        } catch {
            latestError = .helperError(error.localizedDescription)
            setState(.helperFailed)
            throw latestError!
        }
        lastHelperLocation = location
        continuation.yield(.helperLocated(location.source))
        AppLogger.performance.info("helper located source=\(location.source.rawValue, privacy: .public)")

        setState(.startingHelper)
        let process = processFactory()
        helperProcess = process
        previousSequence = nil
        previousMonotonicNS = nil
        processExited = false
        expectedProcessExit = false
        helperShutdownSeen = false
        latestError = nil

        let stream = process.events
        processTask = Task { [weak self] in
            for await event in stream {
                await self?.handleProcessEvent(event)
            }
        }
        do {
            try process.start(at: location, arguments: processArguments)
            AppLogger.performance.info("helper Process.run returned successfully")
        } catch let error as PerformanceHelperProcessError {
            helperProcess = nil
            processTask?.cancel()
            processTask = nil
            latestError = .helperProcess(error)
            setState(.helperFailed)
            throw latestError!
        } catch {
            helperProcess = nil
            processTask?.cancel()
            processTask = nil
            latestError = .helperError(error.localizedDescription)
            setState(.helperFailed)
            throw latestError!
        }
        do {
            try await waitFor("helper_ready", timeout: helperReadyTimeout) { self.state == .helperReady }
        } catch {
            let cleanupState: PerformanceSessionState = state == .protocolMismatch
                ? .protocolMismatch
                : .helperFailed
            await abnormalCleanup(reason: error.localizedDescription, finalState: cleanupState)
            throw error
        }
    }

    private func shutdownReadyHelper() async throws {
        guard let helperProcess, helperProcess.isRunning else {
            finishCleanly()
            return
        }
        setState(.shuttingDown)
        helperShutdownSeen = false
        processExited = false
        expectedProcessExit = true
        try helperProcess.send(.shutdown(requestID: "swift-shutdown-\(UUID().uuidString)"))
        try await waitFor("helper_shutdown", timeout: 10) { self.helperShutdownSeen }
        try await waitFor("Helper 进程退出", timeout: 10) { self.processExited }
        finishCleanly()
    }

    private func handleProcessEvent(_ event: PerformanceHelperProcessEvent) async {
        switch event {
        case .started(let pid, _):
            helperPID = pid
            continuation.yield(.helperStarted(pid: pid))
            AppLogger.performance.info("helper process launched pid=\(pid, privacy: .public)")
        case .stdoutLine(let line):
            handleDecoded(decoder.decode(line: line))
        case .stderrLine(let line):
            continuation.yield(.stderr(line))
            let diagnostic = AppLogger.redactedDiagnostic(line)
            AppLogger.performance.info("helper stderr: \(diagnostic, privacy: .public)")
        case .stdoutClosed:
            guard !expectedProcessExit, helperProcess?.isRunning == true else { return }
            latestError = .helperError("Performance Helper stdout 已关闭")
            setState(activeSessionID == nil ? .helperFailed : .connectionLost)
            await abnormalCleanup(reason: "stdout EOF", finalState: .connectionLost)
        case .stderrClosed:
            continuation.yield(.stderr("Performance Helper stderr 已关闭"))
            AppLogger.performance.info("helper stderr closed")
        case .exited(let status):
            helperPID = nil
            processExited = true
            continuation.yield(.processExited(status: status, expected: expectedProcessExit))
            AppLogger.performance.info(
                "helper exited pid_cleared=true status=\(status, privacy: .public) expected=\(self.expectedProcessExit, privacy: .public)"
            )
            if !expectedProcessExit {
                latestError = .processExited(status)
                setState(activeSessionID == nil ? .helperFailed : .connectionLost)
                helperProcess = nil
                activeSessionID = nil
            }
        }
    }

    private func handleDecoded(_ result: PerformanceDecodingResult) {
        switch result {
        case .protocolMismatch(let actual):
            continuation.yield(
                .compatibilityWarning("只支持协议 v2，Helper 返回 \(actual.map(String.init) ?? "缺失版本")")
            )
            latestError = .helperError("Helper 协议版本不兼容")
            setState(.protocolMismatch)
        case .invalidLine(let reason):
            continuation.yield(.compatibilityWarning(reason))
        case .message(let message):
            guard validateOrdering(message) else { return }
            for warning in message.compatibilityWarnings {
                continuation.yield(.compatibilityWarning("\(message.rawType)：\(warning)"))
            }
            if shouldRejectForSessionMismatch(message) { return }
            continuation.yield(.message(message))

            switch message.type {
            case .helperReady:
                let elapsed = elapsedMilliseconds(since: helperLaunchStartedNS)
                AppLogger.performance.info("helper_ready received elapsed_ms=\(elapsed, privacy: .public)")
                setState(.helperReady)
            case .sessionStarted:
                activeSessionID = message.sessionID
                let elapsed = elapsedMilliseconds(since: sessionStartCommandNS)
                AppLogger.performance.info("session_started received elapsed_ms=\(elapsed, privacy: .public)")
                setState(.monitoring)
            case .sessionEnded:
                sessionEndedSeen = true
                activeSessionID = nil
                if state == .stoppingSession { setState(.helperReady) }
            case .helperShutdown:
                helperShutdownSeen = true
                AppLogger.performance.info("helper_shutdown received")
            case .commandError:
                let detail = message.payload.string("error") ?? "Helper 返回 command_error"
                let diagnostic = AppLogger.redactedDiagnostic(detail)
                AppLogger.performance.error(
                    "command_error received state=\(self.state.rawValue, privacy: .public) detail=\(diagnostic, privacy: .public)"
                )
                latestError = .helperError(detail)
                if state == .startingSession || state == .startingHelper {
                    setState(.helperFailed)
                }
            default:
                break
            }
        }
    }

    private func validateOrdering(_ message: PerformanceMessage) -> Bool {
        guard let sequence = message.sequence else {
            continuation.yield(.compatibilityWarning("\(message.rawType) 缺少 sequence，消息已保留"))
            return true
        }
        if let previousSequence {
            if sequence <= previousSequence {
                continuation.yield(.compatibilityWarning("sequence 未递增，已忽略重复或乱序消息"))
                return false
            }
            if sequence > previousSequence + 1 {
                continuation.yield(.compatibilityWarning("sequence 出现间断：\(previousSequence) → \(sequence)"))
            }
        }
        previousSequence = sequence

        if let monotonic = message.monotonicNS {
            if let previousMonotonicNS, monotonic <= previousMonotonicNS {
                continuation.yield(.compatibilityWarning("monotonic_ns 未严格递增"))
            }
            previousMonotonicNS = monotonic
        }
        return true
    }

    private func shouldRejectForSessionMismatch(_ message: PerformanceMessage) -> Bool {
        guard let activeSessionID,
              let messageSession = message.sessionID,
              messageSession != activeSessionID
        else { return false }
        switch message.type {
        case .systemSample, .processBatch, .batterySample, .energySample, .logEvent,
             .logSummary, .networkSummary, .heartbeat, .streamGap, .providerError,
             .userMarker, .sessionEnded:
            continuation.yield(.compatibilityWarning("忽略 session_id 不一致的 \(message.rawType)"))
            return true
        default:
            return false
        }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval,
        predicate: () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while !predicate() {
            if let latestError { throw latestError }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                AppLogger.performance.error(
                    "startup wait timed out step=\(description, privacy: .public) state=\(self.state.rawValue, privacy: .public)"
                )
                throw PerformanceMonitorServiceError.timedOut(description)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func abnormalCleanup(
        reason: String,
        finalState: PerformanceSessionState = .helperFailed
    ) async {
        let diagnostic = AppLogger.redactedDiagnostic(reason)
        AppLogger.performance.error(
            "helper cleanup begin state=\(self.state.rawValue, privacy: .public) pid=\(self.helperPID ?? -1, privacy: .public) reason=\(diagnostic, privacy: .public)"
        )
        continuation.yield(.compatibilityWarning("异常清理当前 Helper：\(reason)"))
        expectedProcessExit = true
        helperProcess?.terminateOwnedProcess()
        let deadline = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        while helperProcess?.isRunning == true,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        helperProcess = nil
        helperPID = nil
        activeSessionID = nil
        processTask?.cancel()
        processTask = nil
        setState(finalState)
        AppLogger.performance.info("helper cleanup end final_state=\(finalState.rawValue, privacy: .public)")
    }

    private func finishCleanly() {
        helperProcess = nil
        helperPID = nil
        activeSessionID = nil
        processTask?.cancel()
        processTask = nil
        latestError = nil
        expectedProcessExit = false
        setState(.idle)
        AppLogger.performance.info("helper lifecycle finished cleanly")
    }

    private func setState(_ newState: PerformanceSessionState) {
        guard state != newState else { return }
        let previous = state
        state = newState
        AppLogger.performance.info(
            "performance state transition from=\(previous.rawValue, privacy: .public) to=\(newState.rawValue, privacy: .public)"
        )
        continuation.yield(.stateChanged(newState))
    }

    private func elapsedMilliseconds(since startedNS: UInt64?) -> UInt64 {
        guard let startedNS else { return 0 }
        return (DispatchTime.now().uptimeNanoseconds - startedNS) / 1_000_000
    }
}
