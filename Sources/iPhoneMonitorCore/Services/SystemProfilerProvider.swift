import Foundation

public struct SystemProfilerProvider: DeviceInformationProvider {
    public let name = "system_profiler"
    public let priority = 30
    public let isHeavyweight = true

    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public func isAvailable() async -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/system_profiler")
    }

    public func fetchDevices() async throws -> [ProviderDevice] {
        let result = await runner.run(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPUSBDataType", "-json", "-detailLevel", "mini"],
            timeout: 12,
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        guard result.succeeded, let data = result.output.data(using: .utf8) else {
            throw DeviceProviderError.commandFailed(
                provider: name,
                detail: result.conciseError
            )
        }
        return try SystemProfilerOutputParser.parse(data: data)
    }
}

public enum SystemProfilerOutputParser {
    public static func parse(data: Data) throws -> [ProviderDevice] {
        let object = try JSONSerialization.jsonObject(with: data)
        return JSONLookup.dictionaries(in: object).compactMap { raw in
            let name = (raw["_name"] as? String) ?? (raw["device_name"] as? String)
            guard name?.lowercased().contains("iphone") == true else { return nil }
            let serial = (raw["serial_num"] as? String)
                ?? (raw["serial_number"] as? String)
            return ProviderDevice(
                identifier: serial ?? "usb-\(name ?? "iphone")",
                name: name,
                serialNumber: serial,
                connectionType: "USB",
                state: .readLimited,
                statusDetail: "system_profiler 仅确认 USB 连接，暂未获取到配对状态。",
                source: "system_profiler",
                priority: 30
            )
        }
    }
}
