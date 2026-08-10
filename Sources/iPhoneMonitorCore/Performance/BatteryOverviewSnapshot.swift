import Foundation

public enum BatteryOverviewSource: Equatable, Sendable {
    case realtime
    case recentRead
    case unavailable

    public var label: String {
        switch self {
        case .realtime: return "实时"
        case .recentRead: return "最近读取"
        case .unavailable: return "暂无数据"
        }
    }
}

public struct BatteryOverviewSnapshot: Equatable, Sendable {
    public let currentLevelPercent: Double?
    public let isCharging: Bool?
    public let externalPowerConnected: Bool?
    public let healthPercent: Int?
    public let temperatureRaw: Double?
    public let source: BatteryOverviewSource
    public let updatedAt: Date?

    public init(
        currentLevelPercent: Double?,
        isCharging: Bool?,
        externalPowerConnected: Bool?,
        healthPercent: Int?,
        temperatureRaw: Double?,
        source: BatteryOverviewSource,
        updatedAt: Date?
    ) {
        self.currentLevelPercent = currentLevelPercent
        self.isCharging = isCharging
        self.externalPowerConnected = externalPowerConnected
        self.healthPercent = healthPercent
        self.temperatureRaw = temperatureRaw
        self.source = source
        self.updatedAt = updatedAt
    }
}

public enum BatteryOverviewResolver {
    // The balanced Helper samples battery data every two seconds. Four missed
    // samples are enough to stop presenting an old value as live without
    // creating a separate freshness subsystem.
    public static let defaultFreshnessInterval: TimeInterval = 8

    public static func resolve(
        staticBattery: BatteryInformation,
        liveSample: BatteryTelemetrySample?,
        liveReceivedAt: Date?,
        performanceState: PerformanceSessionState,
        now: Date = Date(),
        freshnessInterval: TimeInterval = defaultFreshnessInterval
    ) -> BatteryOverviewSnapshot {
        let liveIsFresh: Bool = {
            guard performanceState == .monitoring,
                  let liveSample,
                  let liveReceivedAt,
                  freshnessInterval > 0
            else { return false }
            let age = max(0, now.timeIntervalSince(liveReceivedAt))
            return age <= freshnessInterval && hasUsableOverviewValue(liveSample)
        }()

        let staticUpdatedAt = [
            staticBattery.currentLevelPercent.updatedAt,
            staticBattery.isCharging.updatedAt,
            staticBattery.externalPowerConnected.updatedAt,
            staticBattery.healthPercent.updatedAt
        ].compactMap { $0 }.max()

        guard liveIsFresh, let liveSample else {
            let hasStaticValue = staticBattery.currentLevelPercent.value != nil
                || staticBattery.isCharging.value != nil
                || staticBattery.externalPowerConnected.value != nil
                || staticBattery.healthPercent.value != nil
            return BatteryOverviewSnapshot(
                currentLevelPercent: staticBattery.currentLevelPercent.value,
                isCharging: staticBattery.isCharging.value,
                externalPowerConnected: staticBattery.externalPowerConnected.value,
                healthPercent: staticBattery.healthPercent.value,
                temperatureRaw: nil,
                source: hasStaticValue ? .recentRead : .unavailable,
                updatedAt: staticUpdatedAt
            )
        }

        return BatteryOverviewSnapshot(
            currentLevelPercent: validPercent(liveSample.metric("CurrentCapacity"))
                ?? staticBattery.currentLevelPercent.value,
            isCharging: liveSample.metric("IsCharging")?.value?.boolValue
                ?? staticBattery.isCharging.value,
            externalPowerConnected: liveSample.metric("ExternalConnected")?.value?.boolValue
                ?? staticBattery.externalPowerConnected.value,
            // BatteryHealthMetric is deliberately not treated as a percentage.
            healthPercent: staticBattery.healthPercent.value,
            temperatureRaw: liveSample.metric("Temperature")?.value?.doubleValue,
            source: .realtime,
            updatedAt: liveReceivedAt
        )
    }

    private static func hasUsableOverviewValue(_ sample: BatteryTelemetrySample) -> Bool {
        validPercent(sample.metric("CurrentCapacity")) != nil
            || sample.metric("IsCharging")?.value?.boolValue != nil
            || sample.metric("ExternalConnected")?.value?.boolValue != nil
            || sample.metric("Temperature")?.value?.doubleValue != nil
    }

    private static func validPercent(_ metric: PerformanceMetric?) -> Double? {
        guard let value = metric?.value?.doubleValue, (0...100).contains(value) else { return nil }
        return value
    }
}
