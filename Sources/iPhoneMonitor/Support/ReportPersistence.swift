import Foundation
import iPhoneMonitorCore

enum ReportPersistence {
    private static var reportURL: URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return support
            .appendingPathComponent("iPhoneMonitor", isDirectory: true)
            .appendingPathComponent("latest-report.json")
    }

    static func load() -> DiagnosticReport? {
        guard
            let reportURL,
            let data = try? Data(contentsOf: reportURL)
        else { return nil }
        return try? JSONDecoder().decode(DiagnosticReport.self, from: data)
    }

    static func save(_ report: DiagnosticReport) {
        guard let reportURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            // Analysis remains usable in memory even when persistence fails.
        }
    }
}
