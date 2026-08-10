import XCTest
@testable import iPhoneMonitorCore

final class DiagnosticTextParserTests: XCTestCase {
    func testBatteryHealthParser() {
        let text = """
        Battery 0 health info:
        {
            "Maximum Capacity Percent" = 96;
        }
        """

        XCTAssertEqual(
            DiagnosticTextParser.batteryHealthPercent(from: text),
            96
        )
    }

    func testFreeStorageParser() throws {
        let text = """
        Filesystem Size Used Avail Capacity Mounted on
        /dev/disk1s2 128G 38G 15G 73% /private/var
        /dev/disk1s8 128G 62G 15G 81% /private/var/mobile
        """

        let freeStorage = try XCTUnwrap(
            DiagnosticTextParser.freeStorageGB(from: text)
        )
        XCTAssertEqual(freeStorage, 15, accuracy: 0.01)
    }

    func testMissingPrivateVarMobileReturnsNil() {
        XCTAssertNil(
            DiagnosticTextParser.freeStorageGB(
                from: "/dev/disk1s1 128G 60G 40G 60% /"
            )
        )
    }

    func testWorkspaceSysdiagnoseIntegrationWhenAvailable() async throws {
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("diagnostics/sysdiagnose/extracted")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: fixture.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw XCTSkip("Workspace sysdiagnose fixture is not available.")
        }

        let report = try await DiagnosticAnalyzer().analyze(sourceURL: fixture)
        let july28 = try XCTUnwrap(
            report.days.first(where: { $0.date == "2026-07-28" })
        )

        XCTAssertEqual(report.batteryHealthPercent, 96)
        XCTAssertEqual(report.freeStorageGB, 15)
        XCTAssertEqual(july28.maximumTemperature, 44.79, accuracy: 0.02)
        XCTAssertEqual(july28.memoryWarningPercent, 28.0, accuracy: 0.1)
        XCTAssertTrue(
            july28.topProcesses.contains(where: { $0.processName == "suggestd" })
        )
    }

    func testCompressedSysdiagnoseImportWhenAvailable() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("diagnostics/sysdiagnose")
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("Compressed workspace sysdiagnose is not available.")
        }
        let archive = try FileManager.default
            .contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )
            .first(where: { $0.lastPathComponent.hasSuffix(".tar.gz") })

        guard let archive else {
            throw XCTSkip("Compressed workspace sysdiagnose is not available.")
        }

        let report = try await DiagnosticAnalyzer().analyze(sourceURL: archive)
        let july28 = try XCTUnwrap(
            report.days.first(where: { $0.date == "2026-07-28" })
        )

        XCTAssertEqual(report.batteryHealthPercent, 96)
        XCTAssertEqual(july28.maximumTemperature, 44.79, accuracy: 0.02)
        XCTAssertGreaterThan(july28.topProcesses.count, 5)
    }
}
