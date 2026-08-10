import XCTest
@testable import iPhoneMonitorCore

final class CapacityAndModelTests: XCTestCase {
    func testCapacityConversion() {
        XCTAssertEqual(CapacityParser.bytes(from: "5 GB"), 5 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(CapacityParser.bytes(from: "512M"), 512 * 1_024 * 1_024)
        XCTAssertEqual(CapacityParser.bytes(from: "12345"), 12_345)
        XCTAssertNil(CapacityParser.bytes(from: "unknown"))
    }

    func testDeviceModelMapping() {
        XCTAssertEqual(
            DeviceModelMapper.marketingName(for: "iPhone14,4"),
            "iPhone 13 mini"
        )
        XCTAssertEqual(
            DeviceModelMapper.marketingName(for: "iPhone99,9"),
            "iPhone99,9"
        )
    }

    func testStorageUsageWithMissingFieldsDoesNotCrash() {
        let missing = StorageInformation()
        XCTAssertNil(missing.usageFraction)

        let contradictory = StorageInformation(
            totalBytes: .available(10, source: "test"),
            availableBytes: .available(20, source: "test")
        )
        XCTAssertNil(contradictory.usageFraction)
    }
}
