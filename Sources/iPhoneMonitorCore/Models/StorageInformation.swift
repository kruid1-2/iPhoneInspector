import Foundation

public struct StorageInformation: Codable, Hashable, Sendable {
    public var totalBytes: DataValue<Int64>
    public var availableBytes: DataValue<Int64>
    public var usedBytes: DataValue<Int64>
    public var reclaimableBytes: DataValue<Int64>
    public var updatedAt: Date?

    public init(
        totalBytes: DataValue<Int64> = .missing(.notReturned),
        availableBytes: DataValue<Int64> = .missing(.notReturned),
        usedBytes: DataValue<Int64> = .missing(.notReturned),
        reclaimableBytes: DataValue<Int64> = .missing(.notSupported),
        updatedAt: Date? = nil
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.reclaimableBytes = reclaimableBytes
        self.updatedAt = updatedAt
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
        return copy
    }

    public var hasAnyValue: Bool {
        totalBytes.value != nil
            || availableBytes.value != nil
            || usedBytes.value != nil
            || reclaimableBytes.value != nil
    }
}
