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
                    let presentation = lagPresentation(summary)
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

                        summaryRow("整体负载", presentation.processor)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("当时较忙").font(.caption).foregroundStyle(.secondary)
                            if presentation.relatedProcesses.isEmpty {
                                Text("进程数据不足")
                            } else {
                                ForEach(presentation.relatedProcesses) { process in
                                    Text("• \(process.displayName)")
                                        .help("PID \(process.pid.map(String.init) ?? "—") · 处理器负载原始值 \(format(process.cpuRaw))")
                                }
                            }
                        }

                        summaryRow("应用内存", presentation.applicationMemory)
                        summaryRow("系统内存", presentation.systemMemory)
                        summaryRow("电池温度", batteryText(summary, trend: presentation.batteryTemperature))
                        summaryRow("系统能耗", presentation.energy)
                        summaryRow(
                            "数据完整性",
                            "\(presentation.dataIntegrity)：\(presentation.dataIntegrityDetail)"
                        )

                        Divider()
                        Text("观察结果")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(presentation.overview)
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

    private func batteryText(_ summary: PerformanceLagSummary, trend: String) -> String {
        guard let start = summary.batteryTemperatureStartRaw,
              let end = summary.batteryTemperatureEndRaw
        else { return trend }
        return "\(trend)（原始值 \(format(start)) → \(format(end))）"
    }

    private func windowDescription(_ summary: PerformanceLagSummary) -> String {
        "卡顿前 \(Int(summary.preWindowSeconds.rounded())) 秒 · 后 \(Int(summary.postWindowSeconds.rounded())) 秒"
    }

    private func lagPresentation(_ summary: PerformanceLagSummary) -> PerformanceLagDiagnosticPresentation {
        PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary,
            processDisplayName: { AppNameResolver.displayName(for: $0) }
        )
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}
