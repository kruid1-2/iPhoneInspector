import SwiftUI
import iPhoneMonitorCore

struct BatteryView: View {
    let battery: BatteryInformation
    let isDemo: Bool
    let hasDevice: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "电池",
                    subtitle: "第三方电池可能导致健康度、循环次数或验证状态缺失；缺失数据不等于电池损坏或非正品。"
                )

                if !hasDevice && battery.latestLogDate == nil && !isDemo {
                    SectionCard("尚无电池数据") {
                        Text("保持 iPhone 连接并刷新，或导入包含 BatteryHealth / PowerLog 的诊断日志。")
                            .foregroundStyle(.secondary)
                    }
                }

                SectionCard("当前状态") {
                    VStack(spacing: 10) {
                        doubleField(
                            "当前电量",
                            battery.currentLevelPercent,
                            format: { AppFormatters.percent($0) }
                        )
                        Divider()
                        boolField("正在充电", battery.isCharging)
                        Divider()
                        boolField("已接入电源", battery.externalPowerConnected)
                        Divider()
                        stringField("充电状态", battery.chargingStatus)
                    }
                }

                SectionCard(
                    "容量与循环",
                    subtitle: "这些字段并非所有 iOS 版本、连接工具和第三方电池都会返回"
                ) {
                    VStack(spacing: 10) {
                        intField("电池健康度", battery.healthPercent, suffix: "%")
                        Divider()
                        intField("设计容量", battery.designCapacityMAh, suffix: " mAh")
                        Divider()
                        intField("当前最大容量", battery.maximumCapacityMAh, suffix: " mAh")
                        Divider()
                        intField("循环次数", battery.cycleCount, suffix: " 次")
                    }
                }

                SectionCard("电池身份与可信度") {
                    VStack(spacing: 10) {
                        stringField("制造或序列信息", battery.serialOrManufacturingInfo)
                        Divider()
                        stringField("系统验证状态", battery.verificationStatus)
                    }
                }

                SectionCard("权限说明") {
                    Text("应用不会显示芯片真实温度、实时放电功率或系统未公开的底层电池参数。PowerLog 中的温度仅作为历史日志证据，并会明确标注来源。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
        }
        .navigationTitle("电池")
    }

    private func doubleField(
        _ title: String,
        _ field: DataValue<Double>,
        format: (Double) -> String
    ) -> some View {
        DataFieldRow(
            title: title,
            value: field.value.map(format),
            availability: effectiveAvailability(field.availability),
            source: field.source,
            detail: field.detail,
            updatedAt: field.updatedAt
        )
    }

    private func intField(
        _ title: String,
        _ field: DataValue<Int>,
        suffix: String
    ) -> some View {
        DataFieldRow(
            title: title,
            value: field.value.map { "\($0)\(suffix)" },
            availability: effectiveAvailability(field.availability),
            source: field.source,
            detail: field.detail,
            updatedAt: field.updatedAt
        )
    }

    private func boolField(_ title: String, _ field: DataValue<Bool>) -> some View {
        DataFieldRow(
            title: title,
            value: field.value.map { $0 ? "是" : "否" },
            availability: effectiveAvailability(field.availability),
            source: field.source,
            detail: field.detail,
            updatedAt: field.updatedAt
        )
    }

    private func stringField(_ title: String, _ field: DataValue<String>) -> some View {
        DataFieldRow(
            title: title,
            value: field.value,
            availability: effectiveAvailability(field.availability),
            source: field.source,
            detail: field.detail,
            updatedAt: field.updatedAt
        )
    }

    private func effectiveAvailability(_ value: DataAvailability) -> DataAvailability {
        isDemo ? .demo : value
    }
}
