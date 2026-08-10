import Foundation

public enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case panic
    case jetsam
    case lowMemory
    case thermal
    case watchdog
    case crash
    case reset
    case battery
    case storage
    case springBoard
    case backboard
    case power
    case unknown

    public var label: String {
        switch self {
        case .panic: return "Panic / 异常重启"
        case .jetsam: return "Jetsam"
        case .lowMemory: return "内存压力"
        case .thermal: return "热压力"
        case .watchdog: return "看门狗超时"
        case .crash: return "进程崩溃"
        case .reset: return "重启记录"
        case .battery: return "电池"
        case .storage: return "存储"
        case .springBoard: return "SpringBoard"
        case .backboard: return "backboardd"
        case .power: return "PowerLog"
        case .unknown: return "未识别格式"
        }
    }
}

public struct DiagnosticRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var category: DiagnosticCategory
    public var timestamp: Date?
    public var processName: String?
    public var summary: String
    public var evidence: String
    public var sourceFile: String
    public var confidence: DataConfidence

    public init(
        id: UUID = UUID(),
        category: DiagnosticCategory,
        timestamp: Date? = nil,
        processName: String? = nil,
        summary: String,
        evidence: String,
        sourceFile: String,
        confidence: DataConfidence
    ) {
        self.id = id
        self.category = category
        self.timestamp = timestamp
        self.processName = processName
        self.summary = summary
        self.evidence = evidence
        self.sourceFile = sourceFile
        self.confidence = confidence
    }
}

public struct DiagnosticImportFailure: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fileName: String
    public var message: String

    public init(id: UUID = UUID(), fileName: String, message: String) {
        self.id = id
        self.fileName = fileName
        self.message = message
    }
}

public struct DiagnosticAnalysis: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceName: String
    public var importedAt: Date
    public var scannedFileCount: Int
    public var records: [DiagnosticRecord]
    public var failures: [DiagnosticImportFailure]
    public var battery: BatteryInformation
    public var storage: StorageInformation
    public var retainedCopyName: String?

    public init(
        id: UUID = UUID(),
        sourceName: String,
        importedAt: Date = Date(),
        scannedFileCount: Int,
        records: [DiagnosticRecord],
        failures: [DiagnosticImportFailure],
        battery: BatteryInformation = BatteryInformation(),
        storage: StorageInformation = StorageInformation(),
        retainedCopyName: String? = nil
    ) {
        self.id = id
        self.sourceName = sourceName
        self.importedAt = importedAt
        self.scannedFileCount = scannedFileCount
        self.records = records
        self.failures = failures
        self.battery = battery
        self.storage = storage
        self.retainedCopyName = retainedCopyName
    }
}
