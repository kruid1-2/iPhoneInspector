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

    func testStorageHardFreeValueBecomesStale() {
        let storage = StorageInformation(
            hardFreeBytes: .available(
                3_700_000_000,
                source: "libimobiledevice",
                rawFieldName: "AmountDataAvailable"
            )
        )

        XCTAssertEqual(storage.markedStale().hardFreeBytes.availability, .stale)
        XCTAssertTrue(storage.hasAnyValue)
    }

    func testStorageDecodesLegacyJSONWithoutHardFreeValue() throws {
        let original = StorageInformation(
            totalBytes: .available(128_000_000_000, source: "legacy")
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "hardFreeBytes")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            StorageInformation.self,
            from: legacyData
        )

        XCTAssertNil(decoded.hardFreeBytes.value)
        XCTAssertEqual(decoded.hardFreeBytes.availability, .notReturned)
    }
}
