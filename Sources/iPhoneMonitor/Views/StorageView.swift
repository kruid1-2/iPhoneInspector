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
                    subtitle: "区分 iPhone 设置口径与 USB 硬空闲读数；无法验证时不会进行推测。"
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
                        storageField(
                            "设置口径可用空间",
                            storage.availableBytes,
                            guidance: "请以 iPhone 设置 → 通用 → iPhone 储存空间为准"
                        )
                        Divider()
                        storageField(
                            "当前硬空闲空间（不含可回收空间）",
                            storage.hardFreeBytes
                        )
                        Divider()
                        storageField("已使用容量", storage.usedBytes)
                        Divider()
                        storageField("可清理空间", storage.reclaimableBytes)
                    }
                }

                SectionCard("风险规则") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("可用空间低于总容量 15%：提醒", systemImage: "info.circle")
                        Label("可用空间低于总容量 8%：较高风险", systemImage: "exclamationmark.triangle")
                        Label("可用空间低于 5 GB：高风险", systemImage: "exclamationmark.octagon")
                        Text("阈值只应用于可信的设置口径可用空间，不应用于当前硬空闲读数。")
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

    private func storageField(
        _ title: String,
        _ field: DataValue<Int64>,
        guidance: String? = nil
    ) -> some View {
        let details = [field.detail, guidance].compactMap { $0 }
        return DataFieldRow(
            title: title,
            value: field.value.map { AppFormatters.bytes($0) },
            availability: isDemo ? .demo : field.availability,
            source: field.source,
            detail: details.isEmpty ? nil : details.joined(separator: "；"),
            updatedAt: field.updatedAt
        )
    }
}
