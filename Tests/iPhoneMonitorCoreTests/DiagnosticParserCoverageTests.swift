import XCTest
@testable import iPhoneMonitorCore

final class DiagnosticParserCoverageTests: XCTestCase {
    private let parser = DiagnosticParser()

    func testIPSBasicParsing() {
        let text = """
        {"bug_type":"210","timestamp":"2026-07-28 15:10:00 +0800","name":"kernel"}
        {"panicString":"userspace watchdog timeout: no successful checkins from SpringBoard"}
        """

        let parsed = parser.parseIPS(text: text, fileName: "panic-full.ips")
        XCTAssertTrue(parsed.records.contains { $0.category == .panic })
        XCTAssertTrue(parsed.records.contains { $0.category == .watchdog })
        XCTAssertNotNil(parsed.records.first?.timestamp)
    }

    func testPanicFileNameRecognitionWithMissingFields() {
        let parsed = parser.parse(
            text: "panicString: test panic without structured metadata",
            fileName: "panic-base-test.panic"
        )
        XCTAssertEqual(parsed.records.first?.category, .panic)
        XCTAssertNil(parsed.records.first?.timestamp)
    }

    func testJetsamRecognition() {
        let parsed = parser.parse(
            text: """
            {"bug_type":"298","procName":"ExampleApp","largestProcess":"ExampleApp"}
            JetsamEvent memorystatus_kill
            """,
            fileName: "JetsamEvent-2026-07-28.ips"
        )
        XCTAssertTrue(parsed.records.contains { $0.category == .jetsam })
        XCTAssertEqual(
            parsed.records.first(where: { $0.category == .jetsam })?.processName,
            "ExampleApp"
        )
    }

    func testThermalAndBatteryRecognition() {
        let parsed = parser.parse(
            text: """
            thermal pressure level = serious
            "Maximum Capacity Percent" = 86;
            "CycleCount" = 612;
            """,
            fileName: "thermal-battery.log"
        )
        XCTAssertTrue(parsed.records.contains { $0.category == .thermal })
        XCTAssertTrue(parsed.records.contains { $0.category == .battery })
        XCTAssertEqual(parsed.battery.healthPercent.value, 86)
        XCTAssertEqual(parsed.battery.cycleCount.value, 612)
    }

    func testUnknownFormatPreservesSummary() {
        let parsed = parser.parse(
            text: "some future iOS diagnostic structure",
            fileName: "future-format.txt"
        )
        XCTAssertEqual(parsed.records.first?.category, .unknown)
        XCTAssertFalse(parsed.records.first?.evidence.isEmpty ?? true)
    }

    func testEmptyFileReturnsControlledError() {
        XCTAssertThrowsError(
            try parser.parse(data: Data(), fileName: "empty.ips")
        )
    }

    func testPlainFileImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("JetsamEvent-test.ips")
        try Data("JetsamEvent memory pressure procName: Test".utf8).write(to: file)

        let service = DiagnosticImportService(applicationSupportURL: root)
        let analysis = try await service.analyze(
            sourceURL: file,
            keepCopy: false
        )

        XCTAssertEqual(analysis.scannedFileCount, 1)
        XCTAssertTrue(analysis.records.contains { $0.category == .jetsam })
        XCTAssertTrue(analysis.failures.isEmpty)
    }

    func testZipAndTarGzipImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectorArchiveTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = source.appendingPathComponent("thermal.log")
        try Data("thermal pressure level = serious".utf8).write(to: log)

        let zip = root.appendingPathComponent("sample.zip")
        let zipResult = await ProcessRunner.run(
            executable: "/usr/bin/zip",
            arguments: ["-q", "-j", zip.path, log.path],
            timeout: 10
        )
        if !zipResult.succeeded {
            throw XCTSkip("zip is unavailable: \(zipResult.conciseError)")
        }

        let tar = root.appendingPathComponent("sample.tar.gz")
        let tarResult = await ProcessRunner.run(
            executable: "/usr/bin/tar",
            arguments: ["-czf", tar.path, "-C", source.path, "thermal.log"],
            timeout: 10
        )
        if !tarResult.succeeded {
            throw XCTSkip("tar is unavailable: \(tarResult.conciseError)")
        }

        let service = DiagnosticImportService(applicationSupportURL: root)
        let zipAnalysis = try await service.analyze(sourceURL: zip, keepCopy: false)
        let tarAnalysis = try await service.analyze(sourceURL: tar, keepCopy: false)

        XCTAssertTrue(zipAnalysis.records.contains { $0.category == .thermal })
        XCTAssertTrue(tarAnalysis.records.contains { $0.category == .thermal })
    }
}
