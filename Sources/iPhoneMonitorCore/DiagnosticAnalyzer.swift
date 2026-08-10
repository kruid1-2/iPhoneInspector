import Foundation

public enum DiagnosticAnalyzerError: LocalizedError {
    case unsupportedSource
    case missingPowerLog
    case archiveReadFailed(String)
    case extractionFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            return "请选择 sysdiagnose 的 .tar.gz 文件或已经解压的文件夹。"
        case .missingPowerLog:
            return "诊断包中没有找到 PowerLog 数据库。"
        case .archiveReadFailed(let detail):
            return "无法读取诊断包：\(detail)"
        case .extractionFailed(let detail):
            return "无法提取诊断数据：\(detail)"
        case .queryFailed(let detail):
            return "无法分析功耗数据库：\(detail)"
        }
    }
}

public struct DiagnosticAnalyzer {
    private let fileManager = FileManager.default

    public init() {}

    public func analyze(sourceURL: URL) async throws -> DiagnosticReport {
        let prepared = try await prepareSource(sourceURL)
        defer {
            if let cleanupURL = prepared.cleanupURL {
                try? fileManager.removeItem(at: cleanupURL)
            }
        }

        guard let powerDatabase = prepared.powerDatabase else {
            throw DiagnosticAnalyzerError.missingPowerLog
        }

        let batteryHealthFromLog = prepared.batteryHealthLog
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap(DiagnosticTextParser.batteryHealthPercent)

        let freeStorageGB = prepared.disksFile
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap(DiagnosticTextParser.freeStorageGB)

        let latestBatteryRows = try? await queryRows(
            database: powerDatabase,
            sql: """
            SELECT
              CAST(MaxCapacity AS INTEGER) AS maximum_capacity,
              CAST(CycleCount AS INTEGER) AS cycle_count
            FROM PLBatteryAgent_EventBackward_Battery
            ORDER BY timestamp DESC
            LIMIT 1;
            """
        )

        let latestBattery = latestBatteryRows?.first
        let batteryHealth = batteryHealthFromLog
            ?? latestBattery.flatMap { integer($0["maximum_capacity"]) }
        let cycleCount = latestBattery.flatMap { integer($0["cycle_count"]) }

        let offset = """
        (SELECT system
         FROM PLStorageOperator_EventForward_TimeOffset
         ORDER BY timestamp DESC
         LIMIT 1)
        """
        let wallTime = "datetime(timestamp+\(offset),'unixepoch','localtime')"

        let dayRows = try await queryRows(
            database: powerDatabase,
            sql: """
            SELECT
              date(\(wallTime)) AS day,
              COUNT(*) AS sample_count,
              ROUND(AVG(Temperature), 2) AS average_temperature,
              ROUND(MAX(Temperature), 2) AS maximum_temperature,
              ROUND(MIN(Level), 1) AS minimum_battery,
              ROUND(MAX(Level), 1) AS maximum_battery
            FROM PLBatteryAgent_EventBackward_Battery
            GROUP BY day
            ORDER BY day;
            """
        )

        var snapshots: [DailySnapshot] = []
        for dayRow in dayRows {
            guard let day = dayRow["day"], isSafeDate(day) else { continue }
            let snapshot = try await buildSnapshot(
                day: day,
                dayRow: dayRow,
                powerDatabase: powerDatabase,
                backgroundDatabase: prepared.backgroundDatabase,
                offset: offset
            )
            snapshots.append(snapshot)
        }

        var generalAlerts: [HealthAlert] = []
        if let batteryHealth {
            if batteryHealth < 80 {
                generalAlerts.append(
                    HealthAlert(
                        severity: .critical,
                        title: "电池健康明显衰减",
                        detail: "最大容量为 \(batteryHealth)%，建议联系 Apple 检测电池。"
                    )
                )
            } else if batteryHealth < 90 {
                generalAlerts.append(
                    HealthAlert(
                        severity: .warning,
                        title: "电池容量有所下降",
                        detail: "最大容量为 \(batteryHealth)%，高负载时更容易发热和降频。"
                    )
                )
            }
        }

        if let freeStorageGB {
            if freeStorageGB < 5 {
                generalAlerts.append(
                    HealthAlert(
                        severity: .critical,
                        title: "可用存储空间过低",
                        detail: String(format: "仅剩 %.1f GB，可能直接造成卡顿。", freeStorageGB)
                    )
                )
            } else if freeStorageGB < 10 {
                generalAlerts.append(
                    HealthAlert(
                        severity: .warning,
                        title: "建议释放存储空间",
                        detail: String(format: "当前约剩 %.1f GB，建议至少保留 10 GB。", freeStorageGB)
                    )
                )
            }
        }

        return DiagnosticReport(
            sourceName: sourceURL.lastPathComponent,
            importedAt: Date(),
            batteryHealthPercent: batteryHealth,
            cycleCount: cycleCount,
            freeStorageGB: freeStorageGB,
            days: snapshots.sorted { $0.date < $1.date },
            generalAlerts: generalAlerts
        )
    }

    private func buildSnapshot(
        day: String,
        dayRow: [String: String],
        powerDatabase: URL,
        backgroundDatabase: URL?,
        offset: String
    ) async throws -> DailySnapshot {
        let wallTime = "datetime(timestamp+\(offset),'unixepoch','localtime')"

        let temperatureRows = (try? await queryRows(
            database: powerDatabase,
            sql: """
            SELECT
              CAST(strftime('%H', \(wallTime)) AS INTEGER) AS hour,
              ROUND(AVG(Temperature), 2) AS average_temperature,
              ROUND(MAX(Temperature), 2) AS maximum_temperature
            FROM PLBatteryAgent_EventBackward_Battery
            WHERE date(\(wallTime)) = '\(day)'
            GROUP BY hour
            ORDER BY hour;
            """
        )) ?? []

        let temperaturePoints = temperatureRows.compactMap { row -> TemperaturePoint? in
            guard
                let hour = integer(row["hour"]),
                let average = double(row["average_temperature"]),
                let maximum = double(row["maximum_temperature"])
            else { return nil }
            return TemperaturePoint(
                hour: hour,
                averageCelsius: average,
                maximumCelsius: maximum
            )
        }

        let hotRows = (try? await queryRows(
            database: powerDatabase,
            sql: """
            WITH hot AS (
              SELECT
                timestamp,
                LAG(timestamp) OVER (ORDER BY timestamp) AS previous_timestamp
              FROM PLBatteryAgent_EventBackward_Battery
              WHERE date(\(wallTime)) = '\(day)'
                AND Temperature >= 40
            ),
            markers AS (
              SELECT
                timestamp,
                CASE
                  WHEN previous_timestamp IS NULL OR timestamp-previous_timestamp > 120 THEN 1
                  ELSE 0
                END AS new_group
              FROM hot
            ),
            grouped AS (
              SELECT
                timestamp,
                SUM(new_group) OVER (ORDER BY timestamp) AS group_id
              FROM markers
            ),
            episodes AS (
              SELECT MAX(timestamp)-MIN(timestamp) AS duration
              FROM grouped
              GROUP BY group_id
            )
            SELECT ROUND(COALESCE(SUM(duration), 0)/60.0, 1) AS hot_minutes
            FROM episodes;
            """
        )) ?? []
        let hotMinutes = hotRows.first.flatMap { double($0["hot_minutes"]) } ?? 0

        let memoryRows = (try? await queryRows(
            database: powerDatabase,
            sql: """
            SELECT
              ROUND(
                100.0 * SUM(CASE WHEN MemoryPressureLevel = 'warn' THEN 1 ELSE 0 END)
                / MAX(COUNT(*), 1),
                1
              ) AS warning_percent,
              ROUND(MAX(SwapUsedSize)/1048576.0, 1) AS maximum_swap_mb
            FROM PLPerformanceAgent_EventPoint_SystemMemory
            WHERE date(\(wallTime)) = '\(day)';
            """
        )) ?? []
        let memoryWarningPercent = memoryRows.first
            .flatMap { double($0["warning_percent"]) } ?? 0
        let maximumSwapMB = memoryRows.first
            .flatMap { double($0["maximum_swap_mb"]) } ?? 0

        let appRows = (try? await queryRows(
            database: powerDatabase,
            sql: """
            WITH ranked AS (
              SELECT
                \(wallTime) AS peak_time,
                AppBundleId,
                PeakMemory,
                SuspendedMemory,
                ROW_NUMBER() OVER (
                  PARTITION BY AppBundleId
                  ORDER BY PeakMemory DESC
                ) AS rank
              FROM PLApplicationAgent_EventBackward_ApplicationMemory
              WHERE date(\(wallTime)) = '\(day)'
            )
            SELECT
              AppBundleId AS bundle_id,
              peak_time,
              ROUND(PeakMemory/1048576.0, 1) AS peak_mb,
              ROUND(SuspendedMemory/1048576.0, 1) AS suspended_mb
            FROM ranked
            WHERE rank = 1
            ORDER BY peak_mb DESC
            LIMIT 12;
            """
        )) ?? []

        let topApps = appRows.compactMap { row -> AppMemoryMetric? in
            guard
                let bundleID = row["bundle_id"],
                let peakMB = double(row["peak_mb"])
            else { return nil }
            return AppMemoryMetric(
                bundleIdentifier: bundleID,
                peakMB: peakMB,
                suspendedMB: double(row["suspended_mb"]) ?? 0,
                peakTime: row["peak_time"] ?? ""
            )
        }

        let spotlightRows = (try? await queryRows(
            database: powerDatabase,
            sql: """
            SELECT
              CAST(COALESCE(SUM(IndexCount), 0) AS INTEGER) AS indexed_items
            FROM PLXPCAgent_EventInterval_SpotlightIndexes
            WHERE date(\(wallTime)) = '\(day)';
            """
        )) ?? []
        let spotlightIndexedItems = spotlightRows.first
            .flatMap { integer($0["indexed_items"]) } ?? 0

        var topProcesses: [ProcessMetric] = []
        if let backgroundDatabase {
            let processRows = (try? await queryRows(
                database: backgroundDatabase,
                sql: """
                SELECT
                  ProcessName AS process_name,
                  COUNT(*) AS instances,
                  ROUND(SUM(CPUTimeConsumed)/1000.0, 1) AS cpu_seconds,
                  ROUND(SUM(DiskIOConsumed)/1048576.0, 1) AS disk_read_mb,
                  ROUND(SUM(DiskIOWrites)/1048576.0, 1) AS disk_write_mb
                FROM BackgroundProcessing_TaskInstanceData_24_5
                WHERE date(StartDate, 'unixepoch', 'localtime') = '\(day)'
                GROUP BY ProcessName
                ORDER BY SUM(CPUTimeConsumed) DESC
                LIMIT 12;
                """
            )) ?? []

            topProcesses = processRows.compactMap { row -> ProcessMetric? in
                guard let name = row["process_name"], !name.isEmpty else { return nil }
                return ProcessMetric(
                    processName: name,
                    instances: integer(row["instances"]) ?? 0,
                    cpuSeconds: double(row["cpu_seconds"]) ?? 0,
                    diskReadMB: double(row["disk_read_mb"]) ?? 0,
                    diskWriteMB: double(row["disk_write_mb"]) ?? 0
                )
            }
        }

        let maximumTemperature = double(dayRow["maximum_temperature"]) ?? 0
        var alerts: [HealthAlert] = []

        if maximumTemperature >= 43 {
            alerts.append(
                HealthAlert(
                    severity: .critical,
                    title: "检测到明显高温",
                    detail: String(
                        format: "最高 %.2f°C，40°C 以上累计约 %.1f 分钟。",
                        maximumTemperature,
                        hotMinutes
                    )
                )
            )
        } else if maximumTemperature >= 40 {
            alerts.append(
                HealthAlert(
                    severity: .warning,
                    title: "存在持续发热",
                    detail: String(format: "当天最高 %.2f°C。", maximumTemperature)
                )
            )
        }

        if memoryWarningPercent >= 20 {
            alerts.append(
                HealthAlert(
                    severity: .warning,
                    title: "内存压力偏高",
                    detail: String(
                        format: "%.1f%% 的采样进入警告状态，容易出现掉帧和应用重载。",
                        memoryWarningPercent
                    )
                )
            )
        }

        if let largestApp = topApps.first, largestApp.peakMB >= 1_000 {
            alerts.append(
                HealthAlert(
                    severity: .warning,
                    title: "单个应用占用内存过高",
                    detail: String(
                        format: "%@ 峰值约 %.0f MB。",
                        largestApp.bundleIdentifier,
                        largestApp.peakMB
                    )
                )
            )
        }

        if let suggestions = topProcesses.first(where: { $0.processName == "suggestd" }),
           suggestions.cpuSeconds >= 1_800 {
            alerts.append(
                HealthAlert(
                    severity: .warning,
                    title: "系统建议与搜索后台活动异常",
                    detail: String(
                        format: "suggestd 累计约 %.0f 秒 CPU、写入 %.0f MB。",
                        suggestions.cpuSeconds,
                        suggestions.diskWriteMB
                    )
                )
            )
        }

        if spotlightIndexedItems >= 5_000 {
            alerts.append(
                HealthAlert(
                    severity: .info,
                    title: "Spotlight 索引量较大",
                    detail: "当天记录了 \(spotlightIndexedItems) 个索引项目。"
                )
            )
        }

        return DailySnapshot(
            date: day,
            sampleCount: integer(dayRow["sample_count"]) ?? 0,
            averageTemperature: double(dayRow["average_temperature"]) ?? 0,
            maximumTemperature: maximumTemperature,
            hotMinutes: hotMinutes,
            minimumBatteryPercent: double(dayRow["minimum_battery"]) ?? 0,
            maximumBatteryPercent: double(dayRow["maximum_battery"]) ?? 0,
            memoryWarningPercent: memoryWarningPercent,
            maximumSwapMB: maximumSwapMB,
            spotlightIndexedItems: spotlightIndexedItems,
            temperaturePoints: temperaturePoints,
            topApps: topApps,
            topProcesses: topProcesses,
            alerts: alerts
        )
    }

    private func prepareSource(_ sourceURL: URL) async throws -> PreparedSource {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw DiagnosticAnalyzerError.unsupportedSource
        }

        if isDirectory.boolValue {
            return locateFiles(in: sourceURL, cleanupURL: nil)
        }

        let lowercasedName = sourceURL.lastPathComponent.lowercased()
        guard lowercasedName.hasSuffix(".tar.gz") || lowercasedName.hasSuffix(".tgz") else {
            throw DiagnosticAnalyzerError.unsupportedSource
        }

        let listing = await ProcessRunner.run(
            executable: "/usr/bin/tar",
            arguments: ["-tzf", sourceURL.path],
            timeout: 120
        )
        guard listing.exitCode == 0, !listing.timedOut else {
            throw DiagnosticAnalyzerError.archiveReadFailed(
                listing.errorOutput.isEmpty ? "命令超时" : listing.errorOutput
            )
        }

        let entries = listing.output
            .split(separator: "\n")
            .map(String.init)
        let selectedEntries = entries.filter { entry in
            guard isSafeArchivePath(entry) else { return false }
            let lower = entry.lowercased()
            return lower.hasSuffix(".plsql")
                || lower.hasSuffix(".bgsql")
                || lower.hasSuffix("/batteryhealth.log")
                || lower.hasSuffix("/disks.txt")
        }

        guard selectedEntries.contains(where: { $0.lowercased().hasSuffix(".plsql") }) else {
            throw DiagnosticAnalyzerError.missingPowerLog
        }

        let cacheRoot = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let extractionDirectory = cacheRoot
            .appendingPathComponent("iPhoneMonitor", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )

        let extraction = await ProcessRunner.run(
            executable: "/usr/bin/tar",
            arguments: ["-xzf", sourceURL.path, "-C", extractionDirectory.path]
                + selectedEntries,
            timeout: 180
        )
        guard extraction.exitCode == 0, !extraction.timedOut else {
            try? fileManager.removeItem(at: extractionDirectory)
            throw DiagnosticAnalyzerError.extractionFailed(
                extraction.errorOutput.isEmpty ? "命令超时" : extraction.errorOutput
            )
        }

        return locateFiles(
            in: extractionDirectory,
            cleanupURL: extractionDirectory
        )
    }

    private func locateFiles(in root: URL, cleanupURL: URL?) -> PreparedSource {
        var powerDatabase: URL?
        var backgroundDatabase: URL?
        var batteryHealthLog: URL?
        var disksFile: URL?

        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let name = fileURL.lastPathComponent.lowercased()
            if name.hasSuffix(".plsql"), name.hasPrefix("powerlog_") {
                powerDatabase = fileURL
            } else if name.hasSuffix(".bgsql") {
                backgroundDatabase = fileURL
            } else if name == "batteryhealth.log" {
                let isDetailedLog = fileURL.path.contains("/logs/BatteryHealth/")
                if batteryHealthLog == nil || isDetailedLog {
                    batteryHealthLog = fileURL
                }
            } else if name == "disks.txt" {
                disksFile = fileURL
            }
        }

        return PreparedSource(
            powerDatabase: powerDatabase,
            backgroundDatabase: backgroundDatabase,
            batteryHealthLog: batteryHealthLog,
            disksFile: disksFile,
            cleanupURL: cleanupURL
        )
    }

    private func queryRows(
        database: URL,
        sql: String
    ) async throws -> [[String: String]] {
        let result = await ProcessRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-header", "-separator", "\t", database.path, sql],
            timeout: 60
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw DiagnosticAnalyzerError.queryFailed(
                result.errorOutput.isEmpty ? "查询超时" : result.errorOutput
            )
        }

        let lines = result.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let headerLine = lines.first else { return [] }
        let headers = headerLine.split(
            separator: "\t",
            omittingEmptySubsequences: false
        ).map(String.init)

        return lines.dropFirst().map { line in
            let values = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            return Dictionary(
                uniqueKeysWithValues: headers.enumerated().map { index, header in
                    (header, index < values.count ? values[index] : "")
                }
            )
        }
    }

    private func integer(_ value: String?) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        return Int(value) ?? Double(value).map(Int.init)
    }

    private func double(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return Double(value)
    }

    private func isSafeDate(_ value: String) -> Bool {
        value.range(
            of: #"^\d{4}-\d{2}-\d{2}$"#,
            options: .regularExpression
        ) != nil
    }

    private func isSafeArchivePath(_ value: String) -> Bool {
        guard !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.hasPrefix("-") else {
            return false
        }
        return !value.split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
    }
}

private struct PreparedSource {
    let powerDatabase: URL?
    let backgroundDatabase: URL?
    let batteryHealthLog: URL?
    let disksFile: URL?
    let cleanupURL: URL?
}

public enum DiagnosticTextParser {
    public static func batteryHealthPercent(from text: String) -> Int? {
        let pattern = #""Maximum Capacity Percent"\s*=\s*(\d+)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    public static func freeStorageGB(from text: String) -> Double? {
        let lines = text.split(separator: "\n")
        guard let mobileLine = lines.first(where: {
            $0.hasSuffix("/private/var/mobile")
        }) else { return nil }

        let columns = mobileLine.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 4 else { return nil }
        return storageValueInGB(String(columns[3]))
    }

    private static func storageValueInGB(_ value: String) -> Double? {
        guard let unit = value.last else { return nil }
        let numberText = String(value.dropLast())
        guard let number = Double(numberText) else { return nil }

        switch unit {
        case "T", "t": return number * 1_024
        case "G", "g": return number
        case "M", "m": return number / 1_024
        case "K", "k": return number / 1_048_576
        default: return Double(value).map { $0 / 1_073_741_824 }
        }
    }
}
