import Foundation

public enum DemoDataFactory {
    public static var device: ConnectedDevice {
        let now = Date()
        let source = "演示数据"
        return ConnectedDevice(
            id: "DEMO-IPHONE",
            information: DeviceInformation(
                name: .available("演示 iPhone", source: source, confidence: .high, updatedAt: now),
                productType: .available("iPhone14,4", source: source, confidence: .high, updatedAt: now),
                marketingName: .available("iPhone 13 mini", source: source, confidence: .high, updatedAt: now),
                systemVersion: .available("26.5.2", source: source, confidence: .high, updatedAt: now),
                buildVersion: .available("演示 Build", source: source, confidence: .high, updatedAt: now),
                serialNumber: .available("DEMO00000001", source: source, confidence: .high, updatedAt: now),
                udid: .available("DEMO-UDID-0000-0000", source: source, confidence: .high, updatedAt: now),
                paired: .available(true, source: source, confidence: .high, updatedAt: now),
                passcodeProtected: .available(true, source: source, confidence: .high, updatedAt: now)
            ),
            connectionType: "USB",
            connectionState: .readable,
            statusDetail: "这些数值仅用于预览界面，不代表真实设备。",
            sources: [source],
            lastSuccessfulRead: now,
            isDemoData: true
        )
    }

    public static var battery: BatteryInformation {
        let source = "演示数据"
        return BatteryInformation(
            currentLevelPercent: .available(61, source: source),
            isCharging: .available(false, source: source),
            externalPowerConnected: .available(false, source: source),
            healthPercent: .available(86, source: source),
            designCapacityMAh: .available(2_406, source: source),
            maximumCapacityMAh: .available(2_069, source: source),
            cycleCount: .available(612, source: source),
            verificationStatus: .available("演示：状态未知", source: source),
            chargingStatus: .available("未在充电", source: source)
        )
    }

    public static var storage: StorageInformation {
        let source = "演示数据"
        let total = Int64(128 * 1_024 * 1_024 * 1_024)
        let available = Int64(11 * 1_024 * 1_024 * 1_024)
        return StorageInformation(
            totalBytes: .available(total, source: source),
            availableBytes: .available(available, source: source),
            usedBytes: .available(total - available, source: source),
            updatedAt: Date()
        )
    }
}
