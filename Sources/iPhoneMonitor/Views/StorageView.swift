import SwiftUI
import iPhoneMonitorCore

struct StorageView: View {
    let storage: StorageInformation
    let riskService: RiskAnalysisService
    let isDemo: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "存储",
                    subtitle: "容量来自设备工具或导入日志；无法读取 App 分类占用时不会进行推测。"
                )

                SectionCard("容量概览") {
                    VStack(alignment: .leading, spacing: 14) {
                        if let fraction = storage.usageFraction {
                            ProgressView(value: fraction)
                                .tint(progressColor)
                            HStack {
                                Text("已使用 \(Int(fraction * 100))%")
                                Spacer()
                                RiskLevelBadge(level: riskLevel)
                            }
                        } else {
                            Text("当前没有足够信息计算使用比例。")
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                        storageField("总容量", storage.totalBytes)
                        Divider()
                        storageField("已使用容量", storage.usedBytes)
                        Divider()
                        storageField("可用容量", storage.availableBytes)
                        Divider()
                        storageField("可清理空间", storage.reclaimableBytes)
                    }
                }

                SectionCard("风险规则") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("可用空间低于总容量 15%：提醒", systemImage: "info.circle")
                        Label("可用空间低于总容量 8%：较高风险", systemImage: "exclamationmark.triangle")
                        Label("可用空间低于 5 GB：高风险", systemImage: "exclamationmark.octagon")
                        Text("规则统一由 RiskAnalysisService 计算，不在界面中臆测可清理容量。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SectionCard("App 存储分类") {
                    Label(
                        "当前 iOS 不允许本应用直接获得完整的 App 存储分类",
                        systemImage: "lock.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(22)
        }
        .navigationTitle("存储")
    }

    private var riskLevel: RiskLevel {
        riskService.storageRiskLevel(storage)
    }

    private var progressColor: Color {
        switch riskLevel {
        case .high, .severe: return .red
        case .moderate, .notice: return .orange
        case .normal: return .green
        case .insufficient: return .accentColor
        }
    }

    private func storageField(_ title: String, _ field: DataValue<Int64>) -> some View {
        DataFieldRow(
            title: title,
            value: field.value.map { AppFormatters.bytes($0) },
            availability: isDemo ? .demo : field.availability,
            source: field.source,
            detail: field.detail,
            updatedAt: field.updatedAt
        )
    }
}
