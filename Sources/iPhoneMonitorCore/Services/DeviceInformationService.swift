import Foundation

public struct DeviceDetailResult: Codable, Hashable, Sendable {
    public var battery: BatteryInformation
    public var storage: StorageInformation
    public var errors: [String]

    public init(
        battery: BatteryInformation = BatteryInformation(),
        storage: StorageInformation = StorageInformation(),
        errors: [String] = []
    ) {
        self.battery = battery
        self.storage = storage
        self.errors = errors
    }
}

public struct DeviceInformationService: Sendable {
    private let runner: CommandRunner
    private let locator: ToolLocator

    public init(
        runner: CommandRunner = CommandRunner(),
        locator: ToolLocator? = nil
    ) {
        self.runner = runner
        self.locator = locator ?? ToolLocator(runner: runner)
    }

    public func fetchDetails(for device: ConnectedDevice) async -> DeviceDetailResult {
        guard !device.isDemoData else {
            return DeviceDetailResult(
                battery: DemoDataFactory.battery,
                storage: DemoDataFactory.storage
            )
        }
        guard device.connectionState == .readable else {
            let detail = "设备未处于可读状态；请解锁 iPhone 并确认“信任此电脑”。"
            return DeviceDetailResult(
                battery: DeviceDetailOutputParser.missingBattery(
                    .permissionDenied,
                    source: "实时 USB 连接",
                    detail: detail
                ),
                storage: DeviceDetailOutputParser.missingStorage(
                    .permissionDenied,
                    source: "实时 USB 连接",
                    detail: detail
                ),
                errors: [detail]
            )
        }

        var results: [DeviceDetailResult] = []
        let hasDevicectl = await locator.executable(named: "devicectl") != nil
        if hasDevicectl {
            results.append(await fetchDevicectlDetails(deviceID: device.id))
        }

        if let infoPath = await locator.executable(named: "ideviceinfo") {
            let libimobiledeviceID = device.information.udid.value ?? device.id
            AppLogger.device.info(
                "Using libimobiledevice identifier \(AppLogger.maskedIdentifier(libimobiledeviceID), privacy: .public)"
            )
            results.append(
                await fetchLibimobiledeviceDetails(
                    executable: infoPath,
                    deviceID: libimobiledeviceID
                )
            )
        } else {
            let detail = "未安装 ideviceinfo；不会自动安装任何第三方读取工具。"
            results.append(
                DeviceDetailResult(
                    battery: DeviceDetailOutputParser.missingBattery(
                        .toolUnavailable,
                        source: "libimobiledevice / com.apple.mobile.battery",
                        detail: detail
                    ),
                    storage: DeviceDetailOutputParser.missingStorage(
                        .toolUnavailable,
                        source: "libimobiledevice / com.apple.disk_usage",
                        detail: detail
                    ),
                    errors: [detail]
                )
            )
        }

        guard !results.isEmpty else {
            let detail = "当前电脑没有可用于读取设备详情的本地工具。"
            return DeviceDetailResult(
                battery: DeviceDetailOutputParser.missingBattery(
                    .toolUnavailable,
                    source: "实时设备连接",
                    detail: detail
                ),
                storage: DeviceDetailOutputParser.missingStorage(
                    .toolUnavailable,
                    source: "实时设备连接",
                    detail: detail
                ),
                errors: [detail]
            )
        }
        let merged = merge(results)
        AppLogger.device.info(
            "Live detail summary batteryLevel=\(summary(merged.battery.currentLevelPercent), privacy: .public) charging=\(summary(merged.battery.isCharging), privacy: .public) storageTotal=\(summary(merged.storage.totalBytes), privacy: .public) storageAvailable=\(summary(merged.storage.availableBytes), privacy: .public)"
        )
        return merged
    }

    private func fetchDevicectlDetails(deviceID: String) async -> DeviceDetailResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-inspector-details-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            let detail = "无法建立受保护的临时目录：\(error.localizedDescription)"
            return DeviceDetailResult(
                battery: DeviceDetailOutputParser.missingBattery(
                    .unavailable,
                    source: "devicectl",
                    detail: detail
                ),
                storage: DeviceDetailOutputParser.missingStorage(
                    .unavailable,
                    source: "devicectl",
                    detail: detail
                ),
                errors: [detail]
            )
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("details.json")
        let result = await runner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "info", "details",
                "--device", deviceID,
                "--timeout", "20",
                "--json-output", outputURL.path
            ],
            timeout: 25,
            maximumOutputBytes: 4 * 1_024 * 1_024
        )
        logProbe(
            command: "xcrun devicectl device info details --device <redacted>",
            result: result
        )

        let data = (try? Data(contentsOf: outputURL))
            ?? result.output.data(using: .utf8)
        if let data, !data.isEmpty {
            do {
                var parsed = try DeviceDetailOutputParser.parseDevicectl(data: data)
                if !result.succeeded {
                    let detail = safeFailureDetail(result)
                    parsed.errors.append("devicectl：\(detail)")
                }
                return parsed
            } catch {
                let detail = "devicectl 返回 JSON 解析失败：\(error.localizedDescription)"
                AppLogger.command.error("\(detail, privacy: .public)")
                return DeviceDetailResult(
                    battery: DeviceDetailOutputParser.missingBattery(
                        .parseFailed,
                        source: "devicectl",
                        detail: detail
                    ),
                    storage: DeviceDetailOutputParser.missingStorage(
                        .parseFailed,
                        source: "devicectl",
                        detail: detail
                    ),
                    errors: [detail]
                )
            }
        }

        let availability = availability(for: result)
        let detail = safeFailureDetail(result)
        return DeviceDetailResult(
            battery: DeviceDetailOutputParser.missingBattery(
                availability,
                source: "devicectl",
                detail: detail
            ),
            storage: DeviceDetailOutputParser.missingStorage(
                availability,
                source: "devicectl",
                detail: detail
            ),
            errors: ["devicectl：\(detail)"]
        )
    }

    private func fetchLibimobiledeviceDetails(
        executable: String,
        deviceID: String
    ) async -> DeviceDetailResult {
        async let generalResult = runner.run(
            executable: executable,
            arguments: ["-u", deviceID, "-x"],
            timeout: 8,
            maximumOutputBytes: 2 * 1_024 * 1_024
        )
        async let batteryResult = runner.run(
            executable: executable,
            arguments: [
                "-u", deviceID,
                "-q", "com.apple.mobile.battery",
                "-x"
            ],
            timeout: 8,
            maximumOutputBytes: 1 * 1_024 * 1_024
        )
        async let storageResult = runner.run(
            executable: executable,
            arguments: [
                "-u", deviceID,
                "-q", "com.apple.disk_usage",
                "-x"
            ],
            timeout: 8,
            maximumOutputBytes: 1 * 1_024 * 1_024
        )
        let commands = await (generalResult, batteryResult, storageResult)

        let generalData = commands.0.succeeded
            ? commands.0.output.data(using: .utf8)
            : nil
        let batteryData = commands.1.succeeded
            ? commands.1.output.data(using: .utf8)
            : nil
        let storageData = commands.2.succeeded
            ? commands.2.output.data(using: .utf8)
            : nil

        var errors: [String] = []
        for (label, result) in [
            ("ideviceinfo -u <redacted> -x", commands.0),
            (
                "ideviceinfo -u <redacted> -q com.apple.mobile.battery -x",
                commands.1
            ),
            (
                "ideviceinfo -u <redacted> -q com.apple.disk_usage -x",
                commands.2
            )
        ] {
            logProbe(command: label, result: result)
            if !result.succeeded {
                let detail = safeFailureDetail(result)
                errors.append("\(label)：\(detail)")
            }
        }

        var parsed = DeviceDetailOutputParser.parseLibimobiledeviceXML(
            generalData: generalData,
            batteryData: batteryData,
            storageData: storageData,
            generalFailure: commands.0.succeeded ? nil : availability(for: commands.0),
            batteryFailure: commands.1.succeeded ? nil : availability(for: commands.1),
            storageFailure: commands.2.succeeded ? nil : availability(for: commands.2),
            generalFailureDetail: commands.0.succeeded ? nil : safeFailureDetail(commands.0),
            batteryFailureDetail: commands.1.succeeded ? nil : safeFailureDetail(commands.1),
            storageFailureDetail: commands.2.succeeded ? nil : safeFailureDetail(commands.2)
        )
        parsed.errors.append(contentsOf: errors)
        return parsed
    }

    func merge(_ results: [DeviceDetailResult]) -> DeviceDetailResult {
        guard var merged = results.first else { return DeviceDetailResult() }

        for next in results.dropFirst() {
            merged.battery.currentLevelPercent = preferred(
                merged.battery.currentLevelPercent,
                next.battery.currentLevelPercent
            )
            merged.battery.isCharging = preferred(
                merged.battery.isCharging,
                next.battery.isCharging
            )
            merged.battery.externalPowerConnected = preferred(
                merged.battery.externalPowerConnected,
                next.battery.externalPowerConnected
            )
            merged.battery.healthPercent = preferred(
                merged.battery.healthPercent,
                next.battery.healthPercent
            )
            merged.battery.designCapacityMAh = preferred(
                merged.battery.designCapacityMAh,
                next.battery.designCapacityMAh
            )
            merged.battery.maximumCapacityMAh = preferred(
                merged.battery.maximumCapacityMAh,
                next.battery.maximumCapacityMAh
            )
            merged.battery.cycleCount = preferred(
                merged.battery.cycleCount,
                next.battery.cycleCount
            )
            merged.battery.serialOrManufacturingInfo = preferred(
                merged.battery.serialOrManufacturingInfo,
                next.battery.serialOrManufacturingInfo
            )
            merged.battery.verificationStatus = preferred(
                merged.battery.verificationStatus,
                next.battery.verificationStatus
            )
            merged.battery.chargingStatus = preferred(
                merged.battery.chargingStatus,
                next.battery.chargingStatus
            )
            merged.storage = preferredStorage(merged.storage, next.storage)
            merged.errors.append(contentsOf: next.errors)
        }
        return merged
    }

    private func preferredStorage(
        _ first: StorageInformation,
        _ second: StorageInformation
    ) -> StorageInformation {
        storageScore(second) > storageScore(first) ? second : first
    }

    private func storageScore(_ storage: StorageInformation) -> Int {
        let valueCount = [
            storage.totalBytes.value,
            storage.availableBytes.value,
            storage.usedBytes.value,
            storage.reclaimableBytes.value,
            storage.hardFreeBytes.value
        ].compactMap { $0 }.count
        return valueCount + (storage.usageFraction == nil ? 0 : 100)
    }

    private func preferred<Value>(
        _ first: DataValue<Value>,
        _ second: DataValue<Value>
    ) -> DataValue<Value> where Value: Codable & Hashable & Sendable {
        if first.value != nil { return first }
        if second.value != nil { return second }
        return availabilityPriority(second.availability)
            > availabilityPriority(first.availability)
            ? second
            : first
    }

    private func availabilityPriority(_ availability: DataAvailability) -> Int {
        switch availability {
        case .available: return 100
        case .permissionDenied: return 90
        case .parseFailed: return 80
        case .unavailable: return 70
        case .toolUnavailable: return 60
        case .notReturned: return 50
        case .unsupportedConnection: return 40
        case .notSupported: return 30
        case .requiresDiagnosticLog: return 20
        case .stale: return 10
        case .demo: return 0
        }
    }

    private func availability(for result: CommandResult) -> DataAvailability {
        let text = "\(result.errorOutput) \(result.output)".lowercased()
        if text.contains("trust")
            || text.contains("pair")
            || text.contains("locked")
            || text.contains("unlock")
            || text.contains("password protected") {
            return .permissionDenied
        }
        return .unavailable
    }

    private func safeFailureDetail(_ result: CommandResult) -> String {
        AppLogger.redactedDiagnostic(result.conciseError)
    }

    private func logProbe(command: String, result: CommandResult) {
        let stderr = safeFailureDetail(result)
        if result.succeeded {
            AppLogger.command.info(
                "\(command, privacy: .public) finished code=\(result.exitCode) duration=\(result.duration, format: .fixed(precision: 2))s"
            )
        } else {
            AppLogger.command.error(
                "\(command, privacy: .public) failed code=\(result.exitCode) stderr=\(stderr, privacy: .public)"
            )
        }
    }

    private func summary<Value>(_ field: DataValue<Value>) -> String {
        if let value = field.value {
            return "\(value) [\(field.source); \(field.rawFieldName ?? "no-raw-key")]"
        }
        return "\(field.availability.rawValue) [\(field.source)]"
    }
}
