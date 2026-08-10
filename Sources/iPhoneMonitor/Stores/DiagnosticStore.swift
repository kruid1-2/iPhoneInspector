import Combine
import Foundation
import iPhoneMonitorCore

@MainActor
final class DiagnosticStore: ObservableObject {
    @Published private(set) var analyses: [DiagnosticAnalysis]
    @Published private(set) var isImporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressMessage = ""
    @Published private(set) var lastError: String?

    private let service: DiagnosticImportService
    private let dataDirectory: URL
    private var importTask: Task<Void, Never>?

    init(service: DiagnosticImportService = DiagnosticImportService()) {
        self.service = service
        dataDirectory = service.dataDirectory()
        analyses = DiagnosticPersistence.load(from: dataDirectory)
    }

    var allRecords: [DiagnosticRecord] {
        analyses.flatMap(\.records).sorted {
            ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
    }

    var latestAnalysis: DiagnosticAnalysis? {
        analyses.max(by: { $0.importedAt < $1.importedAt })
    }

    var latestBattery: BatteryInformation {
        latestAnalysis?.battery ?? BatteryInformation()
    }

    var latestStorage: StorageInformation {
        latestAnalysis?.storage ?? StorageInformation()
    }

    func importDiagnostics(
        from url: URL,
        keepCopy: Bool,
        retentionDays: Int
    ) {
        guard !isImporting else { return }
        isImporting = true
        progress = 0
        progressMessage = "准备导入…"
        lastError = nil

        importTask = Task { [weak self] in
            guard let self else { return }
            let gainedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gainedAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let analysis = try await service.analyze(
                    sourceURL: url,
                    keepCopy: keepCopy
                ) { fraction, message in
                    Task { @MainActor [weak self] in
                        self?.progress = fraction
                        self?.progressMessage = message
                    }
                }
                var updated = analyses
                updated.append(analysis)
                analyses = pruned(updated, retentionDays: retentionDays)
                try DiagnosticPersistence.save(analyses, to: dataDirectory)
                progress = 1
                progressMessage = "已分析 \(analysis.scannedFileCount) 个文件"
                AppLogger.diagnostics.info(
                    "Diagnostic import completed records=\(analysis.records.count)"
                )
            } catch is CancellationError {
                progressMessage = "导入已取消"
            } catch {
                lastError = error.localizedDescription
                progressMessage = "导入失败"
                AppLogger.diagnostics.error(
                    "Diagnostic import failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            isImporting = false
            importTask = nil
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    func clearAll() throws {
        importTask?.cancel()
        try DiagnosticPersistence.clear(directory: dataDirectory)
        try service.clearRetainedImports()
        analyses = []
        progress = 0
        progressMessage = ""
        lastError = nil
    }

    func prune(retentionDays: Int) {
        analyses = pruned(analyses, retentionDays: retentionDays)
        try? DiagnosticPersistence.save(analyses, to: dataDirectory)
    }

    func dataDirectoryURL() -> URL {
        dataDirectory
    }

    private func pruned(
        _ values: [DiagnosticAnalysis],
        retentionDays: Int
    ) -> [DiagnosticAnalysis] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(retentionDays, 1),
            to: Date()
        ) ?? .distantPast
        return values
            .filter { $0.importedAt >= cutoff }
            .sorted { $0.importedAt > $1.importedAt }
    }
}
