import Foundation

public struct PerformanceMetric: Equatable, Sendable {
    public let value: JSONValue?
    public let rawField: String?
    public let unit: String?
    public let availability: String?
    public let displayValue: Double?
    public let displayUnit: String?

    public init(json: JSONValue?) {
        let object = json?.objectValue ?? [:]
        value = object["value"]
        rawField = object.string("raw_field")
        unit = object.string("unit")
        availability = object.string("availability")
        displayValue = object.double("display_value")
        displayUnit = object.string("display_unit")
    }

    public var rawDisplay: String {
        if availability == "unavailable" { return "不可用" }
        return value?.displayString ?? "—"
    }

    public var confirmedDisplay: String {
        if let displayValue, let displayUnit {
            return "\(Self.number(displayValue)) \(displayUnit)"
        }
        if let unit, unit != "bytes", let value = value?.displayString {
            return "\(value) \(unit)"
        }
        return rawDisplay
    }

    private static func number(_ value: Double) -> String {
        if value.rounded() == value { return String(format: "%.0f", value) }
        return String(format: "%.3f", value)
    }
}

public struct SystemPerformanceSample: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let sessionID: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let metrics: [String: PerformanceMetric]

    public init?(message: PerformanceMessage) {
        guard message.type == .systemSample else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        sessionID = message.sessionID
        timestamp = message.timestamp
        monotonicNS = message.monotonicNS
        metrics = Self.metrics(message.payload.object("metrics") ?? [:])
    }

    public func metric(_ name: String) -> PerformanceMetric? { metrics[name] }

    fileprivate static func metrics(_ object: [String: JSONValue]) -> [String: PerformanceMetric] {
        object.mapValues { PerformanceMetric(json: $0) }
    }
}

public struct ProcessPerformanceSample: Equatable, Sendable, Identifiable {
    public let id: Int
    public let pid: Int
    public let name: String
    public let observerOverhead: Bool
    public let metrics: [String: PerformanceMetric]

    public init?(json: JSONValue) {
        guard let object = json.objectValue, let pid = object.int("pid") else { return nil }
        self.id = pid
        self.pid = pid
        name = object.string("name") ?? "<unknown>"
        observerOverhead = object.bool("monitor_overhead") == true
        metrics = SystemPerformanceSample.metrics(object.object("metrics") ?? [:])
    }

    public func metric(_ name: String) -> PerformanceMetric? { metrics[name] }
    public var cpuRaw: Double? { metric("cpuUsage")?.value?.doubleValue }
    public var physicalMemoryMiB: Double? { metric("physFootprint")?.displayValue }
    public var residentMemoryMiB: Double? { metric("memResidentSize")?.displayValue }
}

public struct ProcessPerformanceBatch: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let sessionID: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let processCount: Int?
    public let processes: [ProcessPerformanceSample]

    public init?(message: PerformanceMessage) {
        guard message.type == .processBatch else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        sessionID = message.sessionID
        timestamp = message.timestamp
        monotonicNS = message.monotonicNS
        processCount = message.payload.int("process_count")
        processes = message.payload.array("processes")?.compactMap(ProcessPerformanceSample.init(json:)) ?? []
    }
}

public struct BatteryTelemetrySample: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let sessionID: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let metrics: [String: PerformanceMetric]
    public let powerTelemetryMetrics: [String: PerformanceMetric]

    public init?(message: PerformanceMessage) {
        guard message.type == .batterySample else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        sessionID = message.sessionID
        timestamp = message.timestamp
        monotonicNS = message.monotonicNS
        metrics = SystemPerformanceSample.metrics(message.payload.object("metrics") ?? [:])
        powerTelemetryMetrics = SystemPerformanceSample.metrics(
            message.payload.object("power_telemetry_metrics") ?? [:]
        )
    }

    public func metric(_ name: String) -> PerformanceMetric? {
        metrics[name] ?? powerTelemetryMetrics[name]
    }
}

public struct EnergySample: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let sessionID: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let metrics: [String: PerformanceMetric]
    public let targetProcesses: [String]

    public init?(message: PerformanceMessage) {
        guard message.type == .energySample else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        sessionID = message.sessionID
        timestamp = message.timestamp
        monotonicNS = message.monotonicNS
        metrics = SystemPerformanceSample.metrics(message.payload.object("metrics") ?? [:])
        targetProcesses = message.payload.array("target_processes")?.compactMap {
            $0.objectValue?.string("name")
        } ?? []
    }
}

public struct PerformanceLogEvent: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let timestamp: Date?
    public let process: String
    public let subsystem: String
    public let category: String
    public let level: String
    public let messagePreview: String?
    public let candidateTags: [String]

    public init?(message: PerformanceMessage) {
        guard message.type == .logEvent else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        timestamp = message.timestamp
        process = message.payload.string("process") ?? "<unknown>"
        subsystem = message.payload.string("subsystem") ?? ""
        category = message.payload.string("category") ?? ""
        level = message.payload.string("level") ?? "unknown"
        messagePreview = message.payload.string("message_preview")
        candidateTags = message.payload.array("candidate_tags")?.compactMap(\.stringValue) ?? []
    }
}

public struct PerformanceLogSummary: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let timestamp: Date?
    public let eventsSeen: Int
    public let keywordEventsEmitted: Int
    public let keywordEventsRateLimited: Int
    public let levels: [String: Int]
    public let keywordCounts: [String: Int]
    public let fullLogRetained: Bool

    public init?(message: PerformanceMessage) {
        guard message.type == .logSummary else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        timestamp = message.timestamp
        eventsSeen = message.payload.int("events_seen") ?? 0
        keywordEventsEmitted = message.payload.int("keyword_events_emitted") ?? 0
        keywordEventsRateLimited = message.payload.int("keyword_events_rate_limited") ?? 0
        levels = (message.payload.object("levels") ?? [:]).compactMapValues(\.intValue)
        keywordCounts = (message.payload.object("keyword_counts") ?? [:]).compactMapValues(\.intValue)
        fullLogRetained = message.payload.bool("full_log_retained") == true
    }
}

public struct NetworkSummary: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let sessionID: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let activeConnections: Int?
    public let receivedBytesDelta: Int?
    public let transmittedBytesDelta: Int?
    public let receivedPacketsDelta: Int?
    public let transmittedPacketsDelta: Int?
    public let processAttributionAvailable: Bool

    public init?(message: PerformanceMessage) {
        guard message.type == .networkSummary else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        sessionID = message.sessionID
        timestamp = message.timestamp
        monotonicNS = message.monotonicNS
        activeConnections = message.payload.int("active_connections_observed")
        receivedBytesDelta = message.payload.int("rx_bytes_delta")
        transmittedBytesDelta = message.payload.int("tx_bytes_delta")
        receivedPacketsDelta = message.payload.int("rx_packets_delta")
        transmittedPacketsDelta = message.payload.int("tx_packets_delta")
        processAttributionAvailable = message.payload.bool("process_attribution_available") == true
    }
}

public struct PerformanceStreamGap: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let sessionID: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let stream: String
    public let provider: String
    public let expectedIntervalMS: Double?
    public let observedGapMS: Double?

    public init?(message: PerformanceMessage) {
        guard message.type == .streamGap else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        sessionID = message.sessionID
        timestamp = message.timestamp
        monotonicNS = message.monotonicNS
        stream = message.payload.string("stream") ?? "unknown"
        provider = message.payload.string("provider") ?? message.source ?? "unknown"
        expectedIntervalMS = message.payload.double("expected_interval_ms")
        observedGapMS = message.payload.double("observed_gap_ms")
    }
}

public struct PerformanceProviderError: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let timestamp: Date?
    public let provider: String
    public let errorType: String
    public let summary: String
    public let isolated: Bool

    public init?(message: PerformanceMessage) {
        guard message.type == .providerError else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        timestamp = message.timestamp
        provider = message.payload.string("provider") ?? message.source ?? "helper"
        errorType = message.payload.string("error_type") ?? "UnknownError"
        summary = message.payload.string("error") ?? "未提供错误摘要"
        isolated = message.payload.bool("isolated") == true
    }
}

public struct PerformanceUserMarker: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let sessionID: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let note: String
    public let elapsedMS: Int?

    public init?(message: PerformanceMessage) {
        guard message.type == .userMarker else { return nil }
        id = message.sequence ?? message.monotonicNS ?? 0
        sessionID = message.sessionID
        timestamp = message.timestamp
        monotonicNS = message.monotonicNS
        note = message.payload.string("note") ?? ""
        elapsedMS = message.payload.int("elapsed_ms")
    }
}

public struct PerformanceOutputQueueStats: Equatable, Sendable {
    public let capacity: Int?
    public let currentOccupancy: Int?
    public let highWatermark: Int?
    public let droppedCount: Int

    public init(object: [String: JSONValue]) {
        capacity = object.int("capacity")
        currentOccupancy = object.int("current_occupancy")
        highWatermark = object.int("high_watermark")
        droppedCount = object.int("dropped_count") ?? 0
    }
}

public struct PerformanceHeartbeat: Equatable, Sendable {
    public let providerStates: [String: String]
    public let providerErrorCount: Int
    public let reconnectCount: Int
    public let queue: PerformanceOutputQueueStats

    public init?(message: PerformanceMessage) {
        guard message.type == .heartbeat else { return nil }
        providerStates = (message.payload.object("provider_states") ?? [:]).compactMapValues(\.stringValue)
        providerErrorCount = message.payload.int("provider_error_count") ?? 0
        reconnectCount = message.payload.int("reconnect_count") ?? 0
        queue = PerformanceOutputQueueStats(object: message.payload.object("output_queue") ?? [:])
    }
}
