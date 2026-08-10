import Foundation

public struct XCDeviceProvider: DeviceInformationProvider {
    public let name = "xcrun xcdevice"
    public let priority = 80
    public let isHeavyweight = false

    private let runner: CommandRunner

    public init(runner: CommandRunner = CommandRunner()) {
        self.runner = runner
    }

    public func isAvailable() async -> Bool {
        let result = await runner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--find", "xcdevice"],
            timeout: 4,
            maximumOutputBytes: 64 * 1_024
        )
        return result.succeeded
    }

    public func fetchDevices() async throws -> [ProviderDevice] {
        guard await isAvailable() else {
            throw DeviceProviderError.toolUnavailable(name)
        }
        let result = await runner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["xcdevice", "list", "--timeout=3"],
            timeout: 7,
            maximumOutputBytes: 4 * 1_024 * 1_024
        )
        guard result.succeeded else {
            throw DeviceProviderError.commandFailed(
                provider: name,
                detail: result.conciseError
            )
        }
        guard let data = result.output.data(using: .utf8) else {
            throw DeviceProviderError.invalidOutput(name)
        }
        return try XCDeviceOutputParser.parse(data: data)
    }
}

public enum XCDeviceOutputParser {
    public static func parse(data: Data) throws -> [ProviderDevice] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DeviceProviderError.invalidOutput("xcdevice")
        }

        return array.compactMap { raw in
            guard (raw["simulator"] as? Bool) != true else { return nil }
            let platform = (raw["platform"] as? String)?.lowercased() ?? ""
            let modelName = raw["modelName"] as? String
            guard platform.contains("iphoneos")
                    || modelName?.lowercased().contains("iphone") == true else {
                return nil
            }

            let identifier = raw["identifier"] as? String ?? UUID().uuidString
            let available = raw["available"] as? Bool ?? false
            let error = raw["error"] as? [String: Any]
            let detail = error?["description"] as? String
            let versionParts = splitOperatingSystemVersion(
                raw["operatingSystemVersion"] as? String
            )
            let loweredDetail = detail?.lowercased() ?? ""
            let state: DeviceConnectionState
            if available {
                state = .readable
            } else if loweredDetail.contains("locked") {
                state = .locked
            } else if loweredDetail.contains("trust") || loweredDetail.contains("pair") {
                state = .untrusted
            } else {
                state = .readLimited
            }

            return ProviderDevice(
                identifier: identifier,
                name: raw["name"] as? String,
                productType: raw["modelCode"] as? String,
                marketingName: modelName,
                systemVersion: versionParts.version,
                buildVersion: versionParts.build,
                udid: identifier,
                architecture: raw["architecture"] as? String,
                connectionType: raw["interface"] as? String,
                paired: available ? true : nil,
                state: state,
                statusDetail: detail,
                source: "xcdevice",
                priority: 80
            )
        }
    }

    private static func splitOperatingSystemVersion(
        _ value: String?
    ) -> (version: String?, build: String?) {
        guard let value else { return (nil, nil) }
        let pattern = #"^\s*(.+?)\s*\(([^()]+)\)\s*$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ),
            let versionRange = Range(match.range(at: 1), in: value),
            let buildRange = Range(match.range(at: 2), in: value)
        else { return (value, nil) }
        return (
            String(value[versionRange]),
            String(value[buildRange])
        )
    }
}
