import Foundation
import XCTest
@testable import iPhoneMonitorCore

final class BatteryOverviewResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshLiveSampleWinsWhileMonitoring() throws {
        let snapshot = BatteryOverviewResolver.resolve(
            staticBattery: staticBattery(level: 83, charging: false, external: false, health: 91),
            liveSample: try liveBattery(level: 82, charging: true, external: true, temperature: 3_900),
            liveReceivedAt: now.addingTimeInterval(-1),
            performanceState: .monitoring,
            now: now
        )

        XCTAssertEqual(snapshot.currentLevelPercent, 82)
        XCTAssertEqual(snapshot.isCharging, true)
        XCTAssertEqual(snapshot.externalPowerConnected, true)
        XCTAssertEqual(snapshot.healthPercent, 91)
        XCTAssertEqual(snapshot.temperatureRaw, 3_900)
        XCTAssertEqual(snapshot.source, .realtime)
    }

    func testNoPerformanceSessionUsesStaticBattery() throws {
        let snapshot = BatteryOverviewResolver.resolve(
            staticBattery: staticBattery(level: 83, charging: false, external: true, health: 91),
            liveSample: try liveBattery(level: 82, charging: true, external: true, temperature: 3_900),
            liveReceivedAt: now,
            performanceState: .helperReady,
            now: now
        )

        XCTAssertEqual(snapshot.currentLevelPercent, 83)
        XCTAssertEqual(snapshot.isCharging, false)
        XCTAssertNil(snapshot.temperatureRaw)
        XCTAssertEqual(snapshot.source, .recentRead)
    }

    func testStaleLiveSampleFallsBackToStaticBattery() throws {
        let snapshot = BatteryOverviewResolver.resolve(
            staticBattery: staticBattery(level: 83, charging: false, external: false, health: 91),
            liveSample: try liveBattery(level: 82, charging: true, external: true, temperature: 3_900),
            liveReceivedAt: now.addingTimeInterval(-9),
            performanceState: .monitoring,
            now: now
        )

        XCTAssertEqual(snapshot.currentLevelPercent, 83)
        XCTAssertEqual(snapshot.isCharging, false)
        XCTAssertNil(snapshot.temperatureRaw)
        XCTAssertEqual(snapshot.source, .recentRead)
    }

    func testFreshPartialSampleUsesDeterministicPerFieldFallback() throws {
        let snapshot = BatteryOverviewResolver.resolve(
            staticBattery: staticBattery(level: 83, charging: false, external: true, health: 91),
            liveSample: try liveBattery(level: 150, charging: nil, external: nil, temperature: 3_875),
            liveReceivedAt: now,
            performanceState: .monitoring,
            now: now
        )

        XCTAssertEqual(snapshot.currentLevelPercent, 83, "invalid live percentages must not overwrite static data")
        XCTAssertEqual(snapshot.isCharging, false)
        XCTAssertEqual(snapshot.externalPowerConnected, true)
        XCTAssertEqual(snapshot.temperatureRaw, 3_875, "temperature remains the unscaled battery raw value")
        XCTAssertEqual(snapshot.source, .realtime)
    }

    private func staticBattery(
        level: Double,
        charging: Bool,
        external: Bool,
        health: Int
    ) -> BatteryInformation {
        BatteryInformation(
            currentLevelPercent: .available(level, source: "fixture", updatedAt: now.addingTimeInterval(-60)),
            isCharging: .available(charging, source: "fixture", updatedAt: now.addingTimeInterval(-60)),
            externalPowerConnected: .available(external, source: "fixture", updatedAt: now.addingTimeInterval(-60)),
            healthPercent: .available(health, source: "fixture", updatedAt: now.addingTimeInterval(-60))
        )
    }

    private func liveBattery(
        level: Double?,
        charging: Bool?,
        external: Bool?,
        temperature: Double?
    ) throws -> BatteryTelemetrySample {
        var metrics: [String: Any] = [:]
        if let level { metrics["CurrentCapacity"] = metric(level, field: "CurrentCapacity", unit: "percent") }
        if let charging { metrics["IsCharging"] = metric(charging, field: "IsCharging", unit: "boolean") }
        if let external { metrics["ExternalConnected"] = metric(external, field: "ExternalConnected", unit: "boolean") }
        if let temperature { metrics["Temperature"] = metric(temperature, field: "Temperature") }

        let object: [String: Any] = [
            "protocol_version": 2,
            "type": "battery_sample",
            "timestamp_utc": "2027-01-15T08:00:00.000Z",
            "monotonic_ns": 10_000,
            "sequence": 1,
            "session_id": "fixture-session",
            "source": "battery",
            "payload": ["metrics": metrics]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard case .message(let message) = PerformanceJSONLDecoder().decode(
            line: String(decoding: data, as: UTF8.self)
        ), let sample = BatteryTelemetrySample(message: message) else {
            throw NSError(domain: "BatteryOverviewResolverTests", code: 1)
        }
        return sample
    }

    private func metric(_ value: Any, field: String, unit: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["value": value, "raw_field": field]
        if let unit { result["unit"] = unit }
        return result
    }
}
