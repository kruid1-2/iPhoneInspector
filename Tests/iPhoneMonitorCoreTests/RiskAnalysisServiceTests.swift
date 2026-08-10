import XCTest
@testable import iPhoneMonitorCore

final class RiskAnalysisServiceTests: XCTestCase {
    private let service = RiskAnalysisService()

    func testStorageRiskRules() {
        let total = Int64(128 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(
            service.storageRiskLevel(
                totalBytes: total,
                availableBytes: Int64(20 * 1_024 * 1_024 * 1_024)
            ),
            .normal
        )
        XCTAssertEqual(
            service.storageRiskLevel(
                totalBytes: total,
                availableBytes: Int64(15 * 1_024 * 1_024 * 1_024)
            ),
            .notice
        )
        XCTAssertEqual(
            service.storageRiskLevel(
                totalBytes: total,
                availableBytes: Int64(8 * 1_024 * 1_024 * 1_024)
            ),
            .high
        )
        XCTAssertEqual(
            service.storageRiskLevel(
                totalBytes: nil,
                availableBytes: Int64(4 * 1_024 * 1_024 * 1_024)
            ),
            .high
        )
    }

    func testMultiplePanicsProduceHighRisk() {
        let now = Date()
        let records = (0..<3).map { index in
            DiagnosticRecord(
                category: .panic,
                timestamp: now.addingTimeInterval(Double(-index * 3_600)),
                summary: "panic",
                evidence: "panicString test \(index)",
                sourceFile: "panic-\(index).ips",
                confidence: .high
            )
        }

        let findings = service.analyze(
            device: nil,
            battery: BatteryInformation(),
            storage: StorageInformation(),
            records: records,
            now: now
        )

        XCTAssertEqual(
            findings.first(where: { $0.id == "panic-count" })?.level,
            .high
        )
    }

    func testRepeatedJetsamProducesMemoryFinding() {
        let records = (0..<3).map { index in
            DiagnosticRecord(
                category: .jetsam,
                summary: "jetsam",
                evidence: "memorystatus \(index)",
                sourceFile: "jetsam-\(index).ips",
                confidence: .medium
            )
        }

        let findings = service.analyze(
            device: nil,
            battery: BatteryInformation(),
            storage: StorageInformation(),
            records: records
        )
        XCTAssertNotNil(findings.first(where: { $0.id == "memory-pressure" }))
    }

    func testNoDataReturnsInsufficientFinding() {
        let findings = service.analyze(
            device: nil,
            battery: BatteryInformation(),
            storage: StorageInformation(),
            records: []
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.level, .insufficient)
    }

    func testMissingBatteryDoesNotAssertDamage() {
        let device = DemoDataFactory.device
        let findings = service.analyze(
            device: device,
            battery: BatteryInformation(),
            storage: StorageInformation(),
            records: []
        )
        let batteryFinding = findings.first(where: { $0.id == "battery-data-missing" })
        XCTAssertNotNil(batteryFinding)
        XCTAssertEqual(batteryFinding?.level, .insufficient)
        XCTAssertTrue(batteryFinding?.summary.contains("不能证明") == true)
    }
}
