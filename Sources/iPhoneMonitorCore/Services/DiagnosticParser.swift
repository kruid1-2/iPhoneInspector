import Foundation

public struct ParsedDiagnosticFile: Sendable {
    public var records: [DiagnosticRecord]
    public var battery: BatteryInformation
    public var storage: StorageInformation

    public init(
        records: [DiagnosticRecord],
        battery: BatteryInformation = BatteryInformation(),
        storage: StorageInformation = StorageInformation()
    ) {
        self.records = records
        self.battery = battery
        self.storage = storage
    }
}

public struct DiagnosticParser: Sendable {
    public init() {}

    public func parse(data: Data, fileName: String) throws -> ParsedDiagnosticFile {
        guard !data.isEmpty else {
            throw DiagnosticParserError.emptyFile
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw DiagnosticParserError.unsupportedEncoding
        }
        return parse(text: text, fileName: fileName)
    }

    public func parse(text: String, fileName: String) -> ParsedDiagnosticFile {
        let jsonObjects = jsonObjects(from: text)
        let flattenedJSON = jsonObjects.map(JSONLookup.flattenedText).joined(separator: " ")
        let searchable = "\(fileName)\n\(text.prefix(2_000_000))\n\(flattenedJSON)"
        let lower = searchable.lowercased()
        let timestamp = extractDate(jsonObjects: jsonObjects, text: text)
        let processName = extractProcessName(jsonObjects: jsonObjects, text: text)

        var categories: [DiagnosticCategory] = []
        if isPanic(fileName: fileName, lower: lower, jsonObjects: jsonObjects) {
            categories.append(.panic)
        }
        if containsAny(lower, ["jetsamevent", "jetsam_event", "memorystatus_kill"]) {
            categories.append(.jetsam)
        } else if containsAny(lower, ["lowmemory", "low memory", "memory pressure"]) {
            categories.append(.lowMemory)
        }
        if containsAny(lower, [
            "thermal pressure", "thermalpressure", "thermal level",
            "thermalmonitord", "thermal state"
        ]) {
            categories.append(.thermal)
        }
        if containsAny(lower, ["watchdog", "watchdog timeout", "watchdogtransgression"]) {
            categories.append(.watchdog)
        }
        if containsAny(lower, ["reset counter", "resetcount", "unexpected reset"]) {
            categories.append(.reset)
        }
        if containsAny(lower, ["springboard"]) {
            categories.append(.springBoard)
        }
        if containsAny(lower, ["backboardd"]) {
            categories.append(.backboard)
        }
        if containsAny(lower, [
            "exception type", "\"exception\"", "termination reason",
            "crashreporter key", "incident identifier"
        ]), !categories.contains(.panic) {
            categories.append(.crash)
        }
        if containsAny(lower, [
            "maximum capacity percent", "cyclecount", "battery health",
            "designcapacity", "nominalchargecapacity"
        ]) {
            categories.append(.battery)
        }
        if containsAny(lower, [
            "amountdataavailable", "totaldatacapacity",
            "/private/var/mobile", "disk space", "no space left"
        ]) {
            categories.append(.storage)
        }

        if categories.isEmpty {
            categories = [.unknown]
        }

        let uniqueCategories = Array(Set(categories)).sorted { $0.rawValue < $1.rawValue }
        let records = uniqueCategories.prefix(8).map { category in
            DiagnosticRecord(
                category: category,
                timestamp: timestamp,
                processName: processName,
                summary: summary(
                    for: category,
                    processName: processName,
                    fileName: fileName
                ),
                evidence: evidence(for: category, in: text),
                sourceFile: fileName,
                confidence: category == .unknown ? .low : .medium
            )
        }

        return ParsedDiagnosticFile(
            records: records,
            battery: parseBattery(from: text),
            storage: parseStorage(from: text)
        )
    }

    public func parseIPS(text: String, fileName: String = "report.ips") -> ParsedDiagnosticFile {
        parse(text: text, fileName: fileName)
    }

    private func isPanic(
        fileName: String,
        lower: String,
        jsonObjects: [Any]
    ) -> Bool {
        let lowerName = fileName.lowercased()
        if lowerName.contains("panic-full") || lowerName.contains("panic-base") {
            return true
        }
        if containsAny(lower, [
            "panicstring", "panic string", "kernel panic",
            "\"bug_type\":\"210\"", "\"bug_type\": \"210\""
        ]) {
            return true
        }
        return jsonObjects.contains { object in
            guard let dictionary = object as? [String: Any] else { return false }
            return JSONLookup.string(in: dictionary, keys: ["bug_type", "bugType"]) == "210"
        }
    }

    private func parseBattery(from text: String) -> BatteryInformation {
        let source = "导入的诊断日志"
        let health = firstInteger(
            in: text,
            patterns: [
                #""Maximum Capacity Percent"\s*[=:]\s*(\d+)"#,
                #""?batteryHealthMetric"?\s*[=:]\s*(\d+)"#,
                #"\bBattery Health\b[^0-9]{0,20}(\d{1,3})"#
            ]
        )
        let cycle = firstInteger(
            in: text,
            patterns: [
                #""?CycleCount"?\s*[=:]\s*(\d+)"#,
                #""?cycle_count"?\s*[=:]\s*(\d+)"#
            ]
        )
        let design = firstInteger(
            in: text,
            patterns: [#""?DesignCapacity"?\s*[=:]\s*(\d+)"#]
        )
        let maximum = firstInteger(
            in: text,
            patterns: [
                #""?NominalChargeCapacity"?\s*[=:]\s*(\d+)"#,
                #""?AppleRawMaxCapacity"?\s*[=:]\s*(\d+)"#
            ]
        )
        let lower = text.lowercased()
        let verificationStatus: DataValue<String>
        if lower.contains("unable to verify this iphone has a genuine apple battery")
            || lower.contains("important battery message")
            || lower.contains("battery authenticity") {
            verificationStatus = .available(
                "日志出现 Apple 无法验证电池的提示",
                source: source,
                confidence: .medium
            )
        } else {
            verificationStatus = .missing(.notReturned, source: source)
        }
        let now = Date()

        return BatteryInformation(
            healthPercent: health.map {
                .available($0, source: source, confidence: .medium, updatedAt: now)
            } ?? .missing(.requiresDiagnosticLog, source: source),
            designCapacityMAh: design.map {
                .available($0, source: source, confidence: .medium, updatedAt: now)
            } ?? .missing(.requiresDiagnosticLog, source: source),
            maximumCapacityMAh: maximum.map {
                .available($0, source: source, confidence: .medium, updatedAt: now)
            } ?? .missing(.requiresDiagnosticLog, source: source),
            cycleCount: cycle.map {
                .available($0, source: source, confidence: .medium, updatedAt: now)
            } ?? .missing(.requiresDiagnosticLog, source: source),
            verificationStatus: verificationStatus,
            latestLogDate: health != nil || cycle != nil ? now : nil
        )
    }

    private func parseStorage(from text: String) -> StorageInformation {
        let dataSource = "诊断日志 / data capacity"
        let diskSource = "诊断日志 / disk capacity"
        let dataTotal = firstCapture(
            in: text,
            patterns: [
                #""?TotalDataCapacity"?\s*[=:]\s*"?([0-9.]+\s*[KMGT]?B?)"#
            ]
        ).flatMap(CapacityParser.bytes)
        let dataAvailable = firstCapture(
            in: text,
            patterns: [
                #""?AmountDataAvailable"?\s*[=:]\s*"?([0-9.]+\s*[KMGT]?B?)"#
            ]
        ).flatMap(CapacityParser.bytes)
        let diskTotal = firstCapture(
            in: text,
            patterns: [
                #""?TotalDiskCapacity"?\s*[=:]\s*"?([0-9.]+\s*[KMGT]?B?)"#
            ]
        ).flatMap(CapacityParser.bytes)
        let diskAvailable = firstCapture(
            in: text,
            patterns: [
                #""?AmountDiskAvailable"?\s*[=:]\s*"?([0-9.]+\s*[KMGT]?B?)"#
            ]
        ).flatMap(CapacityParser.bytes)

        let source: String
        let total: Int64?
        let available: Int64?
        let totalRawField: String?
        let availableRawField: String?
        if dataTotal != nil, dataAvailable != nil {
            source = dataSource
            total = dataTotal
            available = dataAvailable
            totalRawField = "TotalDataCapacity"
            availableRawField = "AmountDataAvailable"
        } else if diskTotal != nil, diskAvailable != nil {
            source = diskSource
            total = diskTotal
            available = diskAvailable
            totalRawField = "TotalDiskCapacity"
            availableRawField = "AmountDiskAvailable"
        } else if dataTotal != nil || dataAvailable != nil {
            source = dataSource
            total = dataTotal
            available = dataAvailable
            totalRawField = dataTotal == nil ? nil : "TotalDataCapacity"
            availableRawField = dataAvailable == nil ? nil : "AmountDataAvailable"
        } else if diskTotal != nil || diskAvailable != nil {
            source = diskSource
            total = diskTotal
            available = diskAvailable
            totalRawField = diskTotal == nil ? nil : "TotalDiskCapacity"
            availableRawField = diskAvailable == nil ? nil : "AmountDiskAvailable"
        } else if let freeGB = DiagnosticTextParser.freeStorageGB(from: text) {
            source = "诊断日志 / free storage summary"
            total = nil
            available = Int64(freeGB * 1_024 * 1_024 * 1_024)
            totalRawField = nil
            availableRawField = "FreeStorageGB"
        } else {
            source = "导入的诊断日志"
            total = nil
            available = nil
            totalRawField = nil
            availableRawField = nil
        }
        let now = Date()
        let used: Int64?
        if let total, let available, total >= available {
            used = total - available
        } else {
            used = nil
        }

        return StorageInformation(
            totalBytes: total.map {
                .available(
                    $0,
                    source: source,
                    rawFieldName: totalRawField,
                    confidence: .medium,
                    updatedAt: now
                )
            } ?? .missing(.notReturned, source: source),
            availableBytes: available.map {
                .available(
                    $0,
                    source: source,
                    rawFieldName: availableRawField,
                    confidence: .medium,
                    updatedAt: now
                )
            } ?? .missing(.notReturned, source: source),
            usedBytes: used.map {
                .available(
                    $0,
                    source: source,
                    rawFieldName: [
                        totalRawField,
                        availableRawField
                    ].compactMap { $0 }.joined(separator: " - "),
                    detail: "由同一诊断数据域的总容量减去可用容量",
                    confidence: .medium,
                    updatedAt: now
                )
            } ?? .missing(.notReturned, source: source),
            updatedAt: total != nil || available != nil ? now : nil
        )
    }

    private func summary(
        for category: DiagnosticCategory,
        processName: String?,
        fileName: String
    ) -> String {
        let processSuffix = processName.map { "，涉及进程 \($0)" } ?? ""
        switch category {
        case .panic:
            return "日志包含 panic 或异常重启记录\(processSuffix)"
        case .jetsam:
            return "系统因内存压力终止了进程\(processSuffix)"
        case .lowMemory:
            return "日志记录了内存压力事件\(processSuffix)"
        case .thermal:
            return "日志包含热压力或温控相关记录"
        case .watchdog:
            return "日志包含看门狗超时记录\(processSuffix)"
        case .crash:
            return "日志包含进程崩溃记录\(processSuffix)"
        case .reset:
            return "日志包含设备重启计数或意外重启记录"
        case .battery:
            return "日志包含电池相关字段"
        case .storage:
            return "日志包含存储容量或空间不足记录"
        case .springBoard:
            return "日志提到 SpringBoard\(processSuffix)"
        case .backboard:
            return "日志提到 backboardd\(processSuffix)"
        case .power:
            return "PowerLog 中包含可理解的历史摘要"
        case .unknown:
            return "已保留 \(fileName) 的原始摘要，但当前解析器无法确定类型"
        }
    }

    private func evidence(for category: DiagnosticCategory, in text: String) -> String {
        let keywords: [String]
        switch category {
        case .panic: keywords = ["panicString", "panic string", "kernel panic", "bug_type"]
        case .jetsam: keywords = ["JetsamEvent", "memorystatus", "largestProcess"]
        case .lowMemory: keywords = ["LowMemory", "memory pressure"]
        case .thermal: keywords = ["thermal pressure", "thermal", "ThermalLevel"]
        case .watchdog: keywords = ["watchdog", "watchdog timeout"]
        case .crash: keywords = ["Exception Type", "termination reason", "incident"]
        case .reset: keywords = ["reset counter", "unexpected reset"]
        case .battery: keywords = ["Maximum Capacity", "CycleCount", "DesignCapacity"]
        case .storage: keywords = ["AmountDataAvailable", "/private/var/mobile", "no space"]
        case .springBoard: keywords = ["SpringBoard"]
        case .backboard: keywords = ["backboardd"]
        case .power: keywords = ["PowerLog"]
        case .unknown: keywords = []
        }

        let lines = text.split(whereSeparator: \.isNewline)
        if let line = lines.first(where: { line in
            keywords.contains { line.localizedCaseInsensitiveContains($0) }
        }) {
            return sanitizedEvidence(String(line))
        }
        return sanitizedEvidence(String(text.prefix(500)))
    }

    private func sanitizedEvidence(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"[A-Fa-f0-9]{20,}"#,
                with: "••••",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
            .description
    }

    private func extractProcessName(jsonObjects: [Any], text: String) -> String? {
        for object in jsonObjects {
            if let dictionary = object as? [String: Any],
               let value = JSONLookup.string(
                   in: dictionary,
                   keys: ["procName", "processName", "bundleID", "name"]
               ),
               !value.isEmpty {
                return String(value.prefix(120))
            }
        }
        return firstCapture(
            in: text,
            patterns: [
                #""(?:procName|processName)"\s*:\s*"([^"]+)""#,
                #"\bProcess:\s*([^\s\[]+)"#,
                #"\bPath:\s*.*/([^/\s]+)"#
            ]
        ).map { String($0.prefix(120)) }
    }

    private func extractDate(jsonObjects: [Any], text: String) -> Date? {
        for object in jsonObjects {
            if let dictionary = object as? [String: Any],
               let raw = JSONLookup.string(
                   in: dictionary,
                   keys: ["timestamp", "captureTime", "date", "time"]
               ),
               let date = DiagnosticDateParser.date(from: raw) {
                return date
            }
        }
        return firstCapture(
            in: text,
            patterns: [
                #"(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)"#
            ]
        ).flatMap(DiagnosticDateParser.date)
    }

    private func jsonObjects(from text: String) -> [Any] {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return [object]
        }

        return text.split(whereSeparator: \.isNewline).prefix(3).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }

    private func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains(where: text.contains)
    }

    private func firstInteger(in text: String, patterns: [String]) -> Int? {
        firstCapture(in: text, patterns: patterns).flatMap(Int.init)
    }

    private func firstCapture(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ),
                let match = regex.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                ),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: text)
            else { continue }
            return String(text[range])
        }
        return nil
    }
}

public enum DiagnosticParserError: LocalizedError {
    case emptyFile
    case unsupportedEncoding

    public var errorDescription: String? {
        switch self {
        case .emptyFile: return "文件为空"
        case .unsupportedEncoding: return "文件不是可识别的文本编码"
        }
    }
}

enum DiagnosticDateParser {
    static func date(from value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        for format in [
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
