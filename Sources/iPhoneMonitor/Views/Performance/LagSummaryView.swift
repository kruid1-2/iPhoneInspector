import SwiftUI
import iPhoneMonitorCore

struct LagSummaryView: View {
    let summary: PerformanceLagSummary?
    let isPending: Bool

    var body: some View {
        if isPending || summary != nil {
            SectionCard("最近一次卡顿") {
                if isPending {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在收集卡顿后的约 10 秒数据…")
                                .fontWeight(.medium)
                            Text("停止监控时也会使用已经收到的真实数据立即生成摘要。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let summary {
                    if isPending { Divider() }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(
                                summary.markerTimestamp.map(AppFormatters.date) ?? "时间未知",
                                systemImage: "flag.fill"
                            )
                            .foregroundStyle(.orange)
                            Spacer()
                            Text(windowDescription(summary))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        summaryRow("整体负载", cpuText(summary.cpuObservation))

                        VStack(alignment: .leading, spacing: 5) {
                            Text("当时较忙").font(.caption).foregroundStyle(.secondary)
                            if summary.busiestProcesses.isEmpty {
                                Text("进程数据不足")
                            } else {
                                ForEach(summary.busiestProcesses) { process in
                                    Text("• \(AppNameResolver.displayName(for: process.name))")
                                        .help("PID \(process.pid.map(String.init) ?? "—") · 处理器负载原始值 \(format(process.cpuRaw))")
                                }
                            }
                        }

                        summaryRow("应用内存", memoryText(summary.appMemory))
                        summaryRow("系统内存", systemMemoryText(summary))
                        summaryRow("电池温度", batteryText(summary))
                        summaryRow("系统能耗", energyText(summary.energyObservation))
                        summaryRow("数据完整性", integrityText(summary))

                        Divider()
                        Text("观察结果")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(conclusion(summary))
                            .fontWeight(.medium)
                    }
                }
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cpuText(_ observation: LagCPUObservation) -> String {
        switch observation {
        case .high: return "卡顿附近的处理器负载处于最近一段时间的较高水平"
        case .similar: return "卡顿附近的处理器负载与之前大致相近"
        case .noClearIncrease: return "卡顿附近的处理器负载没有明显升高"
        case .insufficientData: return "数据不足，无法比较卡顿前后的整体负载"
        }
    }

    private func memoryText(_ memory: LagMemoryObservation) -> String {
        var parts: [String] = []
        if let name = memory.largestProcessName, let value = memory.largestMiB {
            parts.append("\(AppNameResolver.displayName(for: name))当时约 \(String(format: "%.1f", value)) MiB")
        }
        if let name = memory.fastestGrowthProcessName, let growth = memory.growthMiB {
            parts.append("\(AppNameResolver.displayName(for: name))在分析窗口内增加约 \(String(format: "%.1f", growth)) MiB")
        }
        return parts.isEmpty ? "应用内存数据不足" : parts.joined(separator: "；")
    }

    private func systemMemoryText(_ summary: PerformanceLagSummary) -> String {
        let free = trendText(
            summary.freeMemoryTrend,
            increasing: "空闲内存页增加",
            stable: "空闲内存页基本稳定",
            decreasing: "空闲内存页减少"
        )
        let compressed = trendText(
            summary.compressorTrend,
            increasing: "压缩内存页增加",
            stable: "压缩内存页基本稳定",
            decreasing: "压缩内存页减少"
        )
        if free == "数据不足" && compressed == "数据不足" { return "系统内存趋势数据不足" }
        return "\(free)；\(compressed)。这里只观察趋势，不代表已经发生内存不足"
    }

    private func batteryText(_ summary: PerformanceLagSummary) -> String {
        let trend = trendText(
            summary.batteryTemperatureTrend,
            increasing: "正在升温",
            stable: "基本稳定",
            decreasing: "正在降温"
        )
        guard let start = summary.batteryTemperatureStartRaw,
              let end = summary.batteryTemperatureEndRaw
        else { return trend }
        return "\(trend)（原始值 \(format(start)) → \(format(end))）"
    }

    private func energyText(_ observation: LagEnergyObservation) -> String {
        switch observation {
        case .increased: return "卡顿附近的能耗评分有所升高"
        case .noClearChange: return "卡顿附近的能耗变化不明显"
        case .insufficientData: return "能耗数据不足"
        }
    }

    private func integrityText(_ summary: PerformanceLagSummary) -> String {
        guard summary.confidence == .incomplete else { return "良好" }
        var details: [String] = []
        if summary.streamGapCount > 0 {
            let duration = summary.streamGapSeconds > 0
                ? String(format: "约 %.1f 秒", summary.streamGapSeconds)
                : "时长未知"
            details.append("存在 \(summary.streamGapCount) 次数据中断（\(duration)）")
        }
        if summary.providerErrorCount > 0 { details.append("数据源错误 \(summary.providerErrorCount) 次") }
        if summary.droppedCount > 0 { details.append("队列丢弃 \(summary.droppedCount) 条") }
        return details.joined(separator: "；") + "，部分判断可能不完整"
    }

    private func conclusion(_ summary: PerformanceLagSummary) -> String {
        let names = summary.busiestProcesses.prefix(2).map {
            AppNameResolver.displayName(for: $0.name)
        }
        let processText = names.isEmpty ? "相关进程" : names.joined(separator: "、")
        if summary.cpuObservation == .high, (summary.appMemory.growthMiB ?? 0) > 0 {
            return "卡顿附近同时出现了较高的处理器活动和应用内存增长，\(processText)值得继续观察；这只是时间上接近的现象，不代表已经确定原因。"
        }
        if summary.cpuObservation == .high {
            return "卡顿附近处理器活动较高，\(processText)的活动可能相关，建议继续观察后续卡顿是否重复出现。"
        }
        if summary.freeMemoryTrend == .decreasing, summary.compressorTrend == .increasing {
            return "卡顿前后空闲内存页减少、压缩内存页增加，说明当时系统内存活动变重，值得继续观察。"
        }
        return "当前数据没有显示单一、明确的同步变化；建议在再次出现卡顿时继续标记并结合当时操作观察。"
    }

    private func windowDescription(_ summary: PerformanceLagSummary) -> String {
        "卡顿前 \(Int(summary.preWindowSeconds.rounded())) 秒 · 后 \(Int(summary.postWindowSeconds.rounded())) 秒"
    }

    private func trendText(
        _ trend: PerformanceTrendDirection,
        increasing: String,
        stable: String,
        decreasing: String
    ) -> String {
        switch trend {
        case .increasing: return increasing
        case .stable: return stable
        case .decreasing: return decreasing
        case .insufficientData: return "数据不足"
        }
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
