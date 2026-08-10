import Foundation
import XCTest
@testable import iPhoneMonitorCore

final class PerformanceInsightsTests: XCTestCase {
    private let session = "insight-session"
    private let start: UInt64 = 5_000_000_000

    func testRecentTrendUsesSeveralSamplesInsteadOfOnePoint() {
        XCTAssertEqual(PerformanceInsightAnalyzer.trend(points: points([10, 10, 12, 16]), relativeThreshold: 0.05), .increasing)
        XCTAssertEqual(PerformanceInsightAnalyzer.trend(points: points([10, 10.1, 10, 10.1]), relativeThreshold: 0.05), .stable)
        XCTAssertEqual(PerformanceInsightAnalyzer.trend(points: points([16, 14, 11, 10]), relativeThreshold: 0.05), .decreasing)
    }

    func testCPUIsComparedRelativelyAndRemainsRaw() throws {
        let summary = try richSummary()
        XCTAssertEqual(summary.cpuObservation, .high)
        let frame = PerformanceTimelineBuilder.build(input: try richInput().0, range: .all)
        XCTAssertEqual(frame.series(kind: .systemCPU).first?.unitLabel, "负载原始值")
        XCTAssertFalse(frame.series(kind: .systemCPU).first?.unitLabel.contains("%") == true)
    }

    func testTopProcessesExcludeObserverOverhead() throws {
        let summary = try richSummary()
        XCTAssertFalse(summary.busiestProcesses.contains { $0.name == "DTServiceHub" })
        XCTAssertEqual(summary.busiestProcesses.first?.name, "WeChat")
        XCTAssertLessThanOrEqual(summary.busiestProcesses.count, 3)
    }

    func testPhysicalFootprintGrowthUsesConfirmedMiB() throws {
        let summary = try richSummary()
        XCTAssertEqual(summary.appMemory.fastestGrowthProcessName, "WeChat")
        XCTAssertEqual(summary.appMemory.growthMiB ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(summary.appMemory.largestMiB ?? 0, 180, accuracy: 0.001)
    }

    func testPIDReuseDoesNotJoinDifferentProcessNames() throws {
        let marker = try marker(offset: 60)
        let batches = [
            try processBatch(offset: 20, values: [(42, "OldProcess", 2, 500, false)]),
            try processBatch(offset: 60, values: [(42, "NewProcess", 3, 10, false)])
        ]
        let input = makeInput(processes: batches, markers: [marker])
        let summary = PerformanceInsightAnalyzer.lagSummary(
            input: input, marker: marker, providerErrorCount: 0, droppedCount: 0
        )
        XCTAssertEqual(summary.appMemory.largestProcessName, "NewProcess")
        XCTAssertNil(summary.appMemory.growthMiB)
    }

    func testBatteryTemperatureTrendKeepsRawValues() throws {
        let summary = try richSummary()
        XCTAssertEqual(summary.batteryTemperatureTrend, .increasing)
        XCTAssertEqual(summary.batteryTemperatureStartRaw, 3_975)
        XCTAssertEqual(summary.batteryTemperatureEndRaw, 4_030)
    }

    func testEnergyUsesRelativeBeforeAndAfterComparison() throws {
        XCTAssertEqual(try richSummary().energyObservation, .increased)
    }

    func testStreamGapAndErrorsLowerConfidence() throws {
        let (input, marker) = try richInput(includeGap: true)
        let summary = PerformanceInsightAnalyzer.lagSummary(
            input: input, marker: marker, providerErrorCount: 1, droppedCount: 2
        )
        XCTAssertEqual(summary.confidence, .incomplete)
        XCTAssertEqual(summary.streamGapCount, 1)
        XCTAssertEqual(summary.streamGapSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(summary.providerErrorCount, 1)
        XCTAssertEqual(summary.droppedCount, 2)
    }

    func testInsufficientDataDoesNotFabricateResults() throws {
        let marker = try marker(offset: 4)
        let input = makeInput(system: [try system(offset: 3, cpu: 10)], markers: [marker])
        let summary = PerformanceInsightAnalyzer.lagSummary(
            input: input, marker: marker, providerErrorCount: 0, droppedCount: 0
        )
        XCTAssertEqual(summary.cpuObservation, .insufficientData)
        XCTAssertTrue(summary.busiestProcesses.isEmpty)
        XCTAssertNil(summary.appMemory.largestMiB)
        XCTAssertEqual(summary.batteryTemperatureTrend, .insufficientData)
        XCTAssertEqual(summary.energyObservation, .insufficientData)
    }

    func testVMPageCountsAreNotConvertedToMemoryUnits() throws {
        let frame = PerformanceTimelineBuilder.build(input: try richInput().0, range: .all)
        let vm = frame.series(kind: .systemVM)
        XCTAssertTrue(vm.allSatisfy { $0.unitLabel == "内存页数（原始计数）" })
        XCTAssertTrue(vm.allSatisfy { !$0.unitLabel.contains("GB") && !$0.unitLabel.contains("MiB") })
    }

    func testShortPostMarkerWindowAnalyzesSafely() throws {
        let marker = try marker(offset: 60)
        let input = makeInput(
            system: (1...60).map { try! system(offset: $0, cpu: 10) },
            markers: [marker]
        )
        let summary = PerformanceInsightAnalyzer.lagSummary(
            input: input, marker: marker, providerErrorCount: 0, droppedCount: 0
        )
        XCTAssertEqual(summary.postWindowSeconds, 0)
        XCTAssertEqual(summary.energyObservation, .insufficientData)
    }

    private func richSummary() throws -> PerformanceLagSummary {
        let (input, marker) = try richInput()
        return PerformanceInsightAnalyzer.lagSummary(
            input: input, marker: marker, providerErrorCount: 0, droppedCount: 0
        )
    }

    private func richInput(includeGap: Bool = false) throws -> (PerformanceTimelineInput, PerformanceUserMarker) {
        let marker = try marker(offset: 60)
        let systemSamples = try (1...70).map { second in
            try system(
                offset: second,
                cpu: second >= 55 ? 30 : 10,
                free: Double(10_000 - second * 20),
                compressed: Double(1_000 + second * 10)
            )
        }
        let processes = [
            try processBatch(offset: 30, values: [
                (100, "WeChat", 5, 100, false),
                (200, "SpringBoard", 8, 80, false),
                (999, "DTServiceHub", 900, 20, true)
            ]),
            try processBatch(offset: 60, values: [
                (100, "WeChat", 40, 180, false),
                (200, "SpringBoard", 20, 85, false),
                (300, "backboardd", 15, 60, false),
                (999, "DTServiceHub", 999, 20, true)
            ]),
            try processBatch(offset: 65, values: [
                (100, "WeChat", 35, 190, false),
                (200, "SpringBoard", 18, 86, false),
                (300, "backboardd", 14, 61, false)
            ])
        ]
        let battery = [
            try battery(offset: 30, temperature: 3_975),
            try battery(offset: 50, temperature: 3_980),
            try battery(offset: 61, temperature: 4_029),
            try battery(offset: 65, temperature: 4_030)
        ]
        let energy = [
            try energy(offset: 30, cost: 10),
            try energy(offset: 50, cost: 10),
            try energy(offset: 61, cost: 20),
            try energy(offset: 65, cost: 20)
        ]
        let gaps = includeGap ? [try gap(offset: 62)] : []
        return (makeInput(
            system: systemSamples,
            processes: processes,
            battery: battery,
            energy: energy,
            gaps: gaps,
            markers: [marker]
        ), marker)
    }

    private func makeInput(
        system: [SystemPerformanceSample] = [],
        processes: [ProcessPerformanceBatch] = [],
        battery: [BatteryTelemetrySample] = [],
        energy: [EnergySample] = [],
        gaps: [PerformanceStreamGap] = [],
        markers: [PerformanceUserMarker] = []
    ) -> PerformanceTimelineInput {
        PerformanceTimelineInput(
            sessionID: session,
            sessionStartMonotonicNS: start,
            sessionStartTimestamp: Date(timeIntervalSince1970: 0),
            systemSamples: system,
            processBatches: processes,
            batterySamples: battery,
            energySamples: energy,
            networkSummaries: [],
            gaps: gaps,
            markers: markers
        )
    }

    private func system(
        offset: Int,
        cpu: Double,
        free: Double? = nil,
        compressed: Double? = nil
    ) throws -> SystemPerformanceSample {
        var metrics: [String: Any] = ["CPU_TotalLoad": metric(cpu, field: "CPU_TotalLoad")]
        if let free { metrics["vmFreeCount"] = metric(free, field: "vmFreeCount") }
        if let compressed { metrics["vmCompressorPageCount"] = metric(compressed, field: "vmCompressorPageCount") }
        return try XCTUnwrap(SystemPerformanceSample(message: message(
            type: "system_sample", offset: offset, source: "sysmon", payload: ["metrics": metrics]
        )))
    }

    private func processBatch(
        offset: Int,
        values: [(Int, String, Double, Double, Bool)]
    ) throws -> ProcessPerformanceBatch {
        let processes: [[String: Any]] = values.map { pid, name, cpu, memory, observer in
            [
                "pid": pid,
                "name": name,
                "monitor_overhead": observer,
                "metrics": [
                    "cpuUsage": metric(cpu, field: "cpuUsage"),
                    "physFootprint": metric(
                        memory * 1_048_576,
                        field: "physFootprint",
                        display: memory,
                        displayUnit: "MiB"
                    )
                ]
            ]
        }
        return try XCTUnwrap(ProcessPerformanceBatch(message: message(
            type: "process_batch", offset: offset, source: "sysmon", payload: ["processes": processes]
        )))
    }

    private func battery(offset: Int, temperature: Double) throws -> BatteryTelemetrySample {
        try XCTUnwrap(BatteryTelemetrySample(message: message(
            type: "battery_sample",
            offset: offset,
            source: "battery",
            payload: ["metrics": ["Temperature": metric(temperature, field: "Temperature")]]
        )))
    }

    private func energy(offset: Int, cost: Double) throws -> EnergySample {
        try XCTUnwrap(EnergySample(message: message(
            type: "energy_sample",
            offset: offset,
            source: "energy",
            payload: ["metrics": ["cost.total": metric(cost, field: "cost.total")]]
        )))
    }

    private func marker(offset: Int) throws -> PerformanceUserMarker {
        try XCTUnwrap(PerformanceUserMarker(message: message(
            type: "lag_marker", offset: offset, source: "helper", payload: ["note": "测试卡顿"]
        )))
    }

    private func gap(offset: Int) throws -> PerformanceStreamGap {
        try XCTUnwrap(PerformanceStreamGap(message: message(
            type: "stream_gap",
            offset: offset,
            source: "sysmon",
            payload: ["provider": "sysmon", "stream": "system_sample", "observed_gap_ms": 3_000]
        )))
    }

    private func message(type: String, offset: Int, source: String, payload: [String: Any]) throws -> PerformanceMessage {
        let object: [String: Any] = [
            "protocol_version": 2,
            "type": type,
            "timestamp_utc": "2026-08-10T10:00:\(String(format: "%02d", offset % 60)).000Z",
            "monotonic_ns": start + UInt64(offset) * 1_000_000_000,
            "sequence": offset,
            "session_id": session,
            "source": source,
            "payload": payload
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        switch PerformanceJSONLDecoder().decode(line: String(decoding: data, as: UTF8.self)) {
        case .message(let message): return message
        default: throw NSError(domain: "PerformanceInsightsTests", code: 1)
        }
    }

    private func metric(
        _ value: Any,
        field: String,
        display: Double? = nil,
        displayUnit: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = ["value": value, "raw_field": field]
        if let display { result["display_value"] = display }
        if let displayUnit { result["display_unit"] = displayUnit }
        return result
    }

    private func points(_ values: [Double]) -> [TimelinePoint] {
        values.enumerated().map { index, value in
            TimelinePoint(
                id: "trend-\(index)",
                sessionID: session,
                seriesID: "trend",
                timestamp: nil,
                monotonicNS: start + UInt64(index) * 1_000_000_000,
                relativeSeconds: Double(index),
                value: value
            )
        }
    }
}
