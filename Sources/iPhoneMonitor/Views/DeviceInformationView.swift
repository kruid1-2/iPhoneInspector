import AppKit
import SwiftUI
import iPhoneMonitorCore

struct DeviceInformationView: View {
    @ObservedObject var deviceStore: DeviceStore
    @ObservedObject var settingsStore: SettingsStore
    @State private var copiedDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "设备信息",
                    subtitle: "字段来源会逐项标注；空值不会覆盖之前成功读取的结果。"
                )

                if let device = deviceStore.primaryDevice {
                    deviceDetails(device)
                } else {
                    EmptyDeviceView {
                        deviceStore.requestRefresh(detailed: true)
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle("设备信息")
    }

    @ViewBuilder
    private func deviceDetails(_ device: ConnectedDevice) -> some View {
        SectionCard(
            device.displayName,
            subtitle: "\(device.modelName) · \(device.connectionType)"
        ) {
            VStack(spacing: 10) {
                field("设备名称", device.information.name)
                Divider()
                field("产品类型", device.information.productType, monospaced: true)
                Divider()
                field("市场型号", device.information.marketingName)
                Divider()
                field("iOS 版本", device.information.systemVersion)
                Divider()
                field("Build Version", device.information.buildVersion, monospaced: true)
                Divider()
                sensitiveField("序列号", device.information.serialNumber)
                Divider()
                sensitiveField("UDID", device.information.udid)
                Divider()
                sensitiveField("ECID", device.information.ecid)
                Divider()
                field("CPU 架构", device.information.architecture)
                Divider()
                boolField("已配对", device.information.paired)
                Divider()
                boolField("受密码保护", device.information.passcodeProtected)
                Divider()
                boolField("启用“查找”", device.information.findMyEnabled)
                Divider()
                DataFieldRow(
                    title: "连接类型",
                    value: device.connectionType,
                    availability: device.isDemoData ? .demo : .available,
                    source: device.sources.joined(separator: " + ")
                )
                Divider()
                DataFieldRow(
                    title: "最近成功读取",
                    value: AppFormatters.date(device.lastSuccessfulRead),
                    availability: device.connectionState == .disconnected ? .stale : .available,
                    source: device.sources.joined(separator: " + ")
                )
            }
        }

        SectionCard("数据提供器", subtitle: "应用只调用当前电脑已存在的本地工具") {
            if deviceStore.providerStatuses.isEmpty {
                Text("尚未执行提供器检查。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deviceStore.providerStatuses, id: \.name) { provider in
                    HStack(spacing: 10) {
                        Image(systemName: provider.succeeded
                              ? "checkmark.circle.fill"
                              : (provider.available ? "exclamationmark.circle" : "minus.circle"))
                            .foregroundStyle(provider.succeeded ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                                .font(.subheadline.weight(.medium))
                            Text(provider.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if provider.name != deviceStore.providerStatuses.last?.name {
                        Divider()
                    }
                }
            }
        }

        if let detail = device.statusDetail, !detail.isEmpty {
            SectionCard("连接诊断详情") {
                Text(detail)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }

        if !deviceStore.detailErrors.isEmpty {
            SectionCard("详细字段读取说明") {
                ForEach(deviceStore.detailErrors, id: \.self) { error in
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }

        SectionCard(
            "可复制的诊断详情",
            subtitle: "不包含完整 UDID、序列号或用户文件内容"
        ) {
            Text(diagnosticSummary(for: device))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(copiedDetails ? "已复制" : "复制诊断详情") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    diagnosticSummary(for: device),
                    forType: .string
                )
                copiedDetails = true
            }
        }
    }

    private func field(
        _ title: String,
        _ field: DataValue<String>,
        monospaced: Bool = false
    ) -> some View {
        DataFieldRow(
            title: title,
            value: field.value,
            availability: availability(field.availability),
            source: field.source,
            monospaced: monospaced
        )
    }

    private func sensitiveField(
        _ title: String,
        _ field: DataValue<String>
    ) -> some View {
        DataFieldRow(
            title: title,
            value: field.value.map {
                AppFormatters.identifier(
                    $0,
                    reveal: settingsStore.showFullIdentifiers
                )
            },
            availability: availability(field.availability),
            source: field.source,
            monospaced: true
        )
    }

    private func boolField(_ title: String, _ field: DataValue<Bool>) -> some View {
        DataFieldRow(
            title: title,
            value: field.value.map { $0 ? "是" : "否" },
            availability: availability(field.availability),
            source: field.source
        )
    }

    private func availability(_ value: DataAvailability) -> DataAvailability {
        deviceStore.primaryDevice?.isDemoData == true ? .demo : value
    }

    private func diagnosticSummary(for device: ConnectedDevice) -> String {
        let providers = deviceStore.providerStatuses.map {
            "\($0.name): \($0.succeeded ? "成功" : $0.detail)"
        }.joined(separator: "\n")
        let errors = deviceStore.detailErrors.isEmpty
            ? "无"
            : deviceStore.detailErrors.joined(separator: "；")
        return """
        iPhone Inspector 0.1.0
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        设备: \(device.modelName)
        iOS: \(device.information.systemVersion.value ?? "未返回")
        连接: \(device.connectionType) / \(device.connectionState.label)
        最后刷新: \(AppFormatters.date(deviceStore.lastRefresh))
        提供器:
        \(providers.isEmpty ? "尚未运行" : providers)
        详细字段错误: \(errors)
        """
    }
}
