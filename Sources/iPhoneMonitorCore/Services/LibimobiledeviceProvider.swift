import Foundation

public struct LibimobiledeviceProvider: DeviceInformationProvider {
    public let name = "libimobiledevice"
    public let priority = 90
    public let isHeavyweight = false

    private let runner: CommandRunner
    private let locator: ToolLocator

    public init(
        runner: CommandRunner = CommandRunner(),
        locator: ToolLocator? = nil
    ) {
        self.runner = runner
        self.locator = locator ?? ToolLocator(runner: runner)
    }

    public func isAvailable() async -> Bool {
        let idPath = await locator.executable(named: "idevice_id")
        let infoPath = await locator.executable(named: "ideviceinfo")
        return idPath != nil && infoPath != nil
    }

    public func fetchDevices() async throws -> [ProviderDevice] {
        guard
            let idPath = await locator.executable(named: "idevice_id"),
            let infoPath = await locator.executable(named: "ideviceinfo")
        else {
            throw DeviceProviderError.toolUnavailable(name)
        }

        let idResult = await runner.run(
            executable: idPath,
            arguments: ["-l"],
            timeout: 5,
            maximumOutputBytes: 512 * 1_024
        )
        guard idResult.succeeded else {
            throw DeviceProviderError.commandFailed(
                provider: name,
                detail: idResult.conciseError
            )
        }

        var devices: [ProviderDevice] = []
        for identifier in idResult.output.split(whereSeparator: \.isNewline).map(String.init) {
            try Task.checkCancellation()
            let infoResult = await runner.run(
                executable: infoPath,
                arguments: ["-u", identifier],
                timeout: 6,
                maximumOutputBytes: 2 * 1_024 * 1_024
            )
            if infoResult.succeeded {
                devices.append(
                    LibimobiledeviceOutputParser.parse(
                        infoResult.output,
                        identifier: identifier
                    )
                )
            } else {
                let lower = infoResult.errorOutput.lowercased()
                let state: DeviceConnectionState = lower.contains("password")
                    ? .locked
                    : (lower.contains("pair") ? .untrusted : .readLimited)
                devices.append(
                    ProviderDevice(
                        identifier: identifier,
                        udid: identifier,
                        connectionType: "USB",
                        state: state,
                        statusDetail: infoResult.conciseError,
                        source: "libimobiledevice",
                        priority: 90
                    )
                )
            }
        }
        return devices
    }
}

public enum LibimobiledeviceOutputParser {
    public static func keyValues(from output: String) -> [String: String] {
        output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }
    }

    public static func parse(_ output: String, identifier: String) -> ProviderDevice {
        let values = keyValues(from: output)
        return ProviderDevice(
            identifier: identifier,
            name: values["DeviceName"],
            productType: values["ProductType"],
            marketingName: values["ProductType"].map(DeviceModelMapper.marketingName),
            systemVersion: values["ProductVersion"],
            buildVersion: values["BuildVersion"],
            serialNumber: values["SerialNumber"],
            udid: values["UniqueDeviceID"] ?? identifier,
            ecid: values["UniqueChipID"],
            architecture: values["CPUArchitecture"],
            connectionType: "USB",
            paired: true,
            passcodeProtected: parseBool(values["PasswordProtected"]),
            findMyEnabled: parseBool(values["FindMyiPhone"]),
            state: .readable,
            source: "libimobiledevice",
            priority: 90
        )
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }
}
