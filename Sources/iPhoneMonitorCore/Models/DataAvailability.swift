import Foundation

public enum DataAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case toolUnavailable
    case notSupported
    case permissionDenied
    case notReturned
    case parseFailed
    case requiresDiagnosticLog
    case unsupportedConnection
    case unavailable
    case stale
    case demo

    public var message: String {
        switch self {
        case .available:
            return "已读取"
        case .toolUnavailable:
            return "当前读取工具不支持"
        case .notSupported:
            return "当前 iOS 不允许直接读取"
        case .permissionDenied:
            return "需要解锁 iPhone 并信任此电脑"
        case .notReturned:
            return "当前 iOS 未返回此字段"
        case .parseFailed:
            return "返回数据解析失败"
        case .requiresDiagnosticLog:
            return "需要导入诊断日志"
        case .unsupportedConnection:
            return "当前连接方式不支持"
        case .unavailable:
            return "暂未获取到数据"
        case .stale:
            return "连接已断开，数据可能已过期"
        case .demo:
            return "演示数据"
        }
    }
}

public enum DataConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
    case unknown

    public var label: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        case .unknown: return "未知"
        }
    }
}

public struct DataValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value?
    public var availability: DataAvailability
    public var source: String
    public var rawFieldName: String?
    public var detail: String?
    public var confidence: DataConfidence
    public var updatedAt: Date?

    public init(
        value: Value? = nil,
        availability: DataAvailability,
        source: String,
        rawFieldName: String? = nil,
        detail: String? = nil,
        confidence: DataConfidence = .unknown,
        updatedAt: Date? = nil
    ) {
        self.value = value
        self.availability = availability
        self.source = source
        self.rawFieldName = rawFieldName
        self.detail = detail
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    public static func available(
        _ value: Value,
        source: String,
        rawFieldName: String? = nil,
        detail: String? = nil,
        confidence: DataConfidence = .high,
        updatedAt: Date = Date()
    ) -> Self {
        Self(
            value: value,
            availability: .available,
            source: source,
            rawFieldName: rawFieldName,
            detail: detail,
            confidence: confidence,
            updatedAt: updatedAt
        )
    }

    public static func missing(
        _ availability: DataAvailability,
        source: String = "实时设备连接",
        rawFieldName: String? = nil,
        detail: String? = nil
    ) -> Self {
        Self(
            value: nil,
            availability: availability,
            source: source,
            rawFieldName: rawFieldName,
            detail: detail
        )
    }

    public func markedStale() -> Self {
        guard value != nil else { return self }
        var copy = self
        copy.availability = .stale
        return copy
    }
}
