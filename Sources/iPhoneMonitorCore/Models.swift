import Foundation

public struct DeviceInfo: Identifiable, Codable, Hashable, Sendable {
    public let identifier: String
    public let name: String
    public let modelName: String
    public let modelCode: String
    public let operatingSystemVersion: String
    public let interface: String
    public let available: Bool
    public let statusDetail: String?

    public var id: String { identifier }

    public init(
        identifier: String,
        name: String,
        modelName: String,
        modelCode: String,
        operatingSystemVersion: String,
        interface: String,
        available: Bool,
        statusDetail: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.modelName = modelName
        self.modelCode = modelCode
        self.operatingSystemVersion = operatingSystemVersion
        self.interface = interface
        self.available = available
        self.statusDetail = statusDetail
    }

    public var maskedIdentifier: String {
        guard identifier.count > 12 else { return identifier }
        return "\(identifier.prefix(6))…\(identifier.suffix(4))"
    }

    public var connectionLabel: String {
        switch interface.lowercased() {
        case "usb": return "USB"
        case "network", "wifi": return "Wi‑Fi"
        default: return interface.isEmpty ? "未知" : interface
        }
    }
}

public enum AlertSeverity: String, Codable, Sendable {
    case info
    case warning
    case critical
}

public struct HealthAlert: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let severity: AlertSeverity
    public let title: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        severity: AlertSeverity,
        title: String,
        detail: String
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct TemperaturePoint: Identifiable, Codable, Hashable, Sendable {
    public let hour: Int
    public let averageCelsius: Double
    public let maximumCelsius: Double

    public var id: Int { hour }

    public init(hour: Int, averageCelsius: Double, maximumCelsius: Double) {
        self.hour = hour
        self.averageCelsius = averageCelsius
        self.maximumCelsius = maximumCelsius
    }
}

public struct AppMemoryMetric: Identifiable, Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let peakMB: Double
    public let suspendedMB: Double
    public let peakTime: String

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        peakMB: Double,
        suspendedMB: Double,
        peakTime: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.peakMB = peakMB
        self.suspendedMB = suspendedMB
        self.peakTime = peakTime
    }
}

public struct ProcessMetric: Identifiable, Codable, Hashable, Sendable {
    public let processName: String
    public let instances: Int
    public let cpuSeconds: Double
    public let diskReadMB: Double
    public let diskWriteMB: Double

    public var id: String { processName }

    public init(
        processName: String,
        instances: Int,
        cpuSeconds: Double,
        diskReadMB: Double,
        diskWriteMB: Double
    ) {
        self.processName = processName
        self.instances = instances
        self.cpuSeconds = cpuSeconds
        self.diskReadMB = diskReadMB
        self.diskWriteMB = diskWriteMB
    }
}

public struct DailySnapshot: Identifiable, Codable, Hashable, Sendable {
    public let date: String
    public let sampleCount: Int
    public let averageTemperature: Double
    public let maximumTemperature: Double
    public let hotMinutes: Double
    public let minimumBatteryPercent: Double
    public let maximumBatteryPercent: Double
    public let memoryWarningPercent: Double
    public let maximumSwapMB: Double
    public let spotlightIndexedItems: Int
    public let temperaturePoints: [TemperaturePoint]
    public let topApps: [AppMemoryMetric]
    public let topProcesses: [ProcessMetric]
    public let alerts: [HealthAlert]

    public var id: String { date }

    public init(
        date: String,
        sampleCount: Int,
        averageTemperature: Double,
        maximumTemperature: Double,
        hotMinutes: Double,
        minimumBatteryPercent: Double,
        maximumBatteryPercent: Double,
        memoryWarningPercent: Double,
        maximumSwapMB: Double,
        spotlightIndexedItems: Int,
        temperaturePoints: [TemperaturePoint],
        topApps: [AppMemoryMetric],
        topProcesses: [ProcessMetric],
        alerts: [HealthAlert]
    ) {
        self.date = date
        self.sampleCount = sampleCount
        self.averageTemperature = averageTemperature
        self.maximumTemperature = maximumTemperature
        self.hotMinutes = hotMinutes
        self.minimumBatteryPercent = minimumBatteryPercent
        self.maximumBatteryPercent = maximumBatteryPercent
        self.memoryWarningPercent = memoryWarningPercent
        self.maximumSwapMB = maximumSwapMB
        self.spotlightIndexedItems = spotlightIndexedItems
        self.temperaturePoints = temperaturePoints
        self.topApps = topApps
        self.topProcesses = topProcesses
        self.alerts = alerts
    }
}

public struct DiagnosticReport: Codable, Hashable, Sendable {
    public let sourceName: String
    public let importedAt: Date
    public let batteryHealthPercent: Int?
    public let cycleCount: Int?
    public let freeStorageGB: Double?
    public let days: [DailySnapshot]
    public let generalAlerts: [HealthAlert]

    public init(
        sourceName: String,
        importedAt: Date,
        batteryHealthPercent: Int?,
        cycleCount: Int?,
        freeStorageGB: Double?,
        days: [DailySnapshot],
        generalAlerts: [HealthAlert]
    ) {
        self.sourceName = sourceName
        self.importedAt = importedAt
        self.batteryHealthPercent = batteryHealthPercent
        self.cycleCount = cycleCount
        self.freeStorageGB = freeStorageGB
        self.days = days
        self.generalAlerts = generalAlerts
    }

    public var preferredDay: DailySnapshot? {
        if days.count > 1 {
            return days.dropLast().last
        }
        return days.last
    }
}
