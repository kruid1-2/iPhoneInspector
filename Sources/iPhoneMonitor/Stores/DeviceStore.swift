import Combine
import Foundation
import iPhoneMonitorCore

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var providerStatuses: [DeviceProviderStatus] = []
    @Published private(set) var battery = BatteryInformation()
    @Published private(set) var storage = StorageInformation()
    @Published private(set) var statusMessage = "等待首次设备检测…"
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var detailErrors: [String] = []

    private let discoveryService: DeviceDiscoveryService
    private let informationService: DeviceInformationService
    private var monitorTask: Task<Void, Never>?
    private var demoMode = false

    init(
        discoveryService: DeviceDiscoveryService = DeviceDiscoveryService(),
        informationService: DeviceInformationService = DeviceInformationService()
    ) {
        self.discoveryService = discoveryService
        self.informationService = informationService
    }

    var primaryDevice: ConnectedDevice? {
        devices.first(where: { $0.connectionState == .readable })
            ?? devices.first(where: { $0.connectionState != .disconnected })
            ?? devices.first
    }

    var hasActiveConnection: Bool {
        guard let device = primaryDevice else { return false }
        return !device.isDemoData && device.connectionState != .disconnected
            || device.isDemoData
    }

    func setDemoMode(_ enabled: Bool) {
        guard demoMode != enabled else { return }
        demoMode = enabled
        if enabled {
            devices = [DemoDataFactory.device]
            battery = DemoDataFactory.battery
            storage = DemoDataFactory.storage
            statusMessage = "演示模式：当前显示的不是设备实测数据"
            lastRefresh = Date()
        } else {
            devices = []
            battery = BatteryInformation()
            storage = StorageInformation()
            statusMessage = "演示模式已关闭，等待真实设备检测…"
            requestRefresh(detailed: true)
        }
    }

    func startMonitoring(settings: SettingsStore) {
        guard monitorTask == nil else { return }
        if settings.demoMode {
            setDemoMode(true)
        } else {
            requestRefresh(detailed: true)
        }
        monitorTask = Task { [weak self, weak settings] in
            while !Task.isCancelled {
                guard let self, let settings else { break }
                let seconds = max(3, settings.detectionInterval)
                try? await Task.sleep(
                    nanoseconds: UInt64(seconds * 1_000_000_000)
                )
                guard !Task.isCancelled else { break }
                if settings.autoDetection, !settings.demoMode {
                    await self.refresh(detailed: false)
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func requestRefresh(detailed: Bool = true) {
        Task { await refresh(detailed: detailed) }
    }

    func refresh(detailed: Bool) async {
        guard !isRefreshing, !demoMode else { return }
        isRefreshing = true
        statusMessage = "正在通过本地设备工具检查 iPhone…"
        defer { isRefreshing = false }

        let result = await discoveryService.discover(
            includeHeavyweightFallbacks: detailed
        )
        providerStatuses = result.providers
        lastRefresh = result.refreshedAt

        if !result.devices.isEmpty {
            devices = result.devices
            if let device = primaryDevice {
                statusMessage = "\(device.displayName) · \(device.connectionState.label)"
                AppLogger.device.info(
                    "Connected device \(AppLogger.maskedIdentifier(device.id), privacy: .public)"
                )
                if detailed, device.connectionState == .readable {
                    let details = await informationService.fetchDetails(for: device)
                    battery = reconciledBattery(
                        previous: battery,
                        refreshed: details.battery
                    )
                    storage = reconciledStorage(
                        previous: storage,
                        refreshed: details.storage
                    )
                    detailErrors = details.errors
                }
            }
            return
        }

        if !devices.isEmpty {
            devices = devices.map { existing in
                var stale = existing
                stale.markDisconnected()
                return stale
            }
            battery = battery.markedStale()
            storage = storage.markedStale()
            statusMessage = "iPhone 连接已中断；上次结果已标记为过期"
        } else {
            statusMessage = "未检测到通过 USB 连接的 iPhone"
        }

        let availableProviders = result.providers.filter(\.available)
        if availableProviders.isEmpty {
            statusMessage = "当前电脑没有可用的 iPhone 设备读取工具"
        } else if availableProviders.allSatisfy({ !$0.succeeded }) {
            statusMessage = "设备工具可用，但本次读取失败"
        }
    }

    private func reconciledBattery(
        previous: BatteryInformation,
        refreshed: BatteryInformation
    ) -> BatteryInformation {
        BatteryInformation(
            currentLevelPercent: reconcile(
                previous.currentLevelPercent,
                refreshed.currentLevelPercent
            ),
            isCharging: reconcile(previous.isCharging, refreshed.isCharging),
            externalPowerConnected: reconcile(
                previous.externalPowerConnected,
                refreshed.externalPowerConnected
            ),
            healthPercent: reconcile(
                previous.healthPercent,
                refreshed.healthPercent
            ),
            designCapacityMAh: reconcile(
                previous.designCapacityMAh,
                refreshed.designCapacityMAh
            ),
            maximumCapacityMAh: reconcile(
                previous.maximumCapacityMAh,
                refreshed.maximumCapacityMAh
            ),
            cycleCount: reconcile(previous.cycleCount, refreshed.cycleCount),
            serialOrManufacturingInfo: reconcile(
                previous.serialOrManufacturingInfo,
                refreshed.serialOrManufacturingInfo
            ),
            verificationStatus: reconcile(
                previous.verificationStatus,
                refreshed.verificationStatus
            ),
            chargingStatus: reconcile(
                previous.chargingStatus,
                refreshed.chargingStatus
            ),
            latestLogDate: refreshed.latestLogDate ?? previous.latestLogDate
        )
    }

    private func reconciledStorage(
        previous: StorageInformation,
        refreshed: StorageInformation
    ) -> StorageInformation {
        if refreshed.usageFraction != nil {
            return refreshed
        }
        if previous.usageFraction != nil {
            var stale = previous.markedStale()
            let detail = "本次刷新未取得同一容量口径的总量与可用量；保留上次完整结果"
            stale.totalBytes.detail = detail
            stale.availableBytes.detail = detail
            stale.usedBytes.detail = detail
            stale.hardFreeBytes = reconcile(
                previous.hardFreeBytes,
                refreshed.hardFreeBytes
            )
            return stale
        }
        return StorageInformation(
            totalBytes: reconcile(previous.totalBytes, refreshed.totalBytes),
            availableBytes: reconcile(
                previous.availableBytes,
                refreshed.availableBytes
            ),
            usedBytes: reconcile(previous.usedBytes, refreshed.usedBytes),
            reclaimableBytes: reconcile(
                previous.reclaimableBytes,
                refreshed.reclaimableBytes
            ),
            hardFreeBytes: reconcile(
                previous.hardFreeBytes,
                refreshed.hardFreeBytes
            ),
            updatedAt: refreshed.updatedAt ?? previous.updatedAt
        )
    }

    private func reconcile<Value>(
        _ previous: DataValue<Value>,
        _ refreshed: DataValue<Value>
    ) -> DataValue<Value> where Value: Codable & Hashable & Sendable {
        if refreshed.value != nil { return refreshed }
        guard previous.value != nil else { return refreshed }

        var stale = previous.markedStale()
        stale.detail = [
            "本次刷新未取得新值",
            refreshed.availability.message,
            refreshed.detail
        ].compactMap { $0 }.joined(separator: "；")
        return stale
    }
}
