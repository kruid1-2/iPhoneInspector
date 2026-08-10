import XCTest
@testable import iPhoneMonitorCore

final class LiveDeviceDetailParserTests: XCTestCase {
    func testDevicectlReadsRealInternalStorageCapacityField() throws {
        let json = """
        {
          "result": {
            "deviceProperties": {
              "osVersionNumber": "26.6"
            },
            "hardwareProperties": {
              "internalStorageCapacity": 128000000000,
              "productType": "iPhone14,4"
            }
          }
        }
        """

        let result = try DeviceDetailOutputParser.parseDevicectl(
            data: Data(json.utf8)
        )

        XCTAssertEqual(result.storage.totalBytes.value, 128_000_000_000)
        XCTAssertEqual(
            result.storage.totalBytes.rawFieldName,
            "internalStorageCapacity"
        )
        XCTAssertEqual(
            result.storage.totalBytes.source,
            "devicectl / hardwareProperties"
        )
        XCTAssertNil(result.storage.availableBytes.value)
        XCTAssertEqual(result.storage.availableBytes.availability, .notReturned)
        XCTAssertNil(result.storage.usedBytes.value)
    }

    func testBatteryXMLSupportsAliasesAndPreservesRawFieldNames() throws {
        let xml = plist([
            "CurrentCapacityPercent": "<integer>57</integer>",
            "IsCharging": "<true/>",
            "ExternalPowerConnected": "<true/>",
            "MaximumCapacityPercent": "<integer>86</integer>",
            "BatteryDesignCapacity": "<integer>2406</integer>",
            "FullChargeCapacity": "<integer>2069</integer>",
            "BatteryCycleCount": "<integer>612</integer>"
        ])

        let battery = try DeviceDetailOutputParser.parseBatteryPropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertEqual(battery.currentLevelPercent.value, 57)
        XCTAssertEqual(
            battery.currentLevelPercent.rawFieldName,
            "CurrentCapacityPercent"
        )
        XCTAssertEqual(battery.isCharging.value, true)
        XCTAssertEqual(battery.externalPowerConnected.value, true)
        XCTAssertEqual(battery.healthPercent.value, 86)
        XCTAssertEqual(battery.designCapacityMAh.value, 2_406)
        XCTAssertEqual(battery.maximumCapacityMAh.value, 2_069)
        XCTAssertEqual(battery.cycleCount.value, 612)
    }

    func testThirdPartyBatteryMissingDeepFieldsDoesNotFailParsing() throws {
        let xml = plist([
            "BatteryCurrentCapacity": "<integer>41</integer>",
            "BatteryIsCharging": "<false/>"
        ])

        let battery = try DeviceDetailOutputParser.parseBatteryPropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertEqual(battery.currentLevelPercent.value, 41)
        XCTAssertEqual(battery.isCharging.value, false)
        XCTAssertEqual(battery.healthPercent.availability, .notReturned)
        XCTAssertEqual(battery.cycleCount.availability, .notReturned)
        XCTAssertNil(battery.maximumCapacityMAh.value)
    }

    func testIOS26BatteryFieldsPreferConnectionStateOverCapability() throws {
        let xml = plist([
            "BatteryCurrentCapacity": "<integer>63</integer>",
            "BatteryIsCharging": "<true/>",
            "ExternalChargeCapable": "<true/>",
            "ExternalConnected": "<false/>",
            "FullyCharged": "<false/>",
            "GasGaugeCapability": "<true/>",
            "HasBattery": "<true/>"
        ])

        let battery = try DeviceDetailOutputParser.parseBatteryPropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertEqual(battery.currentLevelPercent.value, 63)
        XCTAssertEqual(battery.currentLevelPercent.rawFieldName, "BatteryCurrentCapacity")
        XCTAssertEqual(battery.isCharging.value, true)
        XCTAssertEqual(battery.externalPowerConnected.value, false)
        XCTAssertEqual(battery.externalPowerConnected.rawFieldName, "ExternalConnected")
        XCTAssertEqual(battery.chargingStatus.value, "正在充电")
        XCTAssertEqual(battery.healthPercent.availability, .notReturned)
        XCTAssertEqual(battery.cycleCount.availability, .notReturned)
    }

    func testBatteryInvalidTypesAreMarkedAsParseFailures() throws {
        let xml = plist([
            "BatteryCurrentCapacity": "<string>unknown</string>",
            "CycleCount": "<string>many</string>"
        ])

        let battery = try DeviceDetailOutputParser.parseBatteryPropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertEqual(battery.currentLevelPercent.availability, .parseFailed)
        XCTAssertEqual(battery.cycleCount.availability, .parseFailed)
    }

    func testMalformedXMLIsReportedWithoutCrashing() {
        let result = DeviceDetailOutputParser.parseLibimobiledeviceXML(
            generalData: nil,
            batteryData: Data("<plist><dict>".utf8),
            storageData: Data("<not-a-plist/>".utf8)
        )

        XCTAssertEqual(result.battery.currentLevelPercent.availability, .parseFailed)
        XCTAssertEqual(result.storage.totalBytes.availability, .parseFailed)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testStorageXMLComputesOnlyValidatedSameDomainValues() throws {
        let xml = plist([
            "TotalDataCapacity": "<integer>128000000000</integer>",
            "AmountDataAvailable": "<integer>12000000000</integer>"
        ])

        let storage = try DeviceDetailOutputParser.parseStoragePropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertEqual(storage.totalBytes.value, 128_000_000_000)
        XCTAssertEqual(storage.availableBytes.value, 12_000_000_000)
        XCTAssertEqual(storage.usedBytes.value, 116_000_000_000)
        XCTAssertEqual(
            try XCTUnwrap(storage.usageFraction),
            0.90625,
            accuracy: 0.00001
        )
        XCTAssertEqual(
            storage.usedBytes.rawFieldName,
            "TotalDataCapacity - AmountDataAvailable"
        )
    }

    func testIOS26StoragePrefersDataCapacityPairOverPhysicalDiskCapacity() throws {
        let xml = plist([
            "AmountDataAvailable": "<integer>18514563072</integer>",
            "AmountDataReserved": "<integer>209715200</integer>",
            "AmountRestoreAvailable": "<integer>26498916352</integer>",
            "TotalDataAvailable": "<integer>81908506624</integer>",
            "TotalDataCapacity": "<integer>120092147712</integer>",
            "TotalDiskCapacity": "<integer>128000000000</integer>",
            "TotalSystemAvailable": "<integer>0</integer>",
            "TotalSystemCapacity": "<integer>7774638080</integer>"
        ])

        let storage = try DeviceDetailOutputParser.parseStoragePropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertEqual(storage.totalBytes.value, 120_092_147_712)
        XCTAssertEqual(storage.totalBytes.rawFieldName, "TotalDataCapacity")
        XCTAssertEqual(storage.availableBytes.value, 18_514_563_072)
        XCTAssertEqual(storage.availableBytes.rawFieldName, "AmountDataAvailable")
        XCTAssertEqual(storage.usedBytes.value, 101_577_584_640)
        XCTAssertEqual(
            try XCTUnwrap(storage.usageFraction),
            0.8458302549,
            accuracy: 0.000001
        )
    }

    func testStorageDoesNotCalculateAcrossDataAndDiskCapacityFamilies() throws {
        let xml = plist([
            "TotalDiskCapacity": "<integer>128000000000</integer>",
            "AmountDataAvailable": "<integer>18514563072</integer>"
        ])

        let storage = try DeviceDetailOutputParser.parseStoragePropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertNil(storage.usedBytes.value)
        XCTAssertEqual(storage.usedBytes.availability, .parseFailed)
        XCTAssertNil(storage.usageFraction)
    }

    func testDetailMergePrefersCompleteCoherentStorageResult() {
        let devicectl = DeviceDetailResult(
            storage: StorageInformation(
                totalBytes: .available(
                    128_000_000_000,
                    source: "devicectl / hardwareProperties",
                    rawFieldName: "internalStorageCapacity"
                )
            )
        )
        let libimobiledevice = DeviceDetailResult(
            storage: StorageInformation(
                totalBytes: .available(
                    120_092_147_712,
                    source: "libimobiledevice / com.apple.disk_usage",
                    rawFieldName: "TotalDataCapacity"
                ),
                availableBytes: .available(
                    18_514_563_072,
                    source: "libimobiledevice / com.apple.disk_usage",
                    rawFieldName: "AmountDataAvailable"
                ),
                usedBytes: .available(
                    101_577_584_640,
                    source: "libimobiledevice / com.apple.disk_usage",
                    rawFieldName: "TotalDataCapacity - AmountDataAvailable"
                )
            )
        )

        let merged = DeviceInformationService().merge([
            devicectl,
            libimobiledevice
        ])

        XCTAssertEqual(merged.storage.totalBytes.value, 120_092_147_712)
        XCTAssertEqual(merged.storage.availableBytes.value, 18_514_563_072)
        XCTAssertEqual(merged.storage.usedBytes.value, 101_577_584_640)
        XCTAssertNotNil(merged.storage.usageFraction)
    }

    func testStorageRejectsContradictoryCapacityValues() throws {
        let xml = plist([
            "TotalDiskCapacity": "<integer>100</integer>",
            "AmountDiskAvailable": "<integer>120</integer>"
        ])

        let storage = try DeviceDetailOutputParser.parseStoragePropertyList(
            data: Data(xml.utf8)
        )

        XCTAssertNil(storage.usedBytes.value)
        XCTAssertEqual(storage.usedBytes.availability, .parseFailed)
        XCTAssertNil(storage.usageFraction)
    }

    func testStaleValueKeepsLastSuccessfulTimestampAndSource() {
        let timestamp = Date(timeIntervalSince1970: 1234)
        let value = DataValue<Int64>.available(
            128,
            source: "test-domain",
            rawFieldName: "TotalCapacity",
            updatedAt: timestamp
        ).markedStale()

        XCTAssertEqual(value.availability, .stale)
        XCTAssertEqual(value.updatedAt, timestamp)
        XCTAssertEqual(value.source, "test-domain")
        XCTAssertEqual(value.rawFieldName, "TotalCapacity")
    }

    func testDiagnosticLoggingRedactsDeviceIdentifiersAndContactData() {
        let raw = """
        device 00008110-001A2B3C4D5E801E failed
        serial ABCD1234EFGH5678
        owner@example.com +86 138 1234 5678
        """
        let redacted = AppLogger.redactedDiagnostic(raw)

        XCTAssertFalse(redacted.contains("00008110-001A2B3C4D5E801E"))
        XCTAssertFalse(redacted.contains("ABCD1234EFGH5678"))
        XCTAssertFalse(redacted.contains("owner@example.com"))
        XCTAssertFalse(redacted.contains("138 1234 5678"))
        XCTAssertTrue(redacted.contains("<redacted>"))
    }

    private func plist(_ entries: [String: String]) -> String {
        let body = entries.sorted(by: { $0.key < $1.key }).map {
            "<key>\($0.key)</key>\($0.value)"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """
    }
}
