import XCTest
@testable import iPhoneMonitorCore

final class PerformanceJSONLDecoderTests: XCTestCase {
    private let decoder = PerformanceJSONLDecoder()

    func testBalancedConfigurationUsesRealHelperFieldNames() {
        let balanced = PerformanceMonitoringConfiguration()
        XCTAssertEqual(balanced.helperPayload["sample_interval_ms"] as? Int, 1_000)
        XCTAssertEqual(balanced.helperPayload["max_processes"] as? Int, 30)
        XCTAssertEqual(balanced.helperPayload["enable_sysmon"] as? Bool, true)
        XCTAssertEqual(balanced.helperPayload["enable_battery"] as? Bool, true)
        XCTAssertEqual(balanced.helperPayload["enable_energy"] as? Bool, true)
        XCTAssertEqual(balanced.helperPayload["enable_network"] as? Bool, true)
        XCTAssertEqual(balanced.helperPayload["enable_oslog"] as? Bool, false)
        XCTAssertEqual(balanced.helperPayload["emit_log_messages"] as? Bool, false)

        let oslog = PerformanceMonitoringConfiguration(enableOSLog: true)
        XCTAssertEqual(oslog.helperPayload["enable_oslog"] as? Bool, true)
        XCTAssertEqual(oslog.helperPayload["emit_log_messages"] as? Bool, true)
    }

    func testProtocolV2DecodesTimestampSequenceAndMonotonicClock() throws {
        let message = try decodedMessage(line(type: "system_sample", sequence: 9))
        XCTAssertEqual(message.protocolVersion, 2)
        XCTAssertEqual(message.sequence, 9)
        XCTAssertEqual(message.monotonicNS, 1_000_009)
        XCTAssertNotNil(message.timestamp)
    }

    func testProtocolMismatchIsRejected() {
        let result = decoder.decode(line: #"{"protocol_version":3,"type":"helper_ready"}"#)
        XCTAssertEqual(result, .protocolMismatch(actual: 3))
    }

    func testUnknownMessageTypeIsPreserved() throws {
        let message = try decodedMessage(line(type: "future_sample", sequence: 1))
        XCTAssertEqual(message.type, .unknown("future_sample"))
        XCTAssertEqual(message.rawType, "future_sample")
    }

    func testMissingAndWrongTypedFieldsDoNotCrash() throws {
        let missing = try decodedMessage(#"{"protocol_version":2,"type":"heartbeat","payload":null}"#)
        XCTAssertNil(missing.sequence)
        XCTAssertFalse(missing.compatibilityWarnings.isEmpty)

        let wrong = try decodedMessage(
            #"{"protocol_version":2,"type":"heartbeat","sequence":"one","monotonic_ns":false,"timestamp_utc":7,"session_id":2,"payload":[]}"#
        )
        XCTAssertTrue(wrong.payload.isEmpty)
        XCTAssertGreaterThanOrEqual(wrong.compatibilityWarnings.count, 4)
    }

    func testHelperReadyProducesCapabilityFromRealV2Payload() throws {
        let payload: [String: Any] = [
            "helper_version": "0.1.0",
            "python_version": "3.13.14",
            "pymobiledevice3_version": "10.2.3",
            "read_only": true,
            "commands": ["start_session", "mark_lag", "stop_session", "shutdown"],
            "event_types": ["helper_ready", "system_sample", "lag_marker"],
            "output_queue_capacity": 256
        ]
        let capability = PerformanceCapability(message: try decodedMessage(line(type: "helper_ready", payload: payload)))
        XCTAssertTrue(capability.readOnly)
        XCTAssertEqual(capability.outputQueueCapacity, 256)
        XCTAssertEqual(capability.pymobiledevice3Version, "10.2.3")
        XCTAssertTrue(capability.commands.contains("start_session"))
    }

    func testLagMarkerAndFutureUserMarkerShareOneModel() throws {
        for rawType in ["lag_marker", "user_marker"] {
            let message = try decodedMessage(line(type: rawType, payload: ["note": "切换页面", "elapsed_ms": 4200]))
            XCTAssertEqual(message.type, .userMarker)
            XCTAssertEqual(PerformanceUserMarker(message: message)?.note, "切换页面")
        }
    }

    func testSystemSampleKeepsRawCPUAndUnavailableNegativeLoads() throws {
        let payload: [String: Any] = ["metrics": [
            "CPU_TotalLoad": metric(0.42, field: "CPU_TotalLoad"),
            "CPU_SystemLoad": ["value": NSNull(), "raw_field": "CPU_SystemLoad", "availability": "unavailable", "raw_value": -1],
            "vmFreeCount": metric(321, field: "vmFreeCount")
        ]]
        let sample = try XCTUnwrap(SystemPerformanceSample(message: decodedMessage(line(type: "system_sample", payload: payload))))
        XCTAssertEqual(sample.metric("CPU_TotalLoad")?.rawDisplay, "0.42")
        XCTAssertNil(sample.metric("CPU_TotalLoad")?.unit)
        XCTAssertEqual(sample.metric("CPU_SystemLoad")?.rawDisplay, "不可用")
        XCTAssertEqual(sample.metric("vmFreeCount")?.value?.intValue, 321)
    }

    func testProcessBatchUsesHelperMiBAndObserverFlag() throws {
        let payload: [String: Any] = [
            "process_count": 314,
            "processes": [[
                "pid": 42,
                "name": "DTServiceHub",
                "monitor_overhead": true,
                "metrics": [
                    "cpuUsage": metric(0.7, field: "cpuUsage"),
                    "physFootprint": metric(10_485_760, field: "physFootprint", display: 10, displayUnit: "MiB")
                ]
            ]]
        ]
        let batch = try XCTUnwrap(ProcessPerformanceBatch(message: decodedMessage(line(type: "process_batch", payload: payload))))
        XCTAssertEqual(batch.processCount, 314)
        XCTAssertEqual(batch.processes.first?.physicalMemoryMiB, 10)
        XCTAssertEqual(batch.processes.first?.observerOverhead, true)
    }

    func testBatterySampleDoesNotRenameTemperatureOrHealthUnits() throws {
        let payload: [String: Any] = ["metrics": [
            "CurrentCapacity": metric(78, field: "CurrentCapacity", unit: "percent"),
            "Temperature": metric(2990, field: "Temperature"),
            "BatteryHealthMetric": metric(87, field: "BatteryHealthMetric")
        ]]
        let sample = try XCTUnwrap(BatteryTelemetrySample(message: decodedMessage(line(type: "battery_sample", payload: payload))))
        XCTAssertEqual(sample.metric("CurrentCapacity")?.confirmedDisplay, "78 percent")
        XCTAssertNil(sample.metric("Temperature")?.unit)
        XCTAssertNil(sample.metric("BatteryHealthMetric")?.unit)
    }

    func testEnergySampleKeepsRawScore() throws {
        let payload: [String: Any] = [
            "target_processes": [["pid": 55, "name": "SpringBoard"]],
            "metrics": ["cost.cpu": metric(12.5, field: "cost.cpu")]
        ]
        let sample = try XCTUnwrap(EnergySample(message: decodedMessage(line(type: "energy_sample", payload: payload))))
        XCTAssertEqual(sample.targetProcesses, ["SpringBoard"])
        XCTAssertEqual(sample.metrics["cost.cpu"]?.rawDisplay, "12.5")
        XCTAssertNil(sample.metrics["cost.cpu"]?.unit)
    }

    func testLogEventKeepsCandidateLabelsOnly() throws {
        let payload: [String: Any] = [
            "process": "SpringBoard",
            "subsystem": "com.apple.test",
            "category": "runtime",
            "level": "error",
            "message_preview": "candidate thermal event",
            "candidate_tags": ["candidate:thermal"],
            "diagnostic_conclusion": false
        ]
        let event = try XCTUnwrap(PerformanceLogEvent(message: decodedMessage(line(type: "log_event", payload: payload))))
        XCTAssertEqual(event.candidateTags, ["candidate:thermal"])
        XCTAssertEqual(event.messagePreview, "candidate thermal event")
    }

    func testLogSummaryDecodesPrivacyPreservingCounters() throws {
        let payload: [String: Any] = [
            "events_seen": 1_200,
            "keyword_events_emitted": 3,
            "keyword_events_rate_limited": 1,
            "levels": ["default": 900, "error": 4],
            "keyword_counts": ["thermal": 3],
            "full_log_retained": false
        ]
        let summary = try XCTUnwrap(PerformanceLogSummary(message: decodedMessage(line(type: "log_summary", payload: payload))))
        XCTAssertEqual(summary.eventsSeen, 1_200)
        XCTAssertEqual(summary.keywordCounts["thermal"], 3)
        XCTAssertFalse(summary.fullLogRetained)
    }

    func testNetworkSummaryContainsOnlyAggregates() throws {
        let payload: [String: Any] = [
            "active_connections_observed": 8,
            "rx_bytes_delta": 2048,
            "tx_bytes_delta": 1024,
            "process_attribution_available": false,
            "addresses_retained": false,
            "payloads_captured": false
        ]
        let sample = try XCTUnwrap(NetworkSummary(message: decodedMessage(line(type: "network_summary", payload: payload))))
        XCTAssertEqual(sample.receivedBytesDelta, 2048)
        XCTAssertFalse(sample.processAttributionAvailable)
    }

    func testStreamGapAndProviderErrorDecode() throws {
        let gap = try XCTUnwrap(PerformanceStreamGap(message: decodedMessage(line(
            type: "stream_gap",
            source: "sysmon",
            payload: ["stream": "system_sample", "expected_interval_ms": 1000, "observed_gap_ms": 2600]
        ))))
        XCTAssertEqual(gap.provider, "sysmon")
        XCTAssertEqual(gap.observedGapMS, 2600)

        let error = try XCTUnwrap(PerformanceProviderError(message: decodedMessage(line(
            type: "provider_error",
            source: "energy",
            payload: ["provider": "energy", "error_type": "Unavailable", "error": "service unavailable", "isolated": true]
        ))))
        XCTAssertTrue(error.isolated)
        XCTAssertEqual(error.provider, "energy")
    }

    func testCommandErrorIsNotPresentedAsProviderError() throws {
        let message = try decodedMessage(line(
            type: "command_error",
            source: "helper",
            payload: [
                "error_type": "FixtureError",
                "error": "RSD fixture detail that belongs in diagnostics"
            ]
        ))

        XCTAssertNil(PerformanceProviderError(message: message))
    }

    func testHeartbeatDecodesProviderAndBoundedQueueState() throws {
        let payload: [String: Any] = [
            "provider_states": ["sysmon": "running", "energy": "waiting_for_processes"],
            "provider_error_count": 1,
            "reconnect_count": 0,
            "output_queue": ["capacity": 256, "current_occupancy": 4, "high_watermark": 18, "dropped_count": 2]
        ]
        let heartbeat = try XCTUnwrap(PerformanceHeartbeat(message: decodedMessage(line(type: "heartbeat", payload: payload))))
        XCTAssertEqual(heartbeat.providerStates["sysmon"], "running")
        XCTAssertEqual(heartbeat.queue.capacity, 256)
        XCTAssertEqual(heartbeat.queue.droppedCount, 2)
    }

    func testNonJSONStdoutIsReportedWithoutCrash() {
        XCTAssertEqual(
            decoder.decode(line: "progress: connecting"),
            .invalidLine(reason: "stdout 混入非 JSON 文本")
        )
    }

    private func decodedMessage(_ line: String) throws -> PerformanceMessage {
        switch decoder.decode(line: line) {
        case .message(let message): return message
        default: throw NSError(domain: "PerformanceJSONLDecoderTests", code: 1)
        }
    }

    private func line(
        type: String,
        sequence: Int = 1,
        sessionID: String? = "session-redacted",
        source: String = "fixture",
        payload: [String: Any] = [:]
    ) -> String {
        let object: [String: Any] = [
            "protocol_version": 2,
            "type": type,
            "timestamp_utc": "2026-08-02T10:00:00.123Z",
            "monotonic_ns": 1_000_000 + sequence,
            "sequence": sequence,
            "session_id": sessionID ?? NSNull(),
            "source": source,
            "payload": payload
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func metric(
        _ value: Any,
        field: String,
        unit: String? = nil,
        display: Double? = nil,
        displayUnit: String? = nil
    ) -> [String: Any] {
        var object: [String: Any] = ["value": value, "raw_field": field]
        if let unit { object["unit"] = unit }
        if let display { object["display_value"] = display }
        if let displayUnit { object["display_unit"] = displayUnit }
        return object
    }
}
