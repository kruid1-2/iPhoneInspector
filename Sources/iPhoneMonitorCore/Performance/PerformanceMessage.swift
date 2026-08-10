import Foundation

public enum PerformanceMessageType: Equatable, Sendable {
    case helperReady
    case capabilities
    case status
    case sessionStarted
    case systemSample
    case processBatch
    case batterySample
    case energySample
    case logEvent
    case logSummary
    case networkSummary
    case heartbeat
    case streamGap
    case userMarker
    case providerStatus
    case providerError
    case sessionEnded
    case commandAck
    case commandError
    case helperShutdown
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "helper_ready": self = .helperReady
        case "capabilities": self = .capabilities
        case "status": self = .status
        case "session_started": self = .sessionStarted
        case "system_sample": self = .systemSample
        case "process_batch": self = .processBatch
        case "battery_sample": self = .batterySample
        case "energy_sample": self = .energySample
        case "log_event": self = .logEvent
        case "log_summary": self = .logSummary
        case "network_summary": self = .networkSummary
        case "heartbeat": self = .heartbeat
        case "stream_gap": self = .streamGap
        case "lag_marker", "user_marker": self = .userMarker
        case "provider_status": self = .providerStatus
        case "provider_error": self = .providerError
        case "session_ended": self = .sessionEnded
        case "command_ack": self = .commandAck
        case "command_error": self = .commandError
        case "helper_shutdown": self = .helperShutdown
        default: self = .unknown(rawValue)
        }
    }
}

public struct PerformanceMessage: Equatable, Sendable, Identifiable {
    public let protocolVersion: Int
    public let rawType: String
    public let type: PerformanceMessageType
    public let timestampUTC: String?
    public let timestamp: Date?
    public let monotonicNS: UInt64?
    public let sequence: UInt64?
    public let sessionID: String?
    public let source: String?
    public let payload: [String: JSONValue]
    public let compatibilityWarnings: [String]

    public var id: String {
        if let sequence { return "sequence-\(sequence)" }
        return "\(rawType)-\(monotonicNS ?? 0)"
    }

    public var payloadKeySummary: String {
        let keys = payload.keys.sorted().prefix(12)
        return keys.isEmpty ? "无 payload 字段" : "字段：\(keys.joined(separator: ", "))"
    }
}

public enum PerformanceDecodingResult: Equatable, Sendable {
    case message(PerformanceMessage)
    case protocolMismatch(actual: Int?)
    case invalidLine(reason: String)
}

public struct PerformanceCapability: Equatable, Sendable {
    public let helperVersion: String?
    public let pythonVersion: String?
    public let pymobiledevice3Version: String?
    public let commands: [String]
    public let eventTypes: [String]
    public let readOnly: Bool
    public let outputQueueCapacity: Int?

    public init(message: PerformanceMessage) {
        helperVersion = message.payload.string("helper_version")
        pythonVersion = message.payload.string("python_version")
        pymobiledevice3Version = message.payload.string("pymobiledevice3_version")
        commands = message.payload.array("commands")?.compactMap(\.stringValue) ?? []
        eventTypes = message.payload.array("event_types")?.compactMap(\.stringValue) ?? []
        readOnly = message.payload.bool("read_only") == true
        outputQueueCapacity = message.payload.int("output_queue_capacity")
    }
}
