import Foundation

public typealias DiagnosticProgressHandler = @Sendable (Double, String) -> Void

public enum DiagnosticImportError: LocalizedError {
    case unsupportedSource
    case unsafeArchiveEntry(String)
    case archiveTooLarge
    case extractionFailed(String)
    case noReadableFiles

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "支持 .ips、.panic、.log、.txt、.zip、.tar.gz 或诊断文件夹。"
        case .unsafeArchiveEntry(let entry):
            return "压缩包包含不安全路径：\(entry)"
        case .archiveTooLarge:
            return "压缩包候选文件过多或解压后超过 200 MB 安全限制。"
        case .extractionFailed(let detail):
            return "解压失败：\(detail)"
        case .noReadableFiles:
            return "没有找到可读取的诊断文本。"
        }
    }
}

public struct DiagnosticImportService: @unchecked Sendable {
    private let runner: CommandRunner
    private let parser: DiagnosticParser
    private let fileManager: FileManager
    private let applicationSupportURL: URL?

    private let maximumFiles = 600
    private let maximumFileBytes = 20 * 1_024 * 1_024
    private let maximumTotalBytes = 200 * 1_024 * 1_024

    public init(
        runner: CommandRunner = CommandRunner(),
        parser: DiagnosticParser = DiagnosticParser(),
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) {
        self.runner = runner
        self.parser = parser
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL
    }

    public func analyze(
        sourceURL: URL,
        keepCopy: Bool,
        progress: @escaping DiagnosticProgressHandler = { _, _ in }
    ) async throws -> DiagnosticAnalysis {
        progress(0.02, "正在检查导入来源…")
        try Task.checkCancellation()

        let prepared = try await prepare(sourceURL: sourceURL, progress: progress)
        defer {
            if let cleanup = prepared.cleanupURL {
                try? fileManager.removeItem(at: cleanup)
            }
        }

        guard !prepared.files.isEmpty else {
            throw DiagnosticImportError.noReadableFiles
        }

        var records: [DiagnosticRecord] = []
        var failures: [DiagnosticImportFailure] = []
        var battery = BatteryInformation()
        var storage = StorageInformation()

        for (index, fileURL) in prepared.files.enumerated() {
            try Task.checkCancellation()
            let fraction = 0.15 + (0.60 * Double(index) / Double(max(prepared.files.count, 1)))
            progress(fraction, "正在解析 \(fileURL.lastPathComponent)…")

            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    continue
                }
                guard (values.fileSize ?? 0) <= maximumFileBytes else {
                    throw DiagnosticImportError.archiveTooLarge
                }

                let data = try Data(
                    contentsOf: fileURL,
                    options: [.mappedIfSafe, .uncached]
                )
                let parsed = try parser.parse(
                    data: data,
                    fileName: fileURL.lastPathComponent
                )
                records.append(contentsOf: parsed.records)
                battery = mergeBattery(primary: battery, fallback: parsed.battery)
                storage = mergeStorage(primary: storage, fallback: parsed.storage)
                AppLogger.diagnostics.info(
                    "Parsed diagnostic file \(fileURL.lastPathComponent, privacy: .private(mask: .hash))"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(
                    DiagnosticImportFailure(
                        fileName: fileURL.lastPathComponent,
                        message: error.localizedDescription
                    )
                )
            }
        }

        progress(0.78, "正在读取 PowerLog 摘要…")
        if prepared.mayContainPowerLog,
           let legacy = try? await DiagnosticAnalyzer().analyze(sourceURL: sourceURL) {
            battery = mergeBattery(
                primary: battery,
                fallback: batteryFromLegacy(legacy)
            )
            storage = mergeStorage(
                primary: storage,
                fallback: storageFromLegacy(legacy)
            )
            records.append(contentsOf: recordsFromLegacy(legacy))
        }

        try Task.checkCancellation()
        progress(0.90, "正在保存本地摘要…")
        let retainedName = keepCopy ? try retainCopyIfPractical(sourceURL) : nil

        if records.isEmpty, failures.count == prepared.files.count {
            throw DiagnosticImportError.noReadableFiles
        }

        progress(1, "诊断解析完成")
        return DiagnosticAnalysis(
            sourceName: sourceURL.lastPathComponent,
            scannedFileCount: prepared.files.count,
            records: deduplicated(records),
            failures: failures,
            battery: battery,
            storage: storage,
            retainedCopyName: retainedName
        )
    }

    public func clearRetainedImports() throws {
        let importsURL = supportRoot().appendingPathComponent("Imports", isDirectory: true)
        if fileManager.fileExists(atPath: importsURL.path) {
            try fileManager.removeItem(at: importsURL)
        }
    }

    public func dataDirectory() -> URL {
        supportRoot()
    }

    private func prepare(
        sourceURL: URL,
        progress: @escaping DiagnosticProgressHandler
    ) async throws -> PreparedDiagnosticSource {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw DiagnosticImportError.unsupportedSource
        }

        if isDirectory.boolValue {
            let files = try diagnosticFiles(in: sourceURL)
            return PreparedDiagnosticSource(
                files: files,
                cleanupURL: nil,
                mayContainPowerLog: true
            )
        }

        let name = sourceURL.lastPathComponent.lowercased()
        if isPlainDiagnostic(name) {
            return PreparedDiagnosticSource(
                files: [sourceURL],
                cleanupURL: nil,
                mayContainPowerLog: false
            )
        }
        if name.hasSuffix(".zip") {
            progress(0.06, "正在安全检查 ZIP 压缩包…")
            return try await extractArchive(
                sourceURL,
                kind: .zip,
                mayContainPowerLog: false
            )
        }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            progress(0.06, "正在安全检查 sysdiagnose 压缩包…")
            return try await extractArchive(
                sourceURL,
                kind: .tarGzip,
                mayContainPowerLog: true
            )
        }
        throw DiagnosticImportError.unsupportedSource
    }

    private func extractArchive(
        _ archiveURL: URL,
        kind: ArchiveKind,
        mayContainPowerLog: Bool
    ) async throws -> PreparedDiagnosticSource {
        let listing: CommandResult
        switch kind {
        case .zip:
            listing = await runner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-Z1", archiveURL.path],
                timeout: 30,
                maximumOutputBytes: 8 * 1_024 * 1_024
            )
        case .tarGzip:
            listing = await runner.run(
                executable: "/usr/bin/tar",
                arguments: ["-tzf", archiveURL.path],
                timeout: 60,
                maximumOutputBytes: 12 * 1_024 * 1_024
            )
        }
        guard listing.succeeded else {
            throw DiagnosticImportError.extractionFailed(listing.conciseError)
        }
        guard !listing.outputTruncated else {
            throw DiagnosticImportError.archiveTooLarge
        }

        let allEntries = listing.output.split(whereSeparator: \.isNewline).map(String.init)
        for entry in allEntries where !isSafeArchivePath(entry) {
            throw DiagnosticImportError.unsafeArchiveEntry(entry)
        }

        let selected = Array(
            allEntries.filter(isDiagnosticArchiveEntry).prefix(maximumFiles)
        )
        guard !selected.isEmpty else {
            throw DiagnosticImportError.noReadableFiles
        }
        if allEntries.filter(isDiagnosticArchiveEntry).count > maximumFiles {
            throw DiagnosticImportError.archiveTooLarge
        }
        try await validateArchiveSizes(
            archiveURL,
            kind: kind,
            selectedEntries: Set(selected)
        )

        let extractionURL = fileManager.temporaryDirectory
            .appendingPathComponent("iPhoneInspector-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)

        let extraction: CommandResult
        switch kind {
        case .zip:
            extraction = await runner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-qq", archiveURL.path] + selected + ["-d", extractionURL.path],
                timeout: 90,
                maximumOutputBytes: 2 * 1_024 * 1_024
            )
        case .tarGzip:
            extraction = await runner.run(
                executable: "/usr/bin/tar",
                arguments: ["-xzf", archiveURL.path, "-C", extractionURL.path, "--"] + selected,
                timeout: 120,
                maximumOutputBytes: 2 * 1_024 * 1_024
            )
        }

        guard extraction.succeeded else {
            try? fileManager.removeItem(at: extractionURL)
            throw DiagnosticImportError.extractionFailed(extraction.conciseError)
        }

        do {
            let files = try diagnosticFiles(in: extractionURL)
            try validateExtractedSize(files)
            return PreparedDiagnosticSource(
                files: files,
                cleanupURL: extractionURL,
                mayContainPowerLog: mayContainPowerLog
            )
        } catch {
            try? fileManager.removeItem(at: extractionURL)
            throw error
        }
    }

    private func diagnosticFiles(in root: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        var candidates: [(URL, Int)] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey
            ])
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == resolvedRoot.path || resolved.hasPrefix(rootPrefix) else {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard
                values?.isRegularFile == true,
                (values?.fileSize ?? 0) <= maximumFileBytes,
                isDiagnosticArchiveEntry(url.lastPathComponent)
            else { continue }
            candidates.append((url, priority(for: url.lastPathComponent)))
            if candidates.count > maximumFiles * 2 {
                break
            }
        }

        return candidates
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
            }
            .prefix(maximumFiles)
            .map(\.0)
    }

    private func validateExtractedSize(_ files: [URL]) throws {
        var total = 0
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumFileBytes else {
                throw DiagnosticImportError.archiveTooLarge
            }
            total += size
            guard total <= maximumTotalBytes else {
                throw DiagnosticImportError.archiveTooLarge
            }
        }
    }

    private func validateArchiveSizes(
        _ archiveURL: URL,
        kind: ArchiveKind,
        selectedEntries: Set<String>
    ) async throws {
        let result: CommandResult
        switch kind {
        case .zip:
            result = await runner.run(
                executable: "/usr/bin/unzip",
                arguments: ["-l", archiveURL.path],
                timeout: 30,
                maximumOutputBytes: 12 * 1_024 * 1_024
            )
        case .tarGzip:
            result = await runner.run(
                executable: "/usr/bin/tar",
                arguments: ["-tvzf", archiveURL.path],
                timeout: 60,
                maximumOutputBytes: 16 * 1_024 * 1_024
            )
        }
        guard result.succeeded, !result.outputTruncated else {
            throw DiagnosticImportError.archiveTooLarge
        }

        var matched: Set<String> = []
        var total = 0
        for line in result.output.split(whereSeparator: \.isNewline).map(String.init) {
            let parsed: (name: String, size: Int)?
            switch kind {
            case .zip:
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 4, let size = Int(parts[0]) {
                    parsed = (
                        parts.dropFirst(3).map(String.init).joined(separator: " "),
                        size
                    )
                } else {
                    parsed = nil
                }
            case .tarGzip:
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 9, let size = Int(parts[4]) {
                    parsed = (
                        parts.dropFirst(8).map(String.init).joined(separator: " "),
                        size
                    )
                } else {
                    parsed = nil
                }
            }

            guard let parsed, selectedEntries.contains(parsed.name) else { continue }
            matched.insert(parsed.name)
            guard parsed.size <= maximumFileBytes else {
                throw DiagnosticImportError.archiveTooLarge
            }
            total += parsed.size
            guard total <= maximumTotalBytes else {
                throw DiagnosticImportError.archiveTooLarge
            }
        }

        guard matched == selectedEntries else {
            throw DiagnosticImportError.extractionFailed("无法确认压缩包内候选文件的大小")
        }
    }

    private func isSafeArchivePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasPrefix("\\"),
            !path.hasPrefix("-")
        else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }

    private func isDiagnosticArchiveEntry(_ path: String) -> Bool {
        let name = path.lowercased()
        if isPlainDiagnostic(name) { return true }
        return [
            "panic-full", "panic-base", "jetsamevent", "lowmemory",
            "thermal", "reset", "watchdog", "crash", "batteryhealth",
            "disks.txt"
        ].contains(where: name.contains)
    }

    private func isPlainDiagnostic(_ name: String) -> Bool {
        [".ips", ".panic", ".log", ".txt"].contains {
            name.lowercased().hasSuffix($0)
        }
    }

    private func priority(for fileName: String) -> Int {
        let name = fileName.lowercased()
        if name.contains("panic") { return 100 }
        if name.contains("jetsam") || name.contains("lowmemory") { return 90 }
        if name.contains("thermal") || name.contains("watchdog") { return 80 }
        if name.contains("battery") || name.contains("disks") { return 70 }
        if name.hasSuffix(".ips") { return 60 }
        return 20
    }

    private func retainCopyIfPractical(_ sourceURL: URL) throws -> String? {
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else { return nil }
        guard (values.fileSize ?? 0) <= 1_024 * 1_024 * 1_024 else { return nil }

        let importsURL = supportRoot().appendingPathComponent("Imports", isDirectory: true)
        try fileManager.createDirectory(at: importsURL, withIntermediateDirectories: true)
        let safeName = sourceURL.lastPathComponent
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._\-\u4e00-\u9fff]"#,
                with: "_",
                options: .regularExpression
            )
        let destinationName = "\(UUID().uuidString)-\(safeName)"
        let destination = importsURL.appendingPathComponent(destinationName)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destinationName
    }

    private func supportRoot() -> URL {
        if let applicationSupportURL {
            return applicationSupportURL
        }
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("iPhoneInspector", isDirectory: true)
    }

    private func mergeBattery(
        primary: BatteryInformation,
        fallback: BatteryInformation
    ) -> BatteryInformation {
        var result = primary
        if result.currentLevelPercent.value == nil,
           fallback.currentLevelPercent.value != nil {
            result.currentLevelPercent = fallback.currentLevelPercent
        }
        if result.isCharging.value == nil, fallback.isCharging.value != nil {
            result.isCharging = fallback.isCharging
        }
        if result.externalPowerConnected.value == nil,
           fallback.externalPowerConnected.value != nil {
            result.externalPowerConnected = fallback.externalPowerConnected
        }
        if result.healthPercent.value == nil, fallback.healthPercent.value != nil {
            result.healthPercent = fallback.healthPercent
        }
        if result.designCapacityMAh.value == nil,
           fallback.designCapacityMAh.value != nil {
            result.designCapacityMAh = fallback.designCapacityMAh
        }
        if result.maximumCapacityMAh.value == nil,
           fallback.maximumCapacityMAh.value != nil {
            result.maximumCapacityMAh = fallback.maximumCapacityMAh
        }
        if result.cycleCount.value == nil, fallback.cycleCount.value != nil {
            result.cycleCount = fallback.cycleCount
        }
        if result.verificationStatus.value == nil,
           fallback.verificationStatus.value != nil {
            result.verificationStatus = fallback.verificationStatus
        }
        if result.serialOrManufacturingInfo.value == nil,
           fallback.serialOrManufacturingInfo.value != nil {
            result.serialOrManufacturingInfo = fallback.serialOrManufacturingInfo
        }
        if result.chargingStatus.value == nil,
           fallback.chargingStatus.value != nil {
            result.chargingStatus = fallback.chargingStatus
        }
        result.latestLogDate = result.latestLogDate ?? fallback.latestLogDate
        return result
    }

    private func mergeStorage(
        primary: StorageInformation,
        fallback: StorageInformation
    ) -> StorageInformation {
        var result = primary
        if result.totalBytes.value == nil, fallback.totalBytes.value != nil {
            result.totalBytes = fallback.totalBytes
        }
        if result.availableBytes.value == nil,
           fallback.availableBytes.value != nil {
            result.availableBytes = fallback.availableBytes
        }
        if result.usedBytes.value == nil, fallback.usedBytes.value != nil {
            result.usedBytes = fallback.usedBytes
        }
        if result.reclaimableBytes.value == nil,
           fallback.reclaimableBytes.value != nil {
            result.reclaimableBytes = fallback.reclaimableBytes
        }
        result.updatedAt = result.updatedAt ?? fallback.updatedAt
        return result
    }

    private func batteryFromLegacy(_ report: DiagnosticReport) -> BatteryInformation {
        let source = "PowerLog / sysdiagnose"
        return BatteryInformation(
            healthPercent: report.batteryHealthPercent.map {
                .available($0, source: source, confidence: .medium)
            } ?? .missing(.requiresDiagnosticLog, source: source),
            cycleCount: report.cycleCount.map {
                .available($0, source: source, confidence: .medium)
            } ?? .missing(.requiresDiagnosticLog, source: source),
            latestLogDate: report.importedAt
        )
    }

    private func storageFromLegacy(_ report: DiagnosticReport) -> StorageInformation {
        let source = "sysdiagnose disks.txt"
        let available = report.freeStorageGB.map {
            Int64($0 * 1_024 * 1_024 * 1_024)
        }
        return StorageInformation(
            availableBytes: available.map {
                .available($0, source: source, confidence: .medium)
            } ?? .missing(.notReturned, source: source),
            updatedAt: available == nil ? nil : report.importedAt
        )
    }

    private func recordsFromLegacy(_ report: DiagnosticReport) -> [DiagnosticRecord] {
        report.days.flatMap { day -> [DiagnosticRecord] in
            var records: [DiagnosticRecord] = []
            if day.maximumTemperature >= 40 {
                records.append(
                    DiagnosticRecord(
                        category: .thermal,
                        timestamp: DiagnosticDateParser.date(from: "\(day.date) 12:00:00"),
                        summary: String(
                            format: "PowerLog 记录到当天最高电池温度 %.1f°C",
                            day.maximumTemperature
                        ),
                        evidence: String(
                            format: "40°C 以上累计约 %.1f 分钟",
                            day.hotMinutes
                        ),
                        sourceFile: report.sourceName,
                        confidence: .medium
                    )
                )
            }
            if day.memoryWarningPercent > 0 {
                records.append(
                    DiagnosticRecord(
                        category: .lowMemory,
                        timestamp: DiagnosticDateParser.date(from: "\(day.date) 12:00:00"),
                        summary: "PowerLog 记录了内存压力采样",
                        evidence: String(
                            format: "警告采样比例 %.1f%%，交换峰值 %.0f MB",
                            day.memoryWarningPercent,
                            day.maximumSwapMB
                        ),
                        sourceFile: report.sourceName,
                        confidence: .medium
                    )
                )
            }
            return records
        }
    }

    private func deduplicated(_ records: [DiagnosticRecord]) -> [DiagnosticRecord] {
        var seen: Set<String> = []
        return records.filter { record in
            let key = [
                record.category.rawValue,
                record.sourceFile,
                record.summary,
                record.timestamp?.description ?? ""
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }
}

private struct PreparedDiagnosticSource {
    let files: [URL]
    let cleanupURL: URL?
    let mayContainPowerLog: Bool
}

private enum ArchiveKind {
    case zip
    case tarGzip
}
