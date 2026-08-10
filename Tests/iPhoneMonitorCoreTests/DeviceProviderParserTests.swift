import XCTest
@testable import iPhoneMonitorCore

final class DeviceProviderParserTests: XCTestCase {
    func testDevicectlOutputParser() throws {
        let json = """
        {
          "result": {
            "devices": [
              {
                "identifier": "00008110-TEST",
                "deviceProperties": {
                  "name": "我的 iPhone",
                  "osVersionNumber": "26.5.2"
                },
                "hardwareProperties": {
                  "productType": "iPhone14,4",
                  "marketingName": "iPhone 13 mini",
                  "serialNumber": "SERIAL123"
                },
                "connectionProperties": {
                  "transportType": "USB",
                  "pairingState": "paired"
                }
              }
            ]
          }
        }
        """

        let devices = try DevicectlOutputParser.parse(data: Data(json.utf8))
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.name, "我的 iPhone")
        XCTAssertEqual(device.productType, "iPhone14,4")
        XCTAssertEqual(device.marketingName, "iPhone 13 mini")
        XCTAssertEqual(device.systemVersion, "26.5.2")
        XCTAssertEqual(device.connectionType, "USB")
        XCTAssertEqual(device.state, .readable)
        XCTAssertNil(device.udid)
    }

    func testXCDeviceOutputParserIgnoresSimulator() throws {
        let json = """
        [
          {
            "simulator": true,
            "modelName": "iPhone 16",
            "identifier": "SIM",
            "platform": "com.apple.platform.iphonesimulator"
          },
          {
            "simulator": false,
            "modelName": "iPhone 13 mini",
            "modelCode": "iPhone14,4",
            "identifier": "REAL",
            "platform": "com.apple.platform.iphoneos",
            "interface": "usb",
            "operatingSystemVersion": "26.6 (23G71)",
            "available": true,
            "name": "Test Phone"
          }
        ]
        """

        let devices = try XCDeviceOutputParser.parse(data: Data(json.utf8))
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.identifier, "REAL")
        XCTAssertEqual(devices.first?.state, .readable)
        XCTAssertEqual(devices.first?.systemVersion, "26.6")
        XCTAssertEqual(devices.first?.buildVersion, "23G71")
    }

    func testLibimobiledeviceKeyValueParser() {
        let output = """
        DeviceName: Test iPhone
        ProductType: iPhone14,4
        ProductVersion: 26.5.2
        PasswordProtected: true
        """
        let device = LibimobiledeviceOutputParser.parse(
            output,
            identifier: "UDID-1"
        )

        XCTAssertEqual(device.name, "Test iPhone")
        XCTAssertEqual(device.marketingName, "iPhone 13 mini")
        XCTAssertEqual(device.passcodeProtected, true)
        XCTAssertEqual(device.state, .readable)
    }

    func testDiscoveryMergeKeepsCoreDeviceIdentityAndUsesUSBUDID() throws {
        let coreDevice = ProviderDevice(
            identifier: "CORE-DEVICE-ID",
            name: "Test iPhone",
            productType: "iPhone14,4",
            connectionType: "USB",
            state: .readable,
            source: "devicectl",
            priority: 100
        )
        let usbDevice = ProviderDevice(
            identifier: "USB-UDID",
            name: "Test iPhone",
            productType: "iPhone14,4",
            udid: "USB-UDID",
            connectionType: "USB",
            state: .readable,
            source: "libimobiledevice",
            priority: 90
        )

        let device = try XCTUnwrap(
            DeviceDiscoveryService(providers: []).merge([coreDevice, usbDevice]).first
        )

        XCTAssertEqual(device.id, "CORE-DEVICE-ID")
        XCTAssertEqual(device.information.udid.value, "USB-UDID")
        XCTAssertEqual(device.information.udid.source, "libimobiledevice")
    }

    func testDeviceDetailStorageParser() {
        let result = DeviceDetailOutputParser.parseLibimobiledevice(
            batteryOutput: """
            BatteryCurrentCapacity: 57
            BatteryIsCharging: false
            CycleCount: 421
            """,
            storageOutput: """
            TotalDataCapacity: 128000000000
            AmountDataAvailable: 12000000000
            """
        )

        XCTAssertEqual(result.battery.currentLevelPercent.value, 57)
        XCTAssertEqual(result.battery.isCharging.value, false)
        XCTAssertEqual(result.battery.cycleCount.value, 421)
        XCTAssertEqual(result.storage.totalBytes.value, 128_000_000_000)
        XCTAssertEqual(result.storage.availableBytes.value, 12_000_000_000)
        XCTAssertEqual(result.storage.usedBytes.value, 116_000_000_000)
    }
}
