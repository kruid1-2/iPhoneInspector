import Combine
import Foundation
import iPhoneMonitorCore

@MainActor
final class AppStore: ObservableObject {
    let settingsStore: SettingsStore
    let deviceStore: DeviceStore
    let diagnosticStore: DiagnosticStore
    let performanceMonitorStore: PerformanceMonitorStore
    let riskService: RiskAnalysisService

    @Published var isImporterPresented = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        settingsStore: SettingsStore? = nil,
        deviceStore: DeviceStore? = nil,
        diagnosticStore: DiagnosticStore? = nil,
        performanceMonitorStore: PerformanceMonitorStore? = nil,
        riskService: RiskAnalysisService = RiskAnalysisService()
    ) {
        let resolvedSettingsStore = settingsStore ?? SettingsStore()
        let resolvedDeviceStore = deviceStore ?? DeviceStore()
        let resolvedDiagnosticStore = diagnosticStore ?? DiagnosticStore()
        self.settingsStore = resolvedSettingsStore
        self.deviceStore = resolvedDeviceStore
        self.diagnosticStore = resolvedDiagnosticStore
        self.performanceMonitorStore = performanceMonitorStore ?? PerformanceMonitorStore()
        self.riskService = riskService

        resolvedSettingsStore.$demoMode
            .removeDuplicates()
            .sink { [weak resolvedDeviceStore] enabled in
                resolvedDeviceStore?.setDemoMode(enabled)
            }
            .store(in: &cancellables)

        resolvedSettingsStore.$retentionDays
            .removeDuplicates()
            .dropFirst()
            .sink { [weak resolvedDiagnosticStore] days in
                resolvedDiagnosticStore?.prune(retentionDays: days)
            }
            .store(in: &cancellables)
    }

    var effectiveBattery: BatteryInformation {
        mergeBattery(deviceStore.battery, diagnosticStore.latestBattery)
    }

    func overviewBattery(now: Date = Date()) -> BatteryOverviewSnapshot {
        BatteryOverviewResolver.resolve(
            staticBattery: effectiveBattery,
            liveSample: performanceMonitorStore.latestBattery,
            liveReceivedAt: performanceMonitorStore.latestBatteryReceivedAt,
            performanceState: performanceMonitorStore.state,
            now: now
        )
    }

    var effectiveStorage: StorageInformation {
        mergeStorage(deviceStore.storage, diagnosticStore.latestStorage)
    }

    var riskFindings: [RiskFinding] {
        riskService.analyze(
            device: deviceStore.primaryDevice,
            battery: effectiveBattery,
            storage: effectiveStorage,
            records: diagnosticStore.allRecords
        )
    }

    var highestRisk: RiskLevel {
        riskFindings.map(\.level).max() ?? .insufficient
    }

    func importDiagnostics(from url: URL) {
        diagnosticStore.importDiagnostics(
            from: url,
            keepCopy: settingsStore.keepImportedCopies,
            retentionDays: settingsStore.retentionDays
        )
    }

    private func mergeBattery(
        _ primary: BatteryInformation,
        _ fallback: BatteryInformation
    ) -> BatteryInformation {
        var result = primary
        if result.currentLevelPercent.value == nil,
           fallback.currentLevelPercent.value != nil {
            result.currentLevelPercent = fallback.currentLevelPercent
        }
        if result.isCharging.value == nil, fallback.isCharging.value != nil {
            result.isCharging = fallback.isCharging
        }
        if result.externalPowerConnected.value == nil,
           fallback.externalPowerConnected.value != nil {
            result.externalPowerConnected = fallback.externalPowerConnected
        }
        if result.healthPercent.value == nil, fallback.healthPercent.value != nil {
            result.healthPercent = fallback.healthPercent
        }
        if result.designCapacityMAh.value == nil,
           fallback.designCapacityMAh.value != nil {
            result.designCapacityMAh = fallback.designCapacityMAh
        }
        if result.maximumCapacityMAh.value == nil,
           fallback.maximumCapacityMAh.value != nil {
            result.maximumCapacityMAh = fallback.maximumCapacityMAh
        }
        if result.cycleCount.value == nil, fallback.cycleCount.value != nil {
            result.cycleCount = fallback.cycleCount
        }
        if result.verificationStatus.value == nil,
           fallback.verificationStatus.value != nil {
            result.verificationStatus = fallback.verificationStatus
        }
        if result.serialOrManufacturingInfo.value == nil,
           fallback.serialOrManufacturingInfo.value != nil {
            result.serialOrManufacturingInfo = fallback.serialOrManufacturingInfo
        }
        if result.chargingStatus.value == nil,
           fallback.chargingStatus.value != nil {
            result.chargingStatus = fallback.chargingStatus
        }
        result.latestLogDate = result.latestLogDate ?? fallback.latestLogDate
        return result
    }

    private func mergeStorage(
        _ primary: StorageInformation,
        _ fallback: StorageInformation
    ) -> StorageInformation {
        var result = primary
        if result.totalBytes.value == nil, fallback.totalBytes.value != nil {
            result.totalBytes = fallback.totalBytes
        }
        if result.availableBytes.value == nil,
           fallback.availableBytes.value != nil {
            result.availableBytes = fallback.availableBytes
        }
        if result.usedBytes.value == nil, fallback.usedBytes.value != nil {
            result.usedBytes = fallback.usedBytes
        }
        if result.reclaimableBytes.value == nil,
           fallback.reclaimableBytes.value != nil {
            result.reclaimableBytes = fallback.reclaimableBytes
        }
        if result.hardFreeBytes.value == nil,
           fallback.hardFreeBytes.value != nil {
            result.hardFreeBytes = fallback.hardFreeBytes
        }
        result.updatedAt = result.updatedAt ?? fallback.updatedAt
        return result
    }
}
