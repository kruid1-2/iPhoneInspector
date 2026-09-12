import SwiftUI
import iPhoneMonitorCore

struct OverviewView: View {
    @ObservedObject private var deviceStore: DeviceStore
    @ObservedObject private var diagnosticStore: DiagnosticStore
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var performanceStore: PerformanceMonitorStore
    private let appStore: AppStore

    init(appStore: AppStore) {
        self.appStore = appStore
        deviceStore = appStore.deviceStore
        diagnosticStore = appStore.diagnosticStore
        settingsStore = appStore.settingsStore
        performanceStore = appStore.performanceMonitorStore
    }

    private let columns = [
        GridItem(.adaptive(minimum: 170, maximum: 250), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "概览",
                    subtitle: "仅依据当前连接和已导入诊断数据进行本地分析。"
                )

                if deviceStore.primaryDevice == nil {
                    EmptyDeviceView {
                        deviceStore.requestRefresh(detailed: true)
                    }
                } else {
                    connectionCard
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(
                        title: "设备",
                        value: deviceStore.primaryDevice?.modelName ?? "—",
                        detail: deviceStore.primaryDevice?.information.systemVersion.value
                            .map { "iOS \($0)" } ?? "系统版本未返回",
                        systemImage: "iphone.gen3",
                        tint: .blue
                    )
                    batteryCard
                    MetricCard(
                        title: "存储空间",
                        value: storageValue,
                        detail: storageDetail,
                        systemImage: "internaldrive",
                        tint: .indigo
                    )
                    MetricCard(
                        title: "诊断记录",
                        value: "\(diagnosticStore.allRecords.count)",
                        detail: "\(diagnosticStore.analyses.count) 次导入",
                        systemImage: "doc.text.magnifyingglass",
                        tint: .purple
                    )
                    MetricCard(
                        title: "当前风险",
                        value: "\(actionableRisks.count)",
                        detail: "最高等级：\(appStore.highestRisk.label)",
                        systemImage: "exclamationmark.shield",
                        tint: riskColor
                    )
                    MetricCard(
                        title: "最近异常重启",
                        value: latestReboot.map {
                            $0.formatted(date: .abbreviated, time: .omitted)
                        } ?? "未获取",
                        detail: latestReboot == nil ? "需要 panic / watchdog 日志" : "来自导入日志",
                        systemImage: "arrow.counterclockwise.circle",
                        tint: .orange
                    )
                }

                SectionCard("推荐的下一步操作") {
                    Label(nextAction, systemImage: "arrow.right.circle.fill")
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionCard("当前结论") {
                    if actionableRisks.isEmpty {
                        Label(
                            appStore.highestRisk == .insufficient
                                ? "信息不足，尚不能定位卡顿或发热原因"
                                : "当前数据没有触发中等以上风险",
                            systemImage: appStore.highestRisk == .insufficient
                                ? "questionmark.circle"
                                : "checkmark.circle.fill"
                        )
                        .foregroundStyle(
                            appStore.highestRisk == .insufficient
                                ? Color.secondary
                                : Color.green
                        )
                    } else {
                        ForEach(actionableRisks.prefix(4)) { finding in
                            HStack(alignment: .top, spacing: 12) {
                                RiskLevelBadge(level: finding.level)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(finding.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(finding.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            if finding.id != actionableRisks.prefix(4).last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle("概览")
    }

    private var connectionCard: some View {
        SectionCard("连接状态") {
            HStack(spacing: 14) {
                Image(systemName: deviceStore.hasActiveConnection
                      ? "iphone.gen3.radiowaves.left.and.right"
                      : "iphone.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(deviceStore.hasActiveConnection ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(deviceStore.primaryDevice?.displayName ?? "iPhone")
                        .font(.headline)
                    Text(connectionDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(
                    text: deviceStore.primaryDevice?.connectionState.label ?? "未连接",
                    color: deviceStore.hasActiveConnection ? .green : .secondary
                )
            }
        }
    }

    private var batteryCard: some View {
        let snapshot = appStore.overviewBattery()
        return MetricCard(
            title: "电池",
            value: batterySummary(snapshot),
            detail: batteryDetail(snapshot),
            systemImage: "battery.75percent",
            tint: .green
        )
    }

    private func batterySummary(_ snapshot: BatteryOverviewSnapshot) -> String {
        if let level = snapshot.currentLevelPercent {
            return AppFormatters.percent(level)
        }
        if let health = snapshot.healthPercent {
            return "健康度 \(health)%"
        }
        return "—"
    }

    private func batteryDetail(_ snapshot: BatteryOverviewSnapshot) -> String {
        var parts = [snapshot.source.label]
        if let isCharging = snapshot.isCharging {
            parts.append(isCharging ? "正在充电" : "当前未充电")
        } else if let externalPower = snapshot.externalPowerConnected {
            parts.append(externalPower ? "已接入电源" : "未接入电源")
        } else if let health = snapshot.healthPercent {
            parts.append("最大容量 \(health)%")
        }
        if let temperature = snapshot.temperatureRaw {
            parts.append("电池温度原始值 \(formatRaw(temperature))")
        }
        return parts.joined(separator: " · ")
    }

    private func formatRaw(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private var connectionDetail: String {
        guard let device = deviceStore.primaryDevice else {
            return deviceStore.statusMessage
        }
        return "\(device.modelName) · \(device.connectionState.label)"
    }

    private var storageDetail: String {
        let presentation = StorageOverviewPresentation.resolve(
            appStore.effectiveStorage
        )
        if let hardFree = presentation.hardFreeBytes {
            return "当前硬空闲 \(AppFormatters.bytes(hardFree))（不含可回收空间）"
        }
        if let fraction = presentation.usageFraction {
            return "已使用 \(Int(fraction * 100))%"
        }
        return appStore.effectiveStorage.availableBytes.detail
            ?? appStore.effectiveStorage.availableBytes.availability.message
    }

    private var storageValue: String {
        switch StorageOverviewPresentation.resolve(
            appStore.effectiveStorage
        ).primaryValue {
        case let .userAvailable(bytes):
            return AppFormatters.bytes(bytes)
        case .settingsRequired:
            return "请在 iPhone 设置中查看"
        }
    }

    private var actionableRisks: [RiskFinding] {
        appStore.riskFindings.filter { $0.level >= .moderate }
    }

    private var latestReboot: Date? {
        diagnosticStore.allRecords
            .filter { $0.category == .panic || $0.category == .watchdog || $0.category == .reset }
            .compactMap(\.timestamp)
            .max()
    }

    private var nextAction: String {
        if settingsStore.demoMode {
            return "关闭演示模式并连接真实 iPhone，才能得到实测信息。"
        }
        if deviceStore.primaryDevice == nil {
            return "用数据线连接 iPhone，解锁并点击“信任此电脑”，保持亮屏后刷新。"
        }
        if deviceStore.primaryDevice?.connectionState == .locked {
            return "解锁 iPhone，保持屏幕亮起，然后点击刷新。"
        }
        if deviceStore.primaryDevice?.connectionState == .untrusted {
            return "在 iPhone 上点击“信任此电脑”，输入密码后再次刷新。"
        }
        if diagnosticStore.analyses.isEmpty {
            return "导入 sysdiagnose 或“分析数据”中的 .ips 文件，以检查异常重启、内存和热压力。"
        }
        if let first = appStore.riskFindings.first, first.level >= .moderate {
            return first.recommendation
        }
        return "继续观察存储剩余空间，并在问题再次发生后导入新的诊断日志。"
    }

    private var riskColor: Color {
        switch appStore.highestRisk {
        case .normal: return .green
        case .notice: return .blue
        case .moderate: return .orange
        case .high, .severe: return .red
        case .insufficient: return .secondary
        }
    }
}
