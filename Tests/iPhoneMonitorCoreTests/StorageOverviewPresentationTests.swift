import XCTest
@testable import iPhoneMonitorCore

final class StorageOverviewPresentationTests: XCTestCase {
    func testHardFreeOnlyRequiresSettingsAndRetainsDiagnosticValue() {
        let storage = StorageInformation(
            totalBytes: .available(120_092_147_712, source: "USB"),
            hardFreeBytes: .available(
                3_714_256_896,
                source: "USB",
                rawFieldName: "AmountDataAvailable"
            )
        )

        let presentation = StorageOverviewPresentation.resolve(storage)

        XCTAssertEqual(presentation.primaryValue, .settingsRequired)
        XCTAssertEqual(presentation.hardFreeBytes, 3_714_256_896)
        XCTAssertNil(presentation.usageFraction)
    }

    func testVerifiedAvailableCapacityRemainsThePrimaryValue() {
        let storage = StorageInformation(
            totalBytes: .available(100, source: "verified"),
            availableBytes: .available(20, source: "verified"),
            usedBytes: .available(80, source: "verified"),
            hardFreeBytes: .available(5, source: "USB")
        )

        let presentation = StorageOverviewPresentation.resolve(storage)

        XCTAssertEqual(presentation.primaryValue, .userAvailable(20))
        XCTAssertEqual(presentation.hardFreeBytes, 5)
        XCTAssertEqual(presentation.usageFraction, 0.8)
    }
}
