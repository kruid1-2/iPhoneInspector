import Foundation

public struct BatteryInformation: Codable, Hashable, Sendable {
    public var currentLevelPercent: DataValue<Double>
    public var isCharging: DataValue<Bool>
    public var externalPowerConnected: DataValue<Bool>
    public var healthPercent: DataValue<Int>
    public var designCapacityMAh: DataValue<Int>
    public var maximumCapacityMAh: DataValue<Int>
    public var cycleCount: DataValue<Int>
    public var serialOrManufacturingInfo: DataValue<String>
    public var verificationStatus: DataValue<String>
    public var chargingStatus: DataValue<String>
    public var latestLogDate: Date?

    public init(
        currentLevelPercent: DataValue<Double> = .missing(.notReturned),
        isCharging: DataValue<Bool> = .missing(.notReturned),
        externalPowerConnected: DataValue<Bool> = .missing(.notReturned),
        healthPercent: DataValue<Int> = .missing(.notReturned),
        designCapacityMAh: DataValue<Int> = .missing(.notReturned),
        maximumCapacityMAh: DataValue<Int> = .missing(.notReturned),
        cycleCount: DataValue<Int> = .missing(.notReturned),
        serialOrManufacturingInfo: DataValue<String> = .missing(.notSupported),
        verificationStatus: DataValue<String> = .missing(.notReturned),
        chargingStatus: DataValue<String> = .missing(.notReturned),
        latestLogDate: Date? = nil
    ) {
        self.currentLevelPercent = currentLevelPercent
        self.isCharging = isCharging
        self.externalPowerConnected = externalPowerConnected
        self.healthPercent = healthPercent
        self.designCapacityMAh = designCapacityMAh
        self.maximumCapacityMAh = maximumCapacityMAh
        self.cycleCount = cycleCount
        self.serialOrManufacturingInfo = serialOrManufacturingInfo
        self.verificationStatus = verificationStatus
        self.chargingStatus = chargingStatus
        self.latestLogDate = latestLogDate
    }

    public func markedStale() -> Self {
        var copy = self
        copy.currentLevelPercent = currentLevelPercent.markedStale()
        copy.isCharging = isCharging.markedStale()
        copy.externalPowerConnected = externalPowerConnected.markedStale()
        copy.healthPercent = healthPercent.markedStale()
        copy.designCapacityMAh = designCapacityMAh.markedStale()
        copy.maximumCapacityMAh = maximumCapacityMAh.markedStale()
        copy.cycleCount = cycleCount.markedStale()
        copy.serialOrManufacturingInfo = serialOrManufacturingInfo.markedStale()
        copy.verificationStatus = verificationStatus.markedStale()
        copy.chargingStatus = chargingStatus.markedStale()
        return copy
    }

    public var hasAnyValue: Bool {
        currentLevelPercent.value != nil
            || isCharging.value != nil
            || externalPowerConnected.value != nil
            || healthPercent.value != nil
            || designCapacityMAh.value != nil
            || maximumCapacityMAh.value != nil
            || cycleCount.value != nil
            || chargingStatus.value != nil
    }
}
