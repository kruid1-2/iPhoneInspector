import Foundation

public struct StorageInformation: Codable, Hashable, Sendable {
    public var totalBytes: DataValue<Int64>
    public var availableBytes: DataValue<Int64>
    public var usedBytes: DataValue<Int64>
    public var reclaimableBytes: DataValue<Int64>
    public var hardFreeBytes: DataValue<Int64>
    public var updatedAt: Date?

    public init(
        totalBytes: DataValue<Int64> = .missing(.notReturned),
        availableBytes: DataValue<Int64> = .missing(.notReturned),
        usedBytes: DataValue<Int64> = .missing(.notReturned),
        reclaimableBytes: DataValue<Int64> = .missing(.notSupported),
        hardFreeBytes: DataValue<Int64> = .missing(.notReturned),
        updatedAt: Date? = nil
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.reclaimableBytes = reclaimableBytes
        self.hardFreeBytes = hardFreeBytes
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case totalBytes
        case availableBytes
        case usedBytes
        case reclaimableBytes
        case hardFreeBytes
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalBytes: try container.decodeIfPresent(
                DataValue<Int64>.self,
                forKey: .totalBytes
            ) ?? .missing(.notReturned),
            availableBytes: try container.decodeIfPresent(
                DataValue<Int64>.self,
                forKey: .availableBytes
            ) ?? .missing(.notReturned),
            usedBytes: try container.decodeIfPresent(
                DataValue<Int64>.self,
                forKey: .usedBytes
            ) ?? .missing(.notReturned),
            reclaimableBytes: try container.decodeIfPresent(
                DataValue<Int64>.self,
                forKey: .reclaimableBytes
            ) ?? .missing(.notSupported),
            hardFreeBytes: try container.decodeIfPresent(
                DataValue<Int64>.self,
                forKey: .hardFreeBytes
            ) ?? .missing(.notReturned),
            updatedAt: try container.decodeIfPresent(
                Date.self,
                forKey: .updatedAt
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encode(availableBytes, forKey: .availableBytes)
        try container.encode(usedBytes, forKey: .usedBytes)
        try container.encode(reclaimableBytes, forKey: .reclaimableBytes)
        try container.encode(hardFreeBytes, forKey: .hardFreeBytes)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    public var usageFraction: Double? {
        guard
            totalBytes.availability == .available,
            availableBytes.availability == .available,
            usedBytes.availability == .available,
            totalBytes.source == availableBytes.source,
            totalBytes.source == usedBytes.source,
            let total = totalBytes.value,
            total > 0,
            let available = availableBytes.value,
            available >= 0,
            available <= total,
            let used = usedBytes.value,
            used == total - available
        else { return nil }
        return Double(used) / Double(total)
    }

    public func markedStale() -> Self {
        var copy = self
        copy.totalBytes = totalBytes.markedStale()
        copy.availableBytes = availableBytes.markedStale()
        copy.usedBytes = usedBytes.markedStale()
        copy.reclaimableBytes = reclaimableBytes.markedStale()
        copy.hardFreeBytes = hardFreeBytes.markedStale()
        return copy
    }

    public var hasAnyValue: Bool {
        totalBytes.value != nil
            || availableBytes.value != nil
            || usedBytes.value != nil
            || reclaimableBytes.value != nil
            || hardFreeBytes.value != nil
    }
}
