import Foundation

public struct DevicectlProvider: DeviceInformationProvider {
    public let name = "xcrun devicectl"
    public let priority = 100
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
        await locator.executable(named: "devicectl") != nil
    }

    public func fetchDevices() async throws -> [ProviderDevice] {
        guard await isAvailable() else {
            throw DeviceProviderError.toolUnavailable(name)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-inspector-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = await runner.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "list", "devices",
                "--timeout", "4",
                "--json-output", outputURL.path
            ],
            timeout: 8,
            maximumOutputBytes: 2 * 1_024 * 1_024
        )

        let data = (try? Data(contentsOf: outputURL))
            ?? result.output.data(using: .utf8)
        if let data, !data.isEmpty,
           let devices = try? DevicectlOutputParser.parse(data: data) {
            if !devices.isEmpty || result.succeeded {
                return devices
            }
        }

        guard result.succeeded else {
            throw DeviceProviderError.commandFailed(
                provider: name,
                detail: result.conciseError
            )
        }
        throw DeviceProviderError.invalidOutput(name)
    }
}

public enum DevicectlOutputParser {
    public static func parse(data: Data) throws -> [ProviderDevice] {
        let object = try JSONSerialization.jsonObject(with: data)
        let candidates = deviceDictionaries(in: object)

        return candidates.compactMap { dictionary in
            let flattened = JSONLookup.flattenedText(dictionary).lowercased()
            let productType = JSONLookup.string(
                in: dictionary,
                keys: ["productType", "modelCode", "hardwareModel"]
            )
            let marketingName = JSONLookup.string(
                in: dictionary,
                keys: ["marketingName", "deviceType", "modelName"]
            )
            let platform = JSONLookup.string(
                in: dictionary,
                keys: ["platform", "osType", "deviceClass"]
            )?.lowercased()

            let looksLikeIPhone = productType?.lowercased().hasPrefix("iphone") == true
                || marketingName?.lowercased().contains("iphone") == true
                || platform?.contains("ios") == true
                || flattened.contains("iphone")
            guard looksLikeIPhone else { return nil }

            let identifier = JSONLookup.string(
                in: dictionary,
                keys: ["identifier", "udid", "uniqueDeviceIdentifier"]
            ) ?? UUID().uuidString
            let paired = JSONLookup.bool(
                in: dictionary,
                keys: ["paired", "isPaired", "pairingState"]
            )
            let state = connectionState(dictionary: dictionary, paired: paired)

            return ProviderDevice(
                identifier: identifier,
                name: JSONLookup.string(in: dictionary, keys: ["name", "deviceName"]),
                productType: productType,
                marketingName: marketingName,
                systemVersion: JSONLookup.string(
                    in: dictionary,
                    keys: ["osVersionNumber", "operatingSystemVersion", "productVersion"]
                ),
                buildVersion: JSONLookup.string(
                    in: dictionary,
                    keys: ["osBuildVersion", "buildVersion", "productBuildVersion"]
                ),
                serialNumber: JSONLookup.string(
                    in: dictionary,
                    keys: ["serialNumber", "deviceSerialNumber"]
                ),
                udid: JSONLookup.string(
                    in: dictionary,
                    keys: ["udid", "uniqueDeviceIdentifier"]
                ),
                ecid: JSONLookup.string(
                    in: dictionary,
                    keys: ["ecid", "uniqueChipID", "chipID"]
                ),
                architecture: JSONLookup.string(
                    in: dictionary,
                    keys: ["cpuArchitecture", "architecture"]
                ),
                connectionType: JSONLookup.string(
                    in: dictionary,
                    keys: ["transportType", "connectionType", "interface"]
                ),
                paired: paired,
                passcodeProtected: JSONLookup.bool(
                    in: dictionary,
                    keys: ["passwordProtected", "passcodeProtected"]
                ),
                findMyEnabled: JSONLookup.bool(
                    in: dictionary,
                    keys: ["findMyEnabled", "findMyiPhone"]
                ),
                state: state,
                statusDetail: statusDetail(dictionary),
                source: "devicectl",
                priority: 100
            )
        }
    }

    private static func deviceDictionaries(in object: Any) -> [[String: Any]] {
        if let root = object as? [String: Any],
           let result = root["result"] as? [String: Any],
           let devices = result["devices"] as? [[String: Any]] {
            return devices
        }
        if let root = object as? [String: Any],
           let devices = root["devices"] as? [[String: Any]] {
            return devices
        }
        if let array = object as? [[String: Any]] {
            return array
        }
        return JSONLookup.dictionaries(in: object).filter {
            JSONLookup.firstValue(in: $0, keys: ["identifier", "udid"]) != nil
        }
    }

    private static func connectionState(
        dictionary: [String: Any],
        paired: Bool?
    ) -> DeviceConnectionState {
        let text = JSONLookup.flattenedText(dictionary).lowercased()
        if text.contains("untrusted")
            || text.contains("not trusted")
            || text.contains("unpaired")
            || paired == false {
            return .untrusted
        }
        if text.contains("locked") || text.contains("unlock device") {
            return .locked
        }
        if text.contains("unavailable") || text.contains("disconnected") {
            return .disconnected
        }
        if paired == true || text.contains("available") {
            return .readable
        }
        return .readLimited
    }

    private static func statusDetail(_ dictionary: [String: Any]) -> String? {
        JSONLookup.string(
            in: dictionary,
            keys: ["errorDescription", "statusDescription", "visibilityClass"]
        )
    }
}
