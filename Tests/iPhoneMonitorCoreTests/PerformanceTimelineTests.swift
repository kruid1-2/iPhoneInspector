import Foundation
import XCTest
@testable import iPhoneMonitorCore

final class PerformanceTimelineTests: XCTestCase {
    private let session = "fixture-session"
    private let start: UInt64 = 1_000_000_000

    func testTimelineUsesMonotonicOrderAndSessionIsolation() throws {
        let input = makeInput(system: [
            try systemSample(sequence: 2, offsetSeconds: 2, cpu: 20),
            try systemSample(sequence: 1, offsetSeconds: 1, cpu: 10),
            try systemSample(sequence: 3, offsetSeconds: 3, cpu: 30, sessionID: "other-session")
        ])
        let frame = PerformanceTimelineBuilder.build(input: input, range: .all)
        let points = try XCTUnwrap(frame.series(kind: .systemCPU).first).points
        XCTAssertEqual(points.map(\.value), [10, 20])
        XCTAssertEqual(points.map(\.relativeSeconds), [1, 2])
        XCTAssertTrue(points.allSatisfy { $0.sessionID == session })
    }

    func testRangeFilteringUsesMonotonicClock() throws {
        let input = makeInput(system: [
            try systemSample(sequence: 1, offsetSeconds: 1, cpu: 1),
            try systemSample(sequence: 2, offsetSeconds: 40, cpu: 2),
            try systemSample(sequence: 3, offsetSeconds: 70, cpu: 3)
        ])
        let frame = PerformanceTimelineBuilder.build(input: input, range: .seconds30)
        XCTAssertEqual(frame.series(kind: .systemCPU).first?.points.map(\.value), [2, 3])
        XCTAssertEqual(frame.visibleLowerBound, 40, accuracy: 0.001)
    }

    func testDownsamplerPreservesFirstLastPeakAndValley() {
        let values = (0..<1_000).map { index -> Double in
            if index == 333 { return 9_999 }
            if index == 777 { return -8_888 }
            return Double(index % 17)
        }
        let points = values.enumerated().map { index, value in
            timelinePoint(index: index, value: value)
        }
        let sampled = TimelineDownsampler.downsample(points, maxPoints: 120)
        XCTAssertLessThanOrEqual(sampled.count, 120)
        XCTAssertEqual(sampled.first?.id, points.first?.id)
        XCTAssertEqual(sampled.last?.id, points.last?.id)
        XCTAssertTrue(sampled.contains { $0.value == 9_999 })
        XCTAssertTrue(sampled.contains { $0.value == -8_888 })
        XCTAssertEqual(sampled.map(\.monotonicNS), sampled.map(\.monotonicNS).sorted())
    }

    func testDownsamplerHandlesEmptySingleDuplicateAndNonFiniteValues() {
        XCTAssertTrue(TimelineDownsampler.downsample([], maxPoints: 10).isEmpty)
        let single = timelinePoint(index: 0, value: 1)
        XCTAssertEqual(TimelineDownsampler.downsample([single], maxPoints: 10), [single])
        let duplicate = TimelinePoint(
            id: "duplicate",
            sessionID: session,
            seriesID: "series",
            timestamp: nil,
            monotonicNS: single.monotonicNS,
            relativeSeconds: 0,
            value: 2
        )
        let invalid = TimelinePoint(
            id: "invalid",
            sessionID: session,
            seriesID: "series",
            timestamp: nil,
            monotonicNS: single.monotonicNS + 1,
            relativeSeconds: 0,
            value: .nan
        )
        let result = TimelineDownsampler.downsample([single, duplicate, invalid], maxPoints: 10)
        XCTAssertEqual(result.map(\.id), [single.id, duplicate.id])
    }

    func testStreamGapSplitsSeriesWithoutInterpolation() throws {
        let points = [0, 1, 4, 5].map { timelinePoint(index: $0, value: Double($0)) }
        let gap = try gap(sequence: 20, offsetSeconds: 3, provider: "sysmon", stream: "system_sample")
        let segments = TimelineDownsampler.segments(
            points: points,
            gaps: [gap],
            provider: "sysmon",
            seriesID: "series"
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].points.map(\.value), [0, 1])
        XCTAssertEqual(segments[1].points.map(\.value), [4, 5])
    }

    func testEnergyGapOnlySplitsEnergySeries() throws {
        let points = [1, 4].map { timelinePoint(index: $0, value: Double($0)) }
        let energyGap = try gap(sequence: 2, offsetSeconds: 3, provider: "energy", stream: "energy_sample")
        XCTAssertEqual(
            TimelineDownsampler.segments(points: points, gaps: [energyGap], provider: "energy", seriesID: "e").count,
            2
        )
        XCTAssertEqual(
            TimelineDownsampler.segments(points: points, gaps: [energyGap], provider: "battery", seriesID: "b").count,
            1
        )
    }

    func testLagAndUserMarkersBecomeOneTimelineEventModel() throws {
        let lag = try marker(type: "lag_marker", sequence: 4, offsetSeconds: 15, note: "切换时卡顿")
        let user = try marker(type: "user_marker", sequence: 5, offsetSeconds: 20, note: "滑动时卡顿")
        let input = makeInput(markers: [lag, user])
        let events = PerformanceTimelineBuilder.build(input: input, range: .all).events
            .filter { $0.kind == .userMarker }
        XCTAssertEqual(events.map(\.relativeSeconds), [15, 20])
        XCTAssertEqual(events.map(\.detail), ["切换时卡顿", "滑动时卡顿"])
    }

    func testPIDReuseWithChangedNameCreatesSeparateSeries() throws {
        let batches = [
            try processBatch(sequence: 1, offsetSeconds: 1, pid: 42, name: "FirstProcess", cpu: 1, memoryMiB: 10),
            try processBatch(sequence: 2, offsetSeconds: 2, pid: 42, name: "SecondProcess", cpu: 2, memoryMiB: 20)
        ]
        let frame = PerformanceTimelineBuilder.build(input: makeInput(processes: batches), range: .all)
        let series = frame.series(kind: .processCPU).filter { $0.pid == 42 }
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(Set(series.compactMap(\.processName)), Set(["FirstProcess", "SecondProcess"]))
        XCTAssertEqual(Set(series.compactMap(\.processIdentity)).count, 2)
    }

    func testPIDReuseWithSameNameAndChangedStartAbsTimeCreatesSeparateSeries() throws {
        let batches = [
            try processBatch(
                sequence: 1,
                offsetSeconds: 1,
                pid: 42,
                name: "SameProcess",
                cpu: 1,
                memoryMiB: 10,
                startAbsTime: 100
            ),
            try processBatch(
                sequence: 2,
                offsetSeconds: 2,
                pid: 42,
                name: "SameProcess",
                cpu: 2,
                memoryMiB: 20,
                startAbsTime: 200
            )
        ]
        let frame = PerformanceTimelineBuilder.build(input: makeInput(processes: batches), range: .all)
        let series = frame.series(kind: .processCPU).filter { $0.pid == 42 }

        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(Set(series.compactMap(\.processIdentity)).count, 2)
    }

    func testObserverOverheadIsNotAutomaticallyRecommended() throws {
        let batches = [
            try processBatch(sequence: 1, offsetSeconds: 1, pid: 1, name: "DTServiceHub", cpu: 999, memoryMiB: 10, observer: true),
            try processBatch(sequence: 2, offsetSeconds: 2, pid: 2, name: "SpringBoard", cpu: 10, memoryMiB: 20)
        ]
        let frame = PerformanceTimelineBuilder.build(input: makeInput(processes: batches), range: .all)
        let observerIdentity = frame.series(kind: .processCPU).first { $0.observerOverhead }?.processIdentity
        XCTAssertNotNil(observerIdentity)
        XCTAssertFalse(frame.recommendedProcessIdentities.contains(observerIdentity!))
        XCTAssertTrue(frame.series(kind: .processCPU).contains { $0.processName == "SpringBoard" })
    }

    func testDefaultProcessTimelineIsBoundedButKeepsObserverEvidence() throws {
        var batches: [ProcessPerformanceBatch] = []
        for index in 1...20 {
            batches.append(try processBatch(
                sequence: index,
                offsetSeconds: index,
                pid: index,
                name: "Process\(index)",
                cpu: Double(index),
                memoryMiB: Double(index)
            ))
        }
        batches.append(try processBatch(
            sequence: 21,
            offsetSeconds: 21,
            pid: 999,
            name: "DTServiceHub",
            cpu: 999,
            memoryMiB: 10,
            observer: true
        ))

        let frame = PerformanceTimelineBuilder.build(input: makeInput(processes: batches), range: .all)
        let processSeries = frame.series(kind: .processCPU)
        XCTAssertLessThanOrEqual(processSeries.count, 6)
        XCTAssertEqual(processSeries.filter(\.observerOverhead).count, 1)
        XCTAssertEqual(frame.recommendedProcessIdentities.count, 5)
    }

    func testProcessSearchAddsMatchingSeriesWithoutKeepingAllProcesses() throws {
        let batches = try (1...12).map { index in
            try processBatch(
                sequence: index,
                offsetSeconds: index,
                pid: index,
                name: index == 1 ? "photoanalysisd" : "Process\(index)",
                cpu: Double(index),
                memoryMiB: Double(index)
            )
        }
        let frame = PerformanceTimelineBuilder.build(
            input: makeInput(processes: batches),
            range: .all,
            processQuery: "photo"
        )
        XCTAssertTrue(frame.series(kind: .processCPU).contains { $0.processName == "photoanalysisd" })
        XCTAssertLessThan(frame.series(kind: .processCPU).count, 12)
    }

    func testRawUnitsRemainTruthful() throws {
        let system = try systemSample(sequence: 1, offsetSeconds: 1, cpu: 42, vm: 123)
        let battery = try batterySample(sequence: 2, offsetSeconds: 2, temperature: 3_450, voltage: 4_200, current: -900)
        let energy = try energySample(sequence: 3, offsetSeconds: 3, cost: 8.5, cpuCost: 2.25)
        let frame = PerformanceTimelineBuilder.build(
            input: makeInput(system: [system], battery: [battery], energy: [energy]),
            range: .all
        )
        XCTAssertEqual(frame.series(kind: .systemCPU).first?.unitLabel, "负载原始值")
        XCTAssertFalse(frame.series(kind: .systemCPU).first?.detail.contains("百分比") == false)
        XCTAssertEqual(frame.series(kind: .systemVM).first?.unitLabel, "内存页数（原始计数）")
        XCTAssertEqual(frame.series(kind: .batteryTemperature).first?.unitLabel, "原始值")
        XCTAssertTrue(frame.series(kind: .batteryTemperature).first?.detail.contains("不是 CPU 或 SoC") == true)
        XCTAssertTrue(frame.series(kind: .energyCost).first?.detail.contains("不是瓦特或焦耳") == true)
    }

    func testNetworkRateUsesActualMonotonicTimeDifference() throws {
        let first = try networkSample(sequence: 1, offsetSeconds: 1, rx: 512, tx: 256)
        let second = try networkSample(sequence: 2, offsetSeconds: 3, rx: 2_048, tx: 1_024)
        let frame = PerformanceTimelineBuilder.build(input: makeInput(network: [first, second]), range: .all)
        XCTAssertEqual(frame.series(kind: .networkReceive).first?.points.first?.value, 1_024)
        XCTAssertEqual(frame.series(kind: .networkTransmit).first?.points.first?.value, 512)
        XCTAssertEqual(frame.series(kind: .networkReceive).first?.unitLabel, "bytes/s")
    }

    func testBoundedCacheEvictionStillBuildsStableTimeline() throws {
        var buffer = BoundedPerformanceBuffer<SystemPerformanceSample>(capacity: 3)
        for index in 1...5 {
            buffer.append(try systemSample(sequence: index, offsetSeconds: index, cpu: Double(index)))
        }
        let frame = PerformanceTimelineBuilder.build(input: makeInput(system: buffer.elements), range: .all)
        XCTAssertEqual(frame.series(kind: .systemCPU).first?.points.map(\.value), [3, 4, 5])
    }

    func testStoppedSessionKeepsFinalDataAndEndEvent() throws {
        let input = PerformanceTimelineInput(
            sessionID: session,
            sessionStartMonotonicNS: start,
            sessionStartTimestamp: Date(timeIntervalSince1970: 0),
            sessionEndMonotonicNS: start + seconds(5),
            systemSamples: [try systemSample(sequence: 1, offsetSeconds: 1, cpu: 7)],
            processBatches: [],
            batterySamples: [],
            energySamples: [],
            networkSummaries: [],
            gaps: [],
            markers: []
        )
        let frame = PerformanceTimelineBuilder.build(input: input, range: .all)
        XCTAssertEqual(frame.series(kind: .systemCPU).first?.points.first?.value, 7)
        XCTAssertEqual(frame.events.last?.kind, .sessionEnded)
        XCTAssertEqual(frame.events.last?.relativeSeconds, 5)
    }

    func testEmptyTimelineHasOnlySessionBoundary() {
        let frame = PerformanceTimelineBuilder.build(input: makeInput(), range: .all)
        XCTAssertTrue(frame.series.isEmpty)
        XCTAssertEqual(frame.events.map(\.kind), [.sessionStarted])
        XCTAssertEqual(frame.rawPointCount, 0)
    }

    private func makeInput(
        system: [SystemPerformanceSample] = [],
        processes: [ProcessPerformanceBatch] = [],
        battery: [BatteryTelemetrySample] = [],
        energy: [EnergySample] = [],
        network: [NetworkSummary] = [],
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
            networkSummaries: network,
            gaps: gaps,
            markers: markers
        )
    }

    private func systemSample(
        sequence: Int,
        offsetSeconds: Int,
        cpu: Double,
        vm: Double? = nil,
        sessionID: String? = nil
    ) throws -> SystemPerformanceSample {
        var metrics: [String: Any] = ["CPU_TotalLoad": metric(cpu, field: "CPU_TotalLoad")]
        if let vm { metrics["vmFreeCount"] = metric(vm, field: "vmFreeCount") }
        return try XCTUnwrap(SystemPerformanceSample(message: message(
            type: "system_sample",
            sequence: sequence,
            offsetSeconds: offsetSeconds,
            sessionID: sessionID ?? session,
            source: "sysmon",
            payload: ["metrics": metrics]
        )))
    }

    private func processBatch(
        sequence: Int,
        offsetSeconds: Int,
        pid: Int,
        name: String,
        cpu: Double,
        memoryMiB: Double,
        observer: Bool = false,
        startAbsTime: Double? = nil
    ) throws -> ProcessPerformanceBatch {
        var metrics: [String: Any] = [
            "cpuUsage": metric(cpu, field: "cpuUsage"),
            "physFootprint": metric(
                memoryMiB * 1_048_576,
                field: "physFootprint",
                display: memoryMiB,
                displayUnit: "MiB"
            )
        ]
        if let startAbsTime {
            metrics["startAbsTime"] = metric(startAbsTime, field: "startAbsTime")
        }
        return try XCTUnwrap(ProcessPerformanceBatch(message: message(
            type: "process_batch",
            sequence: sequence,
            offsetSeconds: offsetSeconds,
            source: "sysmon",
            payload: [
                "processes": [[
                    "pid": pid,
                    "name": name,
                    "monitor_overhead": observer,
                    "metrics": metrics
                ]]
            ]
        )))
    }

    private func batterySample(
        sequence: Int,
        offsetSeconds: Int,
        temperature: Double,
        voltage: Double,
        current: Double
    ) throws -> BatteryTelemetrySample {
        try XCTUnwrap(BatteryTelemetrySample(message: message(
            type: "battery_sample",
            sequence: sequence,
            offsetSeconds: offsetSeconds,
            source: "battery",
            payload: ["metrics": [
                "Temperature": metric(temperature, field: "Temperature"),
                "Voltage": metric(voltage, field: "Voltage"),
                "InstantAmperage": metric(current, field: "InstantAmperage")
            ]]
        )))
    }

    private func energySample(
        sequence: Int,
        offsetSeconds: Int,
        cost: Double,
        cpuCost: Double
    ) throws -> EnergySample {
        try XCTUnwrap(EnergySample(message: message(
            type: "energy_sample",
            sequence: sequence,
            offsetSeconds: offsetSeconds,
            source: "energy",
            payload: ["metrics": [
                "cost.total": metric(cost, field: "cost.total"),
                "cost.cpu": metric(cpuCost, field: "cost.cpu")
            ]]
        )))
    }

    private func networkSample(
        sequence: Int,
        offsetSeconds: Int,
        rx: Int,
        tx: Int
    ) throws -> NetworkSummary {
        try XCTUnwrap(NetworkSummary(message: message(
            type: "network_summary",
            sequence: sequence,
            offsetSeconds: offsetSeconds,
            source: "network",
            payload: ["rx_bytes_delta": rx, "tx_bytes_delta": tx]
        )))
    }

    private func gap(
        sequence: Int,
        offsetSeconds: Int,
        provider: String,
        stream: String
    ) throws -> PerformanceStreamGap {
        try XCTUnwrap(PerformanceStreamGap(message: message(
            type: "stream_gap",
            sequence: sequence,
            offsetSeconds: offsetSeconds,
            source: provider,
            payload: ["provider": provider, "stream": stream, "observed_gap_ms": 2_500]
        )))
    }

    private func marker(
        type: String,
        sequence: Int,
        offsetSeconds: Int,
        note: String
    ) throws -> PerformanceUserMarker {
        try XCTUnwrap(PerformanceUserMarker(message: message(
            type: type,
            sequence: sequence,
            offsetSeconds: offsetSeconds,
            source: "helper",
            payload: ["note": note, "elapsed_ms": offsetSeconds * 1_000]
        )))
    }

    private func message(
        type: String,
        sequence: Int,
        offsetSeconds: Int,
        sessionID: String? = nil,
        source: String,
        payload: [String: Any]
    ) throws -> PerformanceMessage {
        let object: [String: Any] = [
            "protocol_version": 2,
            "type": type,
            "timestamp_utc": "2026-08-02T10:00:\(String(format: "%02d", offsetSeconds % 60)).000Z",
            "monotonic_ns": start + seconds(offsetSeconds),
            "sequence": sequence,
            "session_id": sessionID ?? session,
            "source": source,
            "payload": payload
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        switch PerformanceJSONLDecoder().decode(line: String(decoding: data, as: UTF8.self)) {
        case .message(let message): return message
        default: throw NSError(domain: "PerformanceTimelineTests", code: 1)
        }
    }

    private func timelinePoint(index: Int, value: Double) -> TimelinePoint {
        TimelinePoint(
            id: "point-\(index)",
            sessionID: session,
            seriesID: "series",
            timestamp: nil,
            monotonicNS: start + seconds(max(0, index)),
            relativeSeconds: Double(index),
            value: value
        )
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

    private func seconds(_ value: Int) -> UInt64 {
        UInt64(value) * 1_000_000_000
    }
}
