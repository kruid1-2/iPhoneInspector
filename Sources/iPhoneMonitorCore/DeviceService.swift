import Foundation

public enum DeviceServiceError: LocalizedError {
    case commandFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "无法读取苹果设备列表。" : detail
        case .invalidResponse:
            return "苹果设备工具返回了无法识别的数据。"
        }
    }
}

public struct DeviceService: Sendable {
    public init() {}

    public func fetchDevices() async throws -> [DeviceInfo] {
        let result = await ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["xcdevice", "list", "--timeout=3"],
            timeout: 8
        )

        if result.timedOut {
            throw DeviceServiceError.commandFailed("读取设备超时，请检查数据线和手机解锁状态。")
        }

        guard let data = result.output.data(using: .utf8), !data.isEmpty else {
            throw DeviceServiceError.commandFailed(result.errorOutput)
        }

        let decoder = JSONDecoder()
        guard let rawDevices = try? decoder.decode([RawDevice].self, from: data) else {
            throw DeviceServiceError.invalidResponse
        }

        return rawDevices
            .filter { raw in
                guard raw.simulator != true else { return false }
                let platform = raw.platform?.lowercased() ?? ""
                let model = raw.modelName?.lowercased() ?? ""
                return platform.contains("iphoneos") || model.contains("iphone")
            }
            .map { raw in
                DeviceInfo(
                    identifier: raw.identifier ?? UUID().uuidString,
                    name: raw.name ?? "iPhone",
                    modelName: raw.modelName ?? "iPhone",
                    modelCode: raw.modelCode ?? "未知",
                    operatingSystemVersion: raw.operatingSystemVersion ?? "未知",
                    interface: raw.interface ?? "未知",
                    available: raw.available ?? false,
                    statusDetail: raw.error?.description
                )
            }
            .sorted {
                if $0.available != $1.available { return $0.available }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}

private struct RawDevice: Decodable {
    let simulator: Bool?
    let modelName: String?
    let modelCode: String?
    let operatingSystemVersion: String?
    let identifier: String?
    let platform: String?
    let interface: String?
    let available: Bool?
    let name: String?
    let error: RawDeviceError?
}

private struct RawDeviceError: Decodable {
    let description: String?
}
