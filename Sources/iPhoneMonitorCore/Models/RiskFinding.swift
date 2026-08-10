import Foundation

public enum RiskLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case insufficient = -1
    case normal = 0
    case notice = 1
    case moderate = 2
    case high = 3
    case severe = 4

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .normal: return "正常"
        case .notice: return "提醒"
        case .moderate: return "中等"
        case .high: return "较高"
        case .severe: return "严重"
        case .insufficient: return "信息不足"
        }
    }
}

public struct RiskFinding: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var level: RiskLevel
    public var summary: String
    public var evidence: [String]
    public var sources: [String]
    public var timestamp: Date?
    public var confidence: DataConfidence
    public var recommendation: String
    public var userActionable: Bool

    public init(
        id: String,
        title: String,
        level: RiskLevel,
        summary: String,
        evidence: [String],
        sources: [String],
        timestamp: Date? = nil,
        confidence: DataConfidence,
        recommendation: String,
        userActionable: Bool
    ) {
        self.id = id
        self.title = title
        self.level = level
        self.summary = summary
        self.evidence = evidence
        self.sources = sources
        self.timestamp = timestamp
        self.confidence = confidence
        self.recommendation = recommendation
        self.userActionable = userActionable
    }
}
