import Foundation

public enum DeviceDetailOutputParser {
    private static let levelKeys = [
        "BatteryCurrentCapacity",
        "CurrentCapacity",
        "CurrentCapacityPercent",
        "BatteryLevel",
        "BatteryPercent",
        "PercentCharge"
    ]
    private static let chargingKeys = [
        "BatteryIsCharging",
        "IsCharging",
        "Charging"
    ]
    private static let externalPowerKeys = [
        "ExternalConnected",
        "ExternalPowerConnected",
        "ExternalChargeCapable"
    ]
    private static let healthKeys = [
        "BatteryHealthMetric",
        "MaximumCapacityPercent",
        "BatteryHealth",
        "MaxCapacityPercent"
    ]
    private static let designCapacityKeys = [
        "DesignCapacity",
        "BatteryDesignCapacity"
    ]
    private static let maximumCapacityKeys = [
        "FullChargeCapacity",
        "NominalChargeCapacity",
        "AppleRawMaxCapacity",
        "BatteryMaximumCapacity"
    ]
    private static let cycleKeys = [
        "CycleCount",
        "BatteryCycleCount"
    ]
    private static let chargingStatusKeys = [
        "ChargingStatus",
        "BatteryChargingStatus"
    ]
    private static let totalStorageKeys = [
        "TotalDataCapacity",
        "TotalDiskCapacity",
        "DiskCapacity",
        "TotalCapacity",
        "InternalStorageCapacity",
        "CapacityBytes"
    ]
    private static let availableStorageKeys = [
        "AmountDataAvailable",
        "AmountDiskAvailable",
        "AvailableDataCapacity",
        "AvailableDiskCapacity",
        "AvailableCapacity",
        "FreeDiskSpace",
        "FreeBytes"
    ]
    private static let storageFieldPairs: [([String], [String])] = [
        (
            ["TotalDataCapacity"],
            ["AmountDataAvailable", "AvailableDataCapacity"]
        ),
        (
            ["TotalDiskCapacity", "DiskCapacity"],
            [
                "AmountDiskAvailable",
                "AvailableDiskCapacity",
                "FreeDiskSpace"
            ]
        ),
        (
            ["TotalCapacity", "CapacityBytes"],
            ["AvailableCapacity", "FreeBytes"]
        )
    ]

    public static func parseDevicectl(data: Data) throws -> DeviceDetailResult {
        let object = try JSONSerialization.jsonObject(with: data)
        guard object is [String: Any] else {
            throw DeviceProviderError.invalidOutput("devicectl details")
        }
        let now = Date()

        let levelMatch = LocatedValue.first(in: object, aliases: levelKeys)
        let chargingMatch = LocatedValue.first(in: object, aliases: chargingKeys)
        let externalMatch = LocatedValue.first(in: object, aliases: externalPowerKeys)
        let storageMatches = storageMatches(in: object)

        let level = percentField(
            levelMatch,
            defaultSource: "devicectl",
            updatedAt: now
        )
        let charging = boolField(
            chargingMatch,
            defaultSource: "devicectl",
            updatedAt: now
        )
        let external = boolField(
            externalMatch,
            defaultSource: "devicectl",
            updatedAt: now
        )
        let chargingStatus: DataValue<String>
        if let chargingValue = charging.value {
            chargingStatus = .available(
                chargingValue ? "正在充电" : "未在充电",
                source: charging.source,
                rawFieldName: charging.rawFieldName,
                detail: "由原始充电布尔字段转换",
                updatedAt: now
            )
        } else {
            chargingStatus = .missing(
                charging.availability,
                source: charging.source,
                rawFieldName: charging.rawFieldName,
                detail: charging.detail
            )
        }

        return DeviceDetailResult(
            battery: BatteryInformation(
                currentLevelPercent: level,
                isCharging: charging,
                externalPowerConnected: external,
                healthPercent: .missing(
                    .notReturned,
                    source: "devicectl",
                    detail: "devicectl 详情没有返回电池健康度"
                ),
                designCapacityMAh: .missing(
                    .notReturned,
                    source: "devicectl",
                    detail: "devicectl 详情没有返回设计容量"
                ),
                maximumCapacityMAh: .missing(
                    .notReturned,
                    source: "devicectl",
                    detail: "devicectl 详情没有返回最大容量"
                ),
                cycleCount: .missing(
                    .notReturned,
                    source: "devicectl",
                    detail: "devicectl 详情没有返回循环次数"
                ),
                chargingStatus: chargingStatus
            ),
            storage: storage(
                totalMatch: storageMatches.total,
                availableMatch: storageMatches.available,
                defaultSource: "devicectl",
                updatedAt: now
            )
        )
    }

    public static func parseLibimobiledeviceXML(
        generalData: Data?,
        batteryData: Data?,
        storageData: Data?,
        generalFailure: DataAvailability? = nil,
        batteryFailure: DataAvailability? = nil,
        storageFailure: DataAvailability? = nil,
        generalFailureDetail: String? = nil,
        batteryFailureDetail: String? = nil,
        storageFailureDetail: String? = nil
    ) -> DeviceDetailResult {
        var errors: [String] = []

        let batterySource = "libimobiledevice / com.apple.mobile.battery"
        var battery: BatteryInformation
        if let batteryData {
            do {
                battery = try parseBatteryPropertyList(
                    data: batteryData,
                    source: batterySource
                )
            } catch {
                let detail = "电池 XML 解析失败：\(error.localizedDescription)"
                errors.append(detail)
                battery = missingBattery(
                    .parseFailed,
                    source: batterySource,
                    detail: detail
                )
            }
        } else {
            battery = missingBattery(
                batteryFailure ?? .notReturned,
                source: batterySource,
                detail: batteryFailureDetail
            )
        }

        let storageSource = "libimobiledevice / com.apple.disk_usage"
        var storageInfo: StorageInformation
        if let storageData {
            do {
                storageInfo = try parseStoragePropertyList(
                    data: storageData,
                    source: storageSource
                )
                if storageInfo.usedBytes.availability == .parseFailed,
                   let detail = storageInfo.usedBytes.detail {
                    errors.append(detail)
                }
            } catch {
                let detail = "存储 XML 解析失败：\(error.localizedDescription)"
                errors.append(detail)
                storageInfo = missingStorage(
                    .parseFailed,
                    source: storageSource,
                    detail: detail
                )
            }
        } else {
            storageInfo = missingStorage(
                storageFailure ?? .notReturned,
                source: storageSource,
                detail: storageFailureDetail
            )
        }

        if let generalData {
            do {
                let object = try propertyListObject(from: generalData)
                let generalSource = "libimobiledevice / general"
                let fallbackBattery = batteryInformation(
                    from: object,
                    source: generalSource,
                    updatedAt: Date()
                )
                let fallbackStorage = storageInformation(
                    from: object,
                    source: generalSource,
                    updatedAt: Date()
                )
                battery = mergeBattery(primary: battery, fallback: fallbackBattery)
                storageInfo = mergeStorage(
                    primary: storageInfo,
                    fallback: fallbackStorage
                )
            } catch {
                errors.append("通用 XML 解析失败：\(error.localizedDescription)")
            }
        } else if let generalFailure {
            let detail = generalFailureDetail ?? generalFailure.message
            errors.append("ideviceinfo 通用域：\(detail)")
        }

        return DeviceDetailResult(
            battery: battery,
            storage: storageInfo,
            errors: errors
        )
    }

    public static func parseBatteryPropertyList(
        data: Data,
        source: String = "libimobiledevice / com.apple.mobile.battery"
    ) throws -> BatteryInformation {
        let object = try propertyListObject(from: data)
        return batteryInformation(from: object, source: source, updatedAt: Date())
    }

    public static func parseStoragePropertyList(
        data: Data,
        source: String = "libimobiledevice / com.apple.disk_usage"
    ) throws -> StorageInformation {
        let object = try propertyListObject(from: data)
        return storageInformation(from: object, source: source, updatedAt: Date())
    }

    // Kept for deterministic legacy fixtures and older ideviceinfo builds that
    // return key/value text even when XML output is requested.
    public static func parseLibimobiledevice(
        batteryOutput: String,
        storageOutput: String
    ) -> DeviceDetailResult {
        if batteryOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("<?xml")
            || storageOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("<?xml") {
            return parseLibimobiledeviceXML(
                generalData: nil,
                batteryData: Data(batteryOutput.utf8),
                storageData: Data(storageOutput.utf8)
            )
        }

        let batteryObject = LibimobiledeviceOutputParser.keyValues(
            from: batteryOutput
        )
        let storageObject = LibimobiledeviceOutputParser.keyValues(
            from: storageOutput
        )
        return DeviceDetailResult(
            battery: batteryInformation(
                from: batteryObject,
                source: "libimobiledevice / com.apple.mobile.battery",
                updatedAt: Date()
            ),
            storage: storageInformation(
                from: storageObject,
                source: "libimobiledevice / com.apple.disk_usage",
                updatedAt: Date()
            )
        )
    }

    public static func missingBattery(
        _ availability: DataAvailability,
        source: String,
        detail: String? = nil
    ) -> BatteryInformation {
        BatteryInformation(
            currentLevelPercent: .missing(
                availability,
                source: source,
                detail: detail
            ),
            isCharging: .missing(
                availability,
                source: source,
                detail: detail
            ),
            externalPowerConnected: .missing(
                availability,
                source: source,
                detail: detail
            ),
            healthPercent: .missing(
                availability,
                source: source,
                detail: detail
            ),
            designCapacityMAh: .missing(
                availability,
                source: source,
                detail: detail
            ),
            maximumCapacityMAh: .missing(
                availability,
                source: source,
                detail: detail
            ),
            cycleCount: .missing(
                availability,
                source: source,
                detail: detail
            ),
            serialOrManufacturingInfo: .missing(
                availability,
                source: source,
                detail: detail
            ),
            verificationStatus: .missing(
                availability,
                source: source,
                detail: detail
            ),
            chargingStatus: .missing(
                availability,
                source: source,
                detail: detail
            )
        )
    }

    public static func missingStorage(
        _ availability: DataAvailability,
        source: String,
        detail: String? = nil
    ) -> StorageInformation {
        StorageInformation(
            totalBytes: .missing(
                availability,
                source: source,
                detail: detail
            ),
            availableBytes: .missing(
                availability,
                source: source,
                detail: detail
            ),
            usedBytes: .missing(
                availability,
                source: source,
                detail: detail
            ),
            reclaimableBytes: .missing(
                availability,
                source: source,
                detail: detail
            )
        )
    }

    private static func batteryInformation(
        from object: Any,
        source: String,
        updatedAt: Date
    ) -> BatteryInformation {
        let level = percentField(
            LocatedValue.first(in: object, aliases: levelKeys),
            defaultSource: source,
            updatedAt: updatedAt
        )
        let charging = boolField(
            LocatedValue.first(in: object, aliases: chargingKeys),
            defaultSource: source,
            updatedAt: updatedAt
        )
        let external = boolField(
            LocatedValue.first(in: object, aliases: externalPowerKeys),
            defaultSource: source,
            updatedAt: updatedAt
        )
        let health = integerField(
            LocatedValue.first(in: object, aliases: healthKeys),
            range: 0...100,
            defaultSource: source,
            updatedAt: updatedAt
        )
        let design = integerField(
            LocatedValue.first(in: object, aliases: designCapacityKeys),
            range: 1...100_000,
            defaultSource: source,
            updatedAt: updatedAt
        )
        let maximum = integerField(
            LocatedValue.first(in: object, aliases: maximumCapacityKeys),
            range: 1...100_000,
            defaultSource: source,
            updatedAt: updatedAt
        )
        let cycle = integerField(
            LocatedValue.first(in: object, aliases: cycleKeys),
            range: 0...100_000,
            defaultSource: source,
            updatedAt: updatedAt
        )

        let rawStatus = stringField(
            LocatedValue.first(in: object, aliases: chargingStatusKeys),
            defaultSource: source,
            updatedAt: updatedAt
        )
        let chargingStatus: DataValue<String>
        if rawStatus.value != nil {
            chargingStatus = rawStatus
        } else if let chargingValue = charging.value {
            chargingStatus = .available(
                chargingValue ? "正在充电" : "未在充电",
                source: charging.source,
                rawFieldName: charging.rawFieldName,
                detail: "由原始充电布尔字段转换",
                updatedAt: updatedAt
            )
        } else {
            chargingStatus = .missing(
                charging.availability,
                source: charging.source,
                rawFieldName: charging.rawFieldName,
                detail: charging.detail
            )
        }

        return BatteryInformation(
            currentLevelPercent: level,
            isCharging: charging,
            externalPowerConnected: external,
            healthPercent: health,
            designCapacityMAh: design,
            maximumCapacityMAh: maximum,
            cycleCount: cycle,
            serialOrManufacturingInfo: .missing(
                .notReturned,
                source: source,
                detail: "未读取或未保留电池序列敏感字段"
            ),
            verificationStatus: .missing(
                .notReturned,
                source: source,
                detail: "当前数据域没有返回可验证状态"
            ),
            chargingStatus: chargingStatus
        )
    }

    private static func storageInformation(
        from object: Any,
        source: String,
        updatedAt: Date
    ) -> StorageInformation {
        let matches = storageMatches(in: object)
        return storage(
            totalMatch: matches.total,
            availableMatch: matches.available,
            defaultSource: source,
            updatedAt: updatedAt
        )
    }

    private static func storageMatches(
        in object: Any
    ) -> (total: LocatedValue?, available: LocatedValue?) {
        for pair in storageFieldPairs {
            let total = LocatedValue.first(in: object, aliases: pair.0)
            let available = LocatedValue.first(in: object, aliases: pair.1)
            if total != nil, available != nil {
                return (total, available)
            }
        }
        return (
            LocatedValue.first(in: object, aliases: totalStorageKeys),
            LocatedValue.first(in: object, aliases: availableStorageKeys)
        )
    }

    private static func storage(
        totalMatch: LocatedValue?,
        availableMatch: LocatedValue?,
        defaultSource: String,
        updatedAt: Date
    ) -> StorageInformation {
        let total = capacityField(
            totalMatch,
            defaultSource: defaultSource,
            updatedAt: updatedAt
        )
        let available = capacityField(
            availableMatch,
            defaultSource: defaultSource,
            updatedAt: updatedAt
        )

        let used: DataValue<Int64>
        if let totalBytes = total.value, let availableBytes = available.value {
            guard total.source == available.source else {
                return StorageInformation(
                    totalBytes: total,
                    availableBytes: available,
                    usedBytes: .missing(
                        .parseFailed,
                        source: defaultSource,
                        detail: "总容量与可用容量来自不同数据域，未计算已使用容量"
                    ),
                    updatedAt: updatedAt
                )
            }
            guard storageFieldsAreCompatible(
                total: total.rawFieldName,
                available: available.rawFieldName
            ) else {
                return StorageInformation(
                    totalBytes: total,
                    availableBytes: available,
                    usedBytes: .missing(
                        .parseFailed,
                        source: defaultSource,
                        detail: "总容量与可用容量字段口径不同，未计算已使用容量"
                    ),
                    updatedAt: updatedAt
                )
            }
            guard totalBytes >= availableBytes else {
                return StorageInformation(
                    totalBytes: total,
                    availableBytes: available,
                    usedBytes: .missing(
                        .parseFailed,
                        source: total.source,
                        detail: "总容量小于可用容量，未计算已使用容量"
                    ),
                    updatedAt: updatedAt
                )
            }
            used = .available(
                totalBytes - availableBytes,
                source: total.source,
                rawFieldName: [
                    total.rawFieldName,
                    available.rawFieldName
                ].compactMap { $0 }.joined(separator: " - "),
                detail: "由同一数据域、统一为字节后的总容量减去可用容量",
                updatedAt: updatedAt
            )
        } else {
            let availability: DataAvailability
            if total.availability == .parseFailed
                || available.availability == .parseFailed {
                availability = .parseFailed
            } else if total.availability == .permissionDenied
                        || available.availability == .permissionDenied {
                availability = .permissionDenied
            } else if total.availability == .toolUnavailable
                        || available.availability == .toolUnavailable {
                availability = .toolUnavailable
            } else {
                availability = .notReturned
            }
            used = .missing(
                availability,
                source: defaultSource,
                detail: "必须同时取得同一数据域的总容量和可用容量才会计算"
            )
        }

        return StorageInformation(
            totalBytes: total,
            availableBytes: available,
            usedBytes: used,
            updatedAt: total.value != nil || available.value != nil
                ? updatedAt
                : nil
        )
    }

    private static func storageFieldsAreCompatible(
        total: String?,
        available: String?
    ) -> Bool {
        guard let total, let available else { return false }
        let totalName = normalize(total)
        let availableName = normalize(available)

        if totalName.contains("data") {
            return availableName.contains("data")
        }
        if totalName.contains("disk") {
            return availableName.contains("disk")
        }
        if totalName == "totalcapacity" || totalName == "capacitybytes" {
            return availableName == "availablecapacity"
                || availableName == "freebytes"
        }
        return false
    }

    private static func propertyListObject(from data: Data) throws -> Any {
        guard !data.isEmpty else {
            throw DeviceProviderError.invalidOutput("空 XML")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        return try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
    }

    private static func percentField(
        _ match: LocatedValue?,
        defaultSource: String,
        updatedAt: Date
    ) -> DataValue<Double> {
        guard let match else {
            return .missing(.notReturned, source: defaultSource)
        }
        guard let value = doubleValue(match.value), (0...100).contains(value) else {
            return .missing(
                .parseFailed,
                source: match.source(defaultSource: defaultSource),
                rawFieldName: match.rawFieldName,
                detail: "字段存在，但电量百分比类型或范围无效"
            )
        }
        return .available(
            value,
            source: match.source(defaultSource: defaultSource),
            rawFieldName: match.rawFieldName,
            updatedAt: updatedAt
        )
    }

    private static func boolField(
        _ match: LocatedValue?,
        defaultSource: String,
        updatedAt: Date
    ) -> DataValue<Bool> {
        guard let match else {
            return .missing(.notReturned, source: defaultSource)
        }
        guard let value = boolValue(match.value) else {
            return .missing(
                .parseFailed,
                source: match.source(defaultSource: defaultSource),
                rawFieldName: match.rawFieldName,
                detail: "字段存在，但布尔值类型无效"
            )
        }
        return .available(
            value,
            source: match.source(defaultSource: defaultSource),
            rawFieldName: match.rawFieldName,
            updatedAt: updatedAt
        )
    }

    private static func integerField(
        _ match: LocatedValue?,
        range: ClosedRange<Int>,
        defaultSource: String,
        updatedAt: Date
    ) -> DataValue<Int> {
        guard let match else {
            return .missing(.notReturned, source: defaultSource)
        }
        guard let value = integerValue(match.value), range.contains(value) else {
            return .missing(
                .parseFailed,
                source: match.source(defaultSource: defaultSource),
                rawFieldName: match.rawFieldName,
                detail: "字段存在，但数值类型或范围无效"
            )
        }
        return .available(
            value,
            source: match.source(defaultSource: defaultSource),
            rawFieldName: match.rawFieldName,
            confidence: .medium,
            updatedAt: updatedAt
        )
    }

    private static func stringField(
        _ match: LocatedValue?,
        defaultSource: String,
        updatedAt: Date
    ) -> DataValue<String> {
        guard let match else {
            return .missing(.notReturned, source: defaultSource)
        }
        let text: String?
        if let value = match.value as? String {
            text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let value = match.value as? NSNumber {
            text = value.stringValue
        } else {
            text = nil
        }
        guard let text, !text.isEmpty else {
            return .missing(
                .parseFailed,
                source: match.source(defaultSource: defaultSource),
                rawFieldName: match.rawFieldName,
                detail: "字段存在，但文本为空或类型无效"
            )
        }
        return .available(
            text,
            source: match.source(defaultSource: defaultSource),
            rawFieldName: match.rawFieldName,
            updatedAt: updatedAt
        )
    }

    private static func capacityField(
        _ match: LocatedValue?,
        defaultSource: String,
        updatedAt: Date
    ) -> DataValue<Int64> {
        guard let match else {
            return .missing(.notReturned, source: defaultSource)
        }
        guard let value = capacityBytes(match.value), value >= 0 else {
            return .missing(
                .parseFailed,
                source: match.source(defaultSource: defaultSource),
                rawFieldName: match.rawFieldName,
                detail: "字段存在，但容量单位、类型或数值无效"
            )
        }
        return .available(
            value,
            source: match.source(defaultSource: defaultSource),
            rawFieldName: match.rawFieldName,
            updatedAt: updatedAt
        )
    }

    private static func doubleValue(_ value: Any) -> Double? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(
                text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "%", with: "")
            )
        }
        return nil
    }

    private static func integerValue(_ value: Any) -> Int? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.rounded() == double else { return nil }
            return Int(exactly: number.int64Value)
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let integer = Int(trimmed) { return integer }
            if let double = Double(trimmed), double.rounded() == double {
                return Int(exactly: Int64(double))
            }
        }
        return nil
    }

    private static func boolValue(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber {
            if number.intValue == 1 { return true }
            if number.intValue == 0 { return false }
            return nil
        }
        guard let text = value as? String else { return nil }
        switch normalize(text) {
        case "true", "yes", "1", "charging", "connected":
            return true
        case "false", "no", "0", "notcharging", "disconnected":
            return false
        default:
            return nil
        }
    }

    private static func capacityBytes(_ value: Any) -> Int64? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        guard let text = value as? String else { return nil }
        return CapacityParser.bytes(
            from: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func mergeBattery(
        primary: BatteryInformation,
        fallback: BatteryInformation
    ) -> BatteryInformation {
        BatteryInformation(
            currentLevelPercent: prefer(primary.currentLevelPercent, fallback.currentLevelPercent),
            isCharging: prefer(primary.isCharging, fallback.isCharging),
            externalPowerConnected: prefer(
                primary.externalPowerConnected,
                fallback.externalPowerConnected
            ),
            healthPercent: prefer(primary.healthPercent, fallback.healthPercent),
            designCapacityMAh: prefer(
                primary.designCapacityMAh,
                fallback.designCapacityMAh
            ),
            maximumCapacityMAh: prefer(
                primary.maximumCapacityMAh,
                fallback.maximumCapacityMAh
            ),
            cycleCount: prefer(primary.cycleCount, fallback.cycleCount),
            serialOrManufacturingInfo: prefer(
                primary.serialOrManufacturingInfo,
                fallback.serialOrManufacturingInfo
            ),
            verificationStatus: prefer(
                primary.verificationStatus,
                fallback.verificationStatus
            ),
            chargingStatus: prefer(primary.chargingStatus, fallback.chargingStatus),
            latestLogDate: primary.latestLogDate ?? fallback.latestLogDate
        )
    }

    private static func mergeStorage(
        primary: StorageInformation,
        fallback: StorageInformation
    ) -> StorageInformation {
        if primary.totalBytes.value != nil || primary.availableBytes.value != nil {
            return primary
        }
        return fallback
    }

    private static func prefer<Value>(
        _ first: DataValue<Value>,
        _ second: DataValue<Value>
    ) -> DataValue<Value> where Value: Codable & Hashable & Sendable {
        first.value != nil ? first : second
    }

    fileprivate static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private struct LocatedValue {
    let rawFieldName: String
    let value: Any
    let path: [String]

    static func first(in object: Any, aliases: [String]) -> LocatedValue? {
        let values = all(in: object)
        for alias in aliases {
            let normalizedAlias = DeviceDetailOutputParser.normalize(alias)
            if let match = values.first(where: {
                DeviceDetailOutputParser.normalize($0.rawFieldName)
                    == normalizedAlias
            }) {
                return match
            }
        }
        return nil
    }

    func source(defaultSource: String) -> String {
        guard defaultSource == "devicectl" else { return defaultSource }
        let knownDomains = [
            "hardwareProperties",
            "deviceProperties",
            "connectionProperties"
        ]
        if let domain = path.first(where: knownDomains.contains) {
            return "devicectl / \(domain)"
        }
        return defaultSource
    }

    private static func all(
        in object: Any,
        path: [String] = []
    ) -> [LocatedValue] {
        if let dictionary = object as? [String: Any] {
            return dictionary.flatMap { key, value in
                let currentPath = path + [key]
                let current = LocatedValue(
                    rawFieldName: key,
                    value: value,
                    path: currentPath
                )
                if value is [String: Any] || value is [Any] {
                    return all(in: value, path: currentPath)
                }
                return [current]
            }
        }
        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in
                all(in: value, path: path + ["[\(index)]"])
            }
        }
        return []
    }
}
