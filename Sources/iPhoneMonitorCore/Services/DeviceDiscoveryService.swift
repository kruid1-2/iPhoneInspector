import Foundation

public struct DeviceDiscoveryService: Sendable {
    private let providers: [any DeviceInformationProvider]

    public init(providers: [any DeviceInformationProvider]? = nil) {
        if let providers {
            self.providers = providers.sorted { $0.priority > $1.priority }
        } else {
            let runner = CommandRunner()
            let locator = ToolLocator(runner: runner)
            self.providers = [
                DevicectlProvider(runner: runner, locator: locator),
                LibimobiledeviceProvider(runner: runner, locator: locator),
                XCDeviceProvider(runner: runner),
                SystemProfilerProvider(runner: runner)
            ]
        }
    }

    public func discover(includeHeavyweightFallbacks: Bool) async -> DeviceDiscoveryResult {
        var snapshots: [ProviderDevice] = []
        var statuses: [DeviceProviderStatus] = []

        for provider in providers {
            if provider.isHeavyweight && !includeHeavyweightFallbacks {
                statuses.append(
                    DeviceProviderStatus(
                        name: provider.name,
                        available: await provider.isAvailable(),
                        succeeded: false,
                        detail: "轻量检测未运行"
                    )
                )
                continue
            }

            let available = await provider.isAvailable()
            guard available else {
                statuses.append(
                    DeviceProviderStatus(
                        name: provider.name,
                        available: false,
                        succeeded: false,
                        detail: "未安装或当前不可用"
                    )
                )
                continue
            }

            do {
                let result = try await provider.fetchDevices()
                snapshots.append(contentsOf: result)
                statuses.append(
                    DeviceProviderStatus(
                        name: provider.name,
                        available: true,
                        succeeded: true,
                        detail: result.isEmpty ? "未检测到 iPhone" : "读取到 \(result.count) 台设备"
                    )
                )

                if !includeHeavyweightFallbacks, !result.isEmpty {
                    break
                }
            } catch is CancellationError {
                break
            } catch {
                statuses.append(
                    DeviceProviderStatus(
                        name: provider.name,
                        available: true,
                        succeeded: false,
                        detail: error.localizedDescription
                    )
                )
            }
        }

        let devices = merge(snapshots)
        AppLogger.device.info(
            "Discovery completed devices=\(devices.count) providers=\(statuses.count)"
        )
        return DeviceDiscoveryResult(devices: devices, providers: statuses)
    }

    public func merge(_ snapshots: [ProviderDevice]) -> [ConnectedDevice] {
        var groups: [[ProviderDevice]] = []

        for snapshot in snapshots.sorted(by: { $0.priority > $1.priority }) {
            if let index = groups.firstIndex(where: { group in
                group.contains(where: { existing in
                    sameDevice(existing, snapshot)
                })
            }) {
                groups[index].append(snapshot)
            } else {
                groups.append([snapshot])
            }
        }

        return groups.compactMap(makeConnectedDevice)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func sameDevice(_ lhs: ProviderDevice, _ rhs: ProviderDevice) -> Bool {
        if lhs.identifier == rhs.identifier { return true }
        if let left = lhs.udid, let right = rhs.udid, left == right { return true }
        if let left = lhs.serialNumber, let right = rhs.serialNumber, left == right { return true }
        return lhs.name != nil
            && lhs.name == rhs.name
            && lhs.productType != nil
            && lhs.productType == rhs.productType
    }

    private func makeConnectedDevice(_ group: [ProviderDevice]) -> ConnectedDevice? {
        guard let best = group.max(by: { $0.priority < $1.priority }) else { return nil }
        let sorted = group.sorted { $0.priority > $1.priority }
        let timestamp = Date()

        func firstString(_ keyPath: KeyPath<ProviderDevice, String?>) -> DataValue<String> {
            for item in sorted {
                if let value = item[keyPath: keyPath], !value.isEmpty {
                    return .available(
                        value,
                        source: item.source,
                        confidence: item.priority >= 80 ? .high : .medium,
                        updatedAt: timestamp
                    )
                }
            }
            return .missing(.notReturned)
        }

        func firstBool(
            _ keyPath: KeyPath<ProviderDevice, Bool?>,
            missing: DataAvailability = .notReturned
        ) -> DataValue<Bool> {
            for item in sorted {
                if let value = item[keyPath: keyPath] {
                    return .available(
                        value,
                        source: item.source,
                        confidence: item.priority >= 80 ? .high : .medium,
                        updatedAt: timestamp
                    )
                }
            }
            return .missing(missing)
        }

        var info = DeviceInformation(
            name: firstString(\.name),
            productType: firstString(\.productType),
            marketingName: firstString(\.marketingName),
            systemVersion: firstString(\.systemVersion),
            buildVersion: firstString(\.buildVersion),
            serialNumber: firstString(\.serialNumber),
            udid: firstString(\.udid),
            ecid: firstString(\.ecid),
            architecture: firstString(\.architecture),
            paired: firstBool(\.paired),
            passcodeProtected: firstBool(\.passcodeProtected),
            findMyEnabled: firstBool(\.findMyEnabled, missing: .notSupported)
        )

        if info.marketingName.value == nil, let productType = info.productType.value {
            info.marketingName = .available(
                DeviceModelMapper.marketingName(for: productType),
                source: "内置机型映射",
                confidence: .medium,
                updatedAt: timestamp
            )
        }

        let state = sorted.map(\.state).max(by: {
            statePriority($0) < statePriority($1)
        }) ?? best.state

        return ConnectedDevice(
            id: best.udid ?? best.serialNumber ?? best.identifier,
            information: info,
            connectionType: sorted.compactMap(\.connectionType).first ?? "未知",
            connectionState: state,
            statusDetail: sorted.compactMap(\.statusDetail).first,
            sources: Array(Set(group.map(\.source))).sorted(),
            lastSuccessfulRead: timestamp
        )
    }

    private func statePriority(_ state: DeviceConnectionState) -> Int {
        switch state {
        case .readable: return 7
        case .locked: return 6
        case .untrusted: return 5
        case .readLimited: return 4
        case .connecting: return 3
        case .readFailed: return 2
        case .toolUnavailable: return 1
        case .disconnected: return 0
        }
    }
}
