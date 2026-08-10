import Foundation

public struct PerformanceJSONLDecoder: Sendable {
    public static let supportedProtocolVersion = 2

    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init() {}

    public func decode(line: String) -> PerformanceDecodingResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalidLine(reason: "stdout 中出现空行")
        }
        guard let data = trimmed.data(using: .utf8) else {
            return .invalidLine(reason: "stdout 行不是 UTF-8")
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .invalidLine(reason: "stdout 混入非 JSON 文本")
        }
        guard let object = raw as? [String: Any] else {
            return .invalidLine(reason: "JSONL 顶层不是对象")
        }

        let json = object.mapValues(JSONValue.init(any:))
        guard let protocolVersion = json.int("protocol_version") else {
            return .protocolMismatch(actual: nil)
        }
        guard protocolVersion == Self.supportedProtocolVersion else {
            return .protocolMismatch(actual: protocolVersion)
        }
        guard let rawType = json.string("type"), !rawType.isEmpty else {
            return .invalidLine(reason: "消息缺少字符串 type")
        }

        var warnings: [String] = []
        let payload: [String: JSONValue]
        if json["payload"] == nil || json["payload"] == .null {
            payload = [:]
        } else if let value = json.object("payload") {
            payload = value
        } else {
            payload = [:]
            warnings.append("payload 类型不是对象，已按空对象处理")
        }

        let sequence = json["sequence"]?.uint64Value
        if sequence == nil { warnings.append("sequence 缺失或类型错误") }
        let monotonicNS = json["monotonic_ns"]?.uint64Value
        if monotonicNS == nil { warnings.append("monotonic_ns 缺失或类型错误") }

        let timestampUTC = json.string("timestamp_utc") ?? json.string("timestamp")
        let timestamp = timestampUTC.flatMap(Self.parseTimestamp)
        if timestampUTC == nil {
            warnings.append("timestamp_utc 缺失")
        } else if timestamp == nil {
            warnings.append("timestamp_utc 格式无法识别")
        }

        if json["session_id"] != nil,
           json["session_id"] != .null,
           json.string("session_id") == nil {
            warnings.append("session_id 类型不是字符串")
        }

        return .message(
            PerformanceMessage(
                protocolVersion: protocolVersion,
                rawType: rawType,
                type: PerformanceMessageType(rawValue: rawType),
                timestampUTC: timestampUTC,
                timestamp: timestamp,
                monotonicNS: monotonicNS,
                sequence: sequence,
                sessionID: json.string("session_id"),
                source: json.string("source"),
                payload: payload,
                compatibilityWarnings: warnings
            )
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        if let date = fractionalTimestampFormatter.date(from: value) { return date }
        return timestampFormatter.date(from: value)
    }
}
