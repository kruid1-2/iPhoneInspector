import Foundation
import XCTest
@testable import iPhoneMonitorCore

final class PerformanceMonitorServiceTests: XCTestCase {
    func testNormalLifecycleUsesRequiredCommandOrder() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)

        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
        let monitoringState = await service.state
        XCTAssertEqual(monitoringState, .monitoring)
        try await service.markLag(note: "固定脱敏备注")
        try await service.stopMonitoring()

        let finalState = await service.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(fake.commands, [.startSession, .markLag, .stopSession, .shutdown])
        XCTAssertEqual(fake.ownedTerminationCount, 0)
        XCTAssertFalse(fake.isRunning)
    }

    func testIllegalTransitionsAreRejected() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)

        do {
            try await service.markLag(note: "too early")
            XCTFail("markLag should reject idle state")
        } catch let error as PerformanceMonitorServiceError {
            guard case .invalidTransition(from: .idle, action: _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
        do {
            try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
            XCTFail("duplicate start should fail")
        } catch let error as PerformanceMonitorServiceError {
            guard case .invalidTransition(from: .monitoring, action: _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        try await service.stopMonitoring()
    }

    func testSequenceGapProducesWarningButKeepsMessage() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)
        let warning = expectation(description: "sequence gap warning")
        let message = expectation(description: "heartbeat retained")
        let observer = Task {
            for await event in service.events {
                if case .compatibilityWarning(let text) = event, text.contains("sequence 出现间断") {
                    warning.fulfill()
                }
                if case .message(let value) = event, value.type == .heartbeat {
                    message.fulfill()
                }
            }
        }

        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
        fake.emit(type: "heartbeat", sequence: 8, sessionID: fake.sessionID, payload: [
            "provider_states": ["sysmon": "running"],
            "output_queue": ["capacity": 256, "dropped_count": 0]
        ])
        await fulfillment(of: [warning, message], timeout: 2)
        observer.cancel()
        try await service.stopMonitoring()
    }

    func testMismatchedSessionSampleIsIgnored() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)
        let warning = expectation(description: "session mismatch warning")
        let observer = Task {
            for await event in service.events {
                if case .compatibilityWarning(let text) = event, text.contains("session_id 不一致") {
                    warning.fulfill()
                    return
                }
            }
        }

        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
        fake.emit(type: "system_sample", sessionID: "different-session", payload: ["metrics": [:]])
        await fulfillment(of: [warning], timeout: 2)
        observer.cancel()
        try await service.stopMonitoring()
    }

    func testProtocolMismatchFailsStartupWithoutCrashing() async {
        let fake = FakePerformanceHelperProcess(helperProtocolVersion: 3)
        let service = makeService(fake)

        do {
            try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
            XCTFail("protocol v3 should be rejected")
        } catch {
            let state = await service.state
            XCTAssertEqual(state, .protocolMismatch)
        }
        await service.shutdown()
    }

    func testUnexpectedHelperExitBecomesConnectionLost() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)
        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())

        fake.unexpectedExit(status: 9)
        try await waitUntil { await service.state == .connectionLost }
        let helperPID = await service.helperPID
        XCTAssertNil(helperPID)
    }

    func testInvalidStdoutAndStderrRemainSeparateStreams() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)
        let invalid = expectation(description: "invalid stdout warning")
        let stderr = expectation(description: "stderr diagnostic")
        let observer = Task {
            for await event in service.events {
                switch event {
                case .compatibilityWarning(let text) where text.contains("非 JSON"):
                    invalid.fulfill()
                case .stderr(let text) where text.contains("sanitized diagnostic"):
                    stderr.fulfill()
                default:
                    break
                }
            }
        }

        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
        fake.emitStdout("progress is not JSON")
        fake.emitStderr("sanitized diagnostic")
        await fulfillment(of: [invalid, stderr], timeout: 2)
        observer.cancel()
        let state = await service.state
        XCTAssertEqual(state, .monitoring)
        try await service.stopMonitoring()
    }

    func testClosedStdinCleansOnlyOwnedProcess() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)
        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
        fake.failMarkLag = true

        do {
            try await service.markLag(note: "write failure fixture")
            XCTFail("markLag should report closed stdin")
        } catch {
            let state = await service.state
            XCTAssertEqual(state, .connectionLost)
            XCTAssertEqual(fake.ownedTerminationCount, 1)
            XCTAssertFalse(fake.isRunning)
        }
    }

    func testUnexpectedStdoutEOFTriggersOwnedCleanup() async throws {
        let fake = FakePerformanceHelperProcess()
        let service = makeService(fake)
        try await service.startMonitoring(config: PerformanceMonitoringConfiguration())

        fake.emitStdoutClosed()
        try await waitUntil { await service.state == .connectionLost }
        XCTAssertEqual(fake.ownedTerminationCount, 1)
    }

    func testHelperReadyTimeoutCleansOwnedProcess() async {
        let fake = FakePerformanceHelperProcess(emitHelperReady: false)
        let service = PerformanceMonitorService(
            locator: FixtureHelperLocator(),
            processFactory: { fake },
            helperReadyTimeout: 0.05
        )

        do {
            try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
            XCTFail("startup should time out")
        } catch {
            let state = await service.state
            XCTAssertEqual(state, .helperFailed)
            XCTAssertEqual(fake.ownedTerminationCount, 1)
            XCTAssertFalse(fake.isRunning)
        }
    }

    func testStartSessionCommandErrorCleansOwnedProcess() async {
        let fake = FakePerformanceHelperProcess()
        fake.failStartSession = true
        let service = makeService(fake)

        do {
            try await service.startMonitoring(config: PerformanceMonitoringConfiguration())
            XCTFail("command_error should fail startup")
        } catch {
            let state = await service.state
            XCTAssertEqual(state, .helperFailed)
            XCTAssertEqual(fake.ownedTerminationCount, 1)
            XCTAssertFalse(fake.isRunning)
            let helperPID = await service.helperPID
            XCTAssertNil(helperPID)
        }
    }

    private func makeService(_ fake: FakePerformanceHelperProcess) -> PerformanceMonitorService {
        PerformanceMonitorService(
            locator: FixtureHelperLocator(),
            processFactory: { fake }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await predicate()) {
            if Date() >= deadline {
                throw NSError(domain: "PerformanceMonitorServiceTests", code: 1)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct FixtureHelperLocator: PerformanceHelperLocating {
    func locate() throws -> PerformanceHelperLocation {
        PerformanceHelperLocation(
            executableURL: URL(fileURLWithPath: "/tmp/fixture-helper"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            source: .developmentOverride
        )
    }
}

private final class FakePerformanceHelperProcess: PerformanceHelperProcessControlling, @unchecked Sendable {
    enum RecordedCommand: Equatable {
        case startSession
        case markLag
        case stopSession
        case shutdown
    }

    let events: AsyncStream<PerformanceHelperProcessEvent>
    let sessionID = "fixture-session"
    var failMarkLag = false
    var failStartSession = false

    private let continuation: AsyncStream<PerformanceHelperProcessEvent>.Continuation
    private let lock = NSLock()
    private var running = false
    private var nextSequence = 0
    private var recordedCommands: [RecordedCommand] = []
    private var terminationCount = 0
    private let helperProtocolVersion: Int
    private let emitHelperReady: Bool

    init(helperProtocolVersion: Int = 2, emitHelperReady: Bool = true) {
        self.helperProtocolVersion = helperProtocolVersion
        self.emitHelperReady = emitHelperReady
        var captured: AsyncStream<PerformanceHelperProcessEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    var processIdentifier: Int32? { isRunning ? 7_654 : nil }
    var isRunning: Bool { locked { running } }
    var commands: [RecordedCommand] { locked { recordedCommands } }
    var ownedTerminationCount: Int { locked { terminationCount } }

    func start(at location: PerformanceHelperLocation, arguments: [String]) throws {
        locked { running = true }
        continuation.yield(.started(pid: 7_654, location: location))
        guard emitHelperReady else { return }
        emit(type: "helper_ready", sessionID: nil, payload: [
            "helper_version": "fixture",
            "read_only": true,
            "commands": ["start_session", "mark_lag", "stop_session", "shutdown"],
            "event_types": ["helper_ready", "session_started", "lag_marker", "session_ended", "helper_shutdown"]
        ], protocolVersion: helperProtocolVersion)
    }

    func send(_ command: PerformanceHelperCommand) throws {
        guard isRunning else { throw PerformanceHelperProcessError.notRunning }
        switch command {
        case .startSession:
            append(.startSession)
            if failStartSession {
                emit(
                    type: "command_error",
                    sessionID: nil,
                    payload: ["error": "no matching trusted USB device was found"]
                )
            } else {
                emit(type: "session_started", sessionID: sessionID, payload: ["state": "running"])
            }
        case .markLag:
            if failMarkLag { throw PerformanceHelperProcessError.inputClosed }
            append(.markLag)
            emit(type: "lag_marker", sessionID: sessionID, payload: ["note": "fixture", "elapsed_ms": 100])
        case .stopSession:
            append(.stopSession)
            emit(type: "session_ended", sessionID: sessionID, payload: ["cleanup_complete": true])
        case .shutdown:
            append(.shutdown)
            emit(type: "helper_shutdown", sessionID: nil, payload: ["cleanup_complete": true])
            locked { running = false }
            continuation.yield(.exited(status: 0))
            continuation.finish()
        }
    }

    func terminateOwnedProcess() {
        let shouldExit: Bool = locked {
            terminationCount += 1
            let wasRunning = running
            running = false
            return wasRunning
        }
        if shouldExit {
            continuation.yield(.exited(status: 15))
            continuation.finish()
        }
    }

    func unexpectedExit(status: Int32) {
        locked { running = false }
        continuation.yield(.exited(status: status))
        continuation.finish()
    }

    func emitStdout(_ line: String) { continuation.yield(.stdoutLine(line)) }
    func emitStderr(_ line: String) { continuation.yield(.stderrLine(line)) }
    func emitStdoutClosed() { continuation.yield(.stdoutClosed) }

    func emit(
        type: String,
        sequence: Int? = nil,
        sessionID: String?,
        payload: [String: Any],
        protocolVersion: Int = 2
    ) {
        let actualSequence: Int = locked {
            if let sequence {
                nextSequence = max(nextSequence, sequence)
                return sequence
            }
            nextSequence += 1
            return nextSequence
        }
        let object: [String: Any] = [
            "protocol_version": protocolVersion,
            "type": type,
            "timestamp_utc": "2026-08-02T10:00:00.123Z",
            "monotonic_ns": 5_000_000 + actualSequence,
            "sequence": actualSequence,
            "session_id": sessionID ?? NSNull(),
            "source": "fixture",
            "payload": payload
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        continuation.yield(.stdoutLine(String(decoding: data, as: UTF8.self)))
    }

    private func append(_ command: RecordedCommand) {
        locked { recordedCommands.append(command) }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
