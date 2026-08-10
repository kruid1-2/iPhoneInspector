import Foundation

public struct RiskAnalysisService: Sendable {
    public init() {}

    public func analyze(
        device: ConnectedDevice?,
        battery: BatteryInformation,
        storage: StorageInformation,
        records: [DiagnosticRecord],
        now: Date = Date()
    ) -> [RiskFinding] {
        var findings: [RiskFinding] = []
        findings.append(contentsOf: storageFindings(storage))
        findings.append(contentsOf: rebootFindings(records, now: now))
        findings.append(contentsOf: memoryFindings(records, now: now))
        findings.append(contentsOf: crashFindings(records, now: now))
        findings.append(contentsOf: thermalFindings(records, now: now))
        findings.append(contentsOf: batteryFindings(battery, device: device))
        findings.append(contentsOf: backgroundTaskFindings(records))

        if let total = storage.totalBytes.value,
           let available = storage.availableBytes.value,
           available > total {
            findings.append(
                RiskFinding(
                    id: "storage-conflict",
                    title: "存储数据相互矛盾",
                    level: .insufficient,
                    summary: "可用容量大于总容量，需要进一步验证。",
                    evidence: ["总容量 \(total) 字节；可用容量 \(available) 字节"],
                    sources: [storage.totalBytes.source, storage.availableBytes.source],
                    confidence: .low,
                    recommendation: "重新连接并刷新，或导入一份新的诊断日志。",
                    userActionable: true
                )
            )
        }

        if storage.totalBytes.value != nil,
           storage.availableBytes.value != nil,
           storage.totalBytes.source != storage.availableBytes.source {
            findings.append(
                RiskFinding(
                    id: "storage-source-mismatch",
                    title: "存储容量口径需要验证",
                    level: .insufficient,
                    summary: "总容量与可用容量来自不同数据域，本次没有据此计算已用比例。",
                    evidence: [
                        "总容量来源：\(storage.totalBytes.source)",
                        "可用容量来源：\(storage.availableBytes.source)"
                    ],
                    sources: [
                        storage.totalBytes.source,
                        storage.availableBytes.source
                    ],
                    confidence: .high,
                    recommendation: "重新连接并刷新，等待同一提供器返回完整容量字段。",
                    userActionable: true
                )
            )
        }

        if findings.isEmpty {
            findings.append(
                RiskFinding(
                    id: "insufficient-data",
                    title: "当前信息不足",
                    level: .insufficient,
                    summary: "基于当前可读取数据，尚不能解释卡顿、发热或掉电原因。",
                    evidence: device == nil
                        ? ["没有可读取的已连接 iPhone，也没有触发风险的日志记录。"]
                        : ["设备已连接，但可用诊断字段不足。"],
                    sources: device?.sources ?? ["本地分析"],
                    confidence: .high,
                    recommendation: "保持手机连接并解锁，然后刷新；如问题持续，请导入 sysdiagnose 或“分析数据”中的 .ips 文件。",
                    userActionable: true
                )
            )
        }

        return findings.sorted {
            if $0.level != $1.level { return $0.level > $1.level }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public func storageRiskLevel(
        totalBytes: Int64?,
        availableBytes: Int64?
    ) -> RiskLevel {
        guard let availableBytes, availableBytes >= 0 else { return .insufficient }
        let fiveGB = Int64(5 * 1_024 * 1_024 * 1_024)
        if availableBytes < fiveGB { return .high }
        guard let totalBytes, totalBytes > 0, availableBytes <= totalBytes else {
            return .insufficient
        }
        let ratio = Double(availableBytes) / Double(totalBytes)
        if ratio < 0.08 { return .high }
        if ratio < 0.15 { return .notice }
        return .normal
    }

    public func storageRiskLevel(_ storage: StorageInformation) -> RiskLevel {
        guard
            let available = storage.availableBytes.value,
            available >= 0,
            storage.availableBytes.availability == .available
        else { return .insufficient }

        let fiveGB = Int64(5 * 1_024 * 1_024 * 1_024)
        if available < fiveGB { return .high }
        guard let fraction = storage.usageFraction else { return .insufficient }
        let availableFraction = 1 - fraction
        if availableFraction < 0.08 { return .high }
        if availableFraction < 0.15 { return .notice }
        return .normal
    }

    private func storageFindings(_ storage: StorageInformation) -> [RiskFinding] {
        let level = storageRiskLevel(storage)
        guard level != .normal, level != .insufficient else { return [] }
        let availableText = storage.availableBytes.value.map(ByteCountFormatter.string) ?? "未知"
        let ratioText: String
        if let fraction = storage.usageFraction {
            ratioText = String(format: "%.1f%%", 100 * (1 - fraction))
        } else {
            ratioText = "比例未知"
        }

        return [
            RiskFinding(
                id: "storage-low",
                title: level >= .high ? "可用存储空间过低" : "存储空间偏紧张",
                level: level,
                summary: "剩余空间不足可能造成写入变慢、应用卡顿和系统任务失败。",
                evidence: ["可用 \(availableText)，占总容量 \(ratioText)"],
                sources: [storage.availableBytes.source, storage.totalBytes.source],
                timestamp: storage.updatedAt,
                confidence: storage.availableBytes.confidence,
                recommendation: "优先清理可确认的大文件和离线下载，避免立即抹掉或刷机；清理后重新启动并观察。",
                userActionable: true
            )
        ]
    }

    private func rebootFindings(
        _ records: [DiagnosticRecord],
        now: Date
    ) -> [RiskFinding] {
        let recent = recentRecords(records, now: now)
        let panics = recent.filter { $0.category == .panic }
        let watchdogs = recent.filter { $0.category == .watchdog }
        var findings: [RiskFinding] = []

        if !panics.isEmpty {
            let level: RiskLevel = panics.count >= 3 ? .high : .moderate
            findings.append(
                finding(
                    id: "panic-count",
                    title: "检测到异常重启 / panic 记录",
                    level: level,
                    summary: "短期 panic 需要结合日志内容判断，不能仅凭次数断言硬件损坏。",
                    records: panics,
                    recommendation: panics.count >= 3
                        ? "备份重要数据，并携带 panic 日志联系 Apple 或可信维修方进一步检测。"
                        : "记录下一次重启时间；如再次发生，请导入新的 panic-full 日志。",
                    actionable: true
                )
            )
        }
        if watchdogs.count >= 2 {
            findings.append(
                finding(
                    id: "watchdog-count",
                    title: "多次看门狗超时",
                    level: .high,
                    summary: "系统或关键进程多次未能及时响应，可能表现为卡死或自动重启。",
                    records: watchdogs,
                    recommendation: "先正常重启并确保有足够存储空间；若继续发生，保留日志供进一步分析。",
                    actionable: true
                )
            )
        }
        return findings
    }

    private func memoryFindings(
        _ records: [DiagnosticRecord],
        now: Date
    ) -> [RiskFinding] {
        let memory = recentRecords(records, now: now).filter {
            $0.category == .jetsam || $0.category == .lowMemory
        }
        guard memory.count >= 2 else { return [] }
        return [
            finding(
                id: "memory-pressure",
                title: "多次 Jetsam / 内存压力",
                level: memory.count >= 5 ? .high : .moderate,
                summary: "系统多次回收或终止进程，可能造成应用重载和明显掉帧。",
                records: memory,
                recommendation: "更新频繁触发的应用，减少同时运行的重型任务，并在复现后导入新的 JetsamEvent。",
                actionable: true
            )
        ]
    }

    private func crashFindings(
        _ records: [DiagnosticRecord],
        now: Date
    ) -> [RiskFinding] {
        let crashes = recentRecords(records, now: now).filter {
            $0.category == .crash || $0.category == .springBoard || $0.category == .backboard
        }
        let grouped = Dictionary(grouping: crashes) {
            $0.processName ?? $0.category.label
        }
        guard let frequent = grouped.max(by: { $0.value.count < $1.value.count }),
              frequent.value.count >= 3 else { return [] }
        return [
            finding(
                id: "crash-\(frequent.key)",
                title: "\(frequent.key) 持续崩溃",
                level: .moderate,
                summary: "同一进程在短期内出现多条崩溃记录。",
                records: frequent.value,
                recommendation: "更新相关应用或系统；如果是系统进程，请保留日志并观察是否与特定操作同时出现。",
                actionable: !frequent.key.lowercased().contains("springboard")
            )
        ]
    }

    private func thermalFindings(
        _ records: [DiagnosticRecord],
        now: Date
    ) -> [RiskFinding] {
        let thermal = recentRecords(records, now: now).filter { $0.category == .thermal }
        guard !thermal.isEmpty else { return [] }
        return [
            finding(
                id: "thermal-pressure",
                title: "日志出现热压力记录",
                level: thermal.count >= 2 ? .high : .notice,
                summary: "热压力可能导致系统主动限制性能；日志只说明当时发生过温控事件。",
                records: thermal,
                recommendation: "暂停充电和高负载任务，取下影响散热的保护壳并让设备自然降温；不要放入冰箱或强制冷却。",
                actionable: true
            )
        ]
    }

    private func batteryFindings(
        _ battery: BatteryInformation,
        device: ConnectedDevice?
    ) -> [RiskFinding] {
        if let health = battery.healthPercent.value {
            if health < 80 {
                return [
                    RiskFinding(
                        id: "battery-health-low",
                        title: "电池最大容量明显偏低",
                        level: .high,
                        summary: "电池容量衰减可能放大掉电和高负载降频，但仍需结合设备表现确认。",
                        evidence: ["日志或工具返回最大容量 \(health)%"],
                        sources: [battery.healthPercent.source],
                        timestamp: battery.latestLogDate,
                        confidence: battery.healthPercent.confidence,
                        recommendation: "在备份数据后，由 Apple 或可信维修方进行电池检测。",
                        userActionable: false
                    )
                ]
            }
            if health < 90 {
                return [
                    RiskFinding(
                        id: "battery-health-notice",
                        title: "电池容量有所下降",
                        level: .notice,
                        summary: "容量下降可能缩短续航；第三方电池的报告值可能缺失或不准确。",
                        evidence: ["当前读取到 \(health)%"],
                        sources: [battery.healthPercent.source],
                        timestamp: battery.latestLogDate,
                        confidence: battery.healthPercent.confidence,
                        recommendation: "先观察充满电后的实际续航和异常发热，再决定是否检测电池。",
                        userActionable: true
                    )
                ]
            }
            return []
        }

        guard device != nil else { return [] }
        return [
            RiskFinding(
                id: "battery-data-missing",
                title: "电池底层数据未返回",
                level: .insufficient,
                summary: "未越狱 iPhone 或第三方更换电池可能不返回健康度、循环次数等字段；缺失本身不能证明电池损坏或非正品。",
                evidence: [battery.healthPercent.availability.message],
                sources: [battery.healthPercent.source],
                confidence: .high,
                recommendation: "可导入 sysdiagnose 或“分析数据”中的电池相关日志进行补充验证。",
                userActionable: true
            )
        ]
    }

    private func backgroundTaskFindings(_ records: [DiagnosticRecord]) -> [RiskFinding] {
        let text = records.map { "\($0.processName ?? "") \($0.evidence)" }
            .joined(separator: " ")
            .lowercased()
        guard ["photoanalysisd", "mediaanalysisd", "spotlight", "indexing"]
            .contains(where: text.contains) else { return [] }
        return [
            RiskFinding(
                id: "background-indexing",
                title: "可能存在系统后台索引任务",
                level: .notice,
                summary: "系统更新、照片同步或恢复备份后，索引和照片分析可能暂时增加发热与耗电。",
                evidence: ["日志提到照片分析或索引相关进程。"],
                sources: Array(
                    Array(Set(records.map(\.sourceFile))).sorted().prefix(3)
                ),
                confidence: .low,
                recommendation: "连接电源和 Wi‑Fi 静置一段时间后再比较；这只是可能性，不是确定结论。",
                userActionable: true
            )
        ]
    }

    private func recentRecords(
        _ records: [DiagnosticRecord],
        now: Date
    ) -> [DiagnosticRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        return records.filter { record in
            guard let timestamp = record.timestamp else { return true }
            return timestamp >= cutoff && timestamp <= now.addingTimeInterval(86_400)
        }
    }

    private func finding(
        id: String,
        title: String,
        level: RiskLevel,
        summary: String,
        records: [DiagnosticRecord],
        recommendation: String,
        actionable: Bool
    ) -> RiskFinding {
        RiskFinding(
            id: id,
            title: title,
            level: level,
            summary: summary,
            evidence: records.prefix(5).map { $0.evidence },
            sources: Array(Set(records.map(\.sourceFile))).sorted(),
            timestamp: records.compactMap(\.timestamp).max(),
            confidence: records.map(\.confidence).min(by: {
                confidenceRank($0) < confidenceRank($1)
            }) ?? .unknown,
            recommendation: recommendation,
            userActionable: actionable
        )
    }

    private func confidenceRank(_ value: DataConfidence) -> Int {
        switch value {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .unknown: return 0
        }
    }
}

private extension ByteCountFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
