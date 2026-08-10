import Foundation
import iPhoneMonitorCore

enum DiagnosticPersistence {
    static func load(from directory: URL) -> [DiagnosticAnalysis] {
        let url = directory.appendingPathComponent("diagnostics.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DiagnosticAnalysis].self, from: data)) ?? []
    }

    static func save(_ analyses: [DiagnosticAnalysis], to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(analyses)
        try data.write(
            to: directory.appendingPathComponent("diagnostics.json"),
            options: .atomic
        )
    }

    static func clear(directory: URL) throws {
        let url = directory.appendingPathComponent("diagnostics.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
