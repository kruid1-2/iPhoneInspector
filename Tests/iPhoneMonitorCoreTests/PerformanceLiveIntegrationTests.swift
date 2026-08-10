import Foundation
import XCTest
@testable import iPhoneMonitorCore

final class PerformanceLiveIntegrationTests: XCTestCase {
    func testRealHelperBalancedAndOSLogSessions() async throws {
        guard ProcessInfo.processInfo.environment["IPHONE_INSPECTOR_RUN_LIVE_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set IPHONE_INSPECTOR_RUN_LIVE_PERFORMANCE=1 for the explicit USB device test")
        }

        let balanced = try await runSession(duration: 60, oslog: false, markLagAt: 30)
        XCTAssertTrue(balanced.helperReady)
        XCTAssertGreaterThan(balanced.counts["system_sample", default: 0], 0)
        XCTAssertGreaterThan(balanced.counts["process_batch", default: 0], 0)
        XCTAssertGreaterThan(balanced.counts["battery_sample", default: 0], 0)
        XCTAssertGreaterThan(balanced.counts["energy_sample", default: 0], 0)
        XCTAssertGreaterThan(balanced.counts["network_summary", default: 0], 0)
        XCTAssertGreaterThan(balanced.counts["heartbeat", default: 0], 0)
        XCTAssertEqual(balanced.counts["lag_marker", default: 0], 1)
        XCTAssertEqual(balanced.counts["session_started", default: 0], 1)
        XCTAssertEqual(balanced.counts["session_ended", default: 0], 1)
        XCTAssertEqual(balanced.counts["helper_shutdown", default: 0], 1)
        XCTAssertEqual(balanced.finalState, .idle)
        XCTAssertNil(balanced.finalPID)

        let oslog = try await runSession(duration: 18, oslog: true, markLagAt: nil)
        XCTAssertTrue(oslog.helperReady)
        XCTAssertGreaterThan(oslog.counts["log_summary", default: 0], 0)
        XCTAssertEqual(oslog.counts["session_started", default: 0], 1)
        XCTAssertEqual(oslog.counts["session_ended", default: 0], 1)
        XCTAssertEqual(oslog.finalState, .idle)
        XCTAssertNil(oslog.finalPID)

        let report: [String: Any] = [
            "balanced": balanced.reportObject,
            "oslog": oslog.reportObject,
            "privacy": [
                "raw_jsonl_saved": false,
                "full_logs_saved": false,
                "device_identifiers_in_report": false
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PERFORMANCE_LIVE_SUMMARY \(String(decoding: data, as: UTF8.self))")
    }

    private func runSession(
        duration: TimeInterval,
        oslog: Bool,
        markLagAt: TimeInterval?
    ) async throws -> LiveRunResult {
        let service = PerformanceMonitorService()
        let collector = LiveEventCollector()
        let observer = Task {
            for await event in service.events {
                await collector.consume(event)
            }
        }

        try await service.startMonitoring(config: PerformanceMonitoringConfiguration(enableOSLog: oslog))
        let helperPID = await service.helperPID
        let started = Date()
        var resourceSamples: [HelperResourceSample] = []
        var markerSent = false

        while Date().timeIntervalSince(started) < duration {
            let elapsed = Date().timeIntervalSince(started)
            if !markerSent, let markLagAt, elapsed >= markLagAt {
                try await service.markLag(note: "Swift 实机验收卡顿标记")
                markerSent = true
            }
            if let helperPID, let sample = helperResources(pid: helperPID) {
                resourceSamples.append(sample)
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        try await service.stopMonitoring()
        try await Task.sleep(nanoseconds: 200_000_000)
        observer.cancel()
        let snapshot = await collector.snapshot()
        return LiveRunResult(
            requestedDuration: duration,
            actualDuration: Date().timeIntervalSince(started),
            oslogEnabled: oslog,
            snapshot: snapshot,
            resources: resourceSamples,
            finalState: await service.state,
            finalPID: await service.helperPID
        )
    }

    private func helperResources(pid: Int32) -> HelperResourceSample? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "%cpu=", "-o", "rss="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let parts = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let cpu = Double(parts[0]),
                  let rssKB = Int(parts[1])
            else { return nil }
            return HelperResourceSample(cpuPercent: cpu, rssKB: rssKB)
        } catch {
            return nil
        }
    }
}

private actor LiveEventCollector {
    private var counts: [String: Int] = [:]
    private var systemFields: Set<String> = []
    private var processFields: Set<String> = []
    private var batteryFields: Set<String> = []
    private var energyFields: Set<String> = []
    private var providerErrors: Set<String> = []
    private var helperReady = false
    private var warnings = 0

    func consume(_ event: PerformanceMonitorServiceEvent) {
        switch event {
        case .message(let message):
            counts[message.rawType, default: 0] += 1
            if message.type == .helperReady { helperReady = true }
            switch message.type {
            case .systemSample:
                if let fields = message.payload.object("metrics") {
                    systemFields.formUnion(fields.keys)
                }
            case .processBatch:
                if let first = message.payload.array("processes")?.first?.objectValue {
                    if let fields = first.object("metrics") {
                        processFields.formUnion(fields.keys)
                    }
                }
            case .batterySample:
                if let fields = message.payload.object("metrics") {
                    batteryFields.formUnion(fields.keys)
                }
            case .energySample:
                if let fields = message.payload.object("metrics") {
                    energyFields.formUnion(fields.keys)
                }
            case .providerError:
                providerErrors.insert(message.payload.string("provider") ?? message.source ?? "unknown")
            default:
                break
            }
        case .compatibilityWarning:
            warnings += 1
        default:
            break
        }
    }

    func snapshot() -> LiveEventSnapshot {
        LiveEventSnapshot(
            counts: counts,
            systemFields: systemFields.sorted(),
            processFields: processFields.sorted(),
            batteryFields: batteryFields.sorted(),
            energyFields: energyFields.sorted(),
            providerErrors: providerErrors.sorted(),
            helperReady: helperReady,
            compatibilityWarningCount: warnings
        )
    }
}

private struct LiveEventSnapshot {
    let counts: [String: Int]
    let systemFields: [String]
    let processFields: [String]
    let batteryFields: [String]
    let energyFields: [String]
    let providerErrors: [String]
    let helperReady: Bool
    let compatibilityWarningCount: Int
}

private struct HelperResourceSample {
    let cpuPercent: Double
    let rssKB: Int
}

private struct LiveRunResult {
    let requestedDuration: TimeInterval
    let actualDuration: TimeInterval
    let oslogEnabled: Bool
    let snapshot: LiveEventSnapshot
    let resources: [HelperResourceSample]
    let finalState: PerformanceSessionState
    let finalPID: Int32?

    var helperReady: Bool { snapshot.helperReady }
    var counts: [String: Int] { snapshot.counts }

    var reportObject: [String: Any] {
        let cpu = resources.map(\.cpuPercent)
        let rss = resources.map(\.rssKB)
        return [
            "requested_duration_seconds": requestedDuration,
            "actual_duration_seconds": actualDuration,
            "oslog_enabled": oslogEnabled,
            "helper_ready": snapshot.helperReady,
            "event_counts": snapshot.counts,
            "system_fields": snapshot.systemFields,
            "process_fields": snapshot.processFields,
            "battery_fields": snapshot.batteryFields,
            "energy_fields": snapshot.energyFields,
            "provider_errors": snapshot.providerErrors,
            "compatibility_warning_count": snapshot.compatibilityWarningCount,
            "helper_resource_sample_count": resources.count,
            "helper_average_cpu_percent": cpu.isEmpty ? NSNull() : cpu.reduce(0, +) / Double(cpu.count),
            "helper_peak_cpu_percent": cpu.max().map { $0 as Any } ?? NSNull(),
            "helper_initial_rss_kb": rss.first.map { $0 as Any } ?? NSNull(),
            "helper_peak_rss_kb": rss.max().map { $0 as Any } ?? NSNull(),
            "helper_final_rss_kb": rss.last.map { $0 as Any } ?? NSNull(),
            "final_state": finalState.rawValue,
            "final_pid_present": finalPID != nil
        ]
    }
}
