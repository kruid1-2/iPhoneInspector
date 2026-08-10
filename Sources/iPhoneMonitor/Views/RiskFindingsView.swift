import SwiftUI
import iPhoneMonitorCore

struct RiskFindingsView: View {
    let findings: [RiskFinding]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "风险提示",
                    subtitle: "这是基于当前可读取数据的本地规则分析，不是硬件故障的绝对结论。"
                )

                SectionCard("风险总览") {
                    HStack(spacing: 14) {
                        RiskLevelBadge(level: highestLevel)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(findings.count) 条分析结果")
                                .font(.headline)
                            Text("中等以上 \(findings.filter { $0.level >= .moderate }.count) 条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                ForEach(findings) { finding in
                    findingCard(finding)
                }
            }
            .padding(22)
        }
        .navigationTitle("风险提示")
    }

    private var highestLevel: RiskLevel {
        findings.map(\.level).max() ?? .insufficient
    }

    private func findingCard(_ finding: RiskFinding) -> some View {
        SectionCard(finding.title) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RiskLevelBadge(level: finding.level)
                    Text("可信度：\(finding.confidence.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let timestamp = finding.timestamp {
                        Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(finding.summary)
                    .fixedSize(horizontal: false, vertical: true)

                if !finding.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("证据")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(finding.evidence.filter { !$0.isEmpty }, id: \.self) { evidence in
                            Text("• \(evidence)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Divider()
                Label(finding.recommendation, systemImage: "arrow.right.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("来源：\(finding.sources.joined(separator: "、"))")
                    Spacer()
                    Text(finding.userActionable ? "可自行先处理" : "建议专业检测")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
