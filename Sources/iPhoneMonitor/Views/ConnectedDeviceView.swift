import SwiftUI
import iPhoneMonitorCore

struct ConnectedDeviceView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("连接的 iPhone")
                        .font(.largeTitle.weight(.semibold))
                    Text("每 6 秒通过 Apple 开发工具检查一次 USB 与 Wi‑Fi 设备状态。")
                        .foregroundStyle(.secondary)
                }

                if store.devices.isEmpty {
                    SectionCard("未检测到设备") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                "请使用数据线连接 iPhone，并保持手机解锁",
                                systemImage: "cable.connector"
                            )
                            Text("首次连接时，需要在手机上点按“信任”，电脑端也可能要求确认。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("重新检查") {
                                store.requestDeviceRefresh()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ForEach(store.devices) { device in
                        deviceCard(device)
                    }
                }

                if let deviceError = store.deviceError {
                    SectionCard("设备工具返回错误") {
                        Text(deviceError)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                capabilitiesCard
            }
            .padding(22)
        }
        .navigationTitle("连接的 iPhone")
    }

    private func deviceCard(_ device: DeviceInfo) -> some View {
        SectionCard(device.name, subtitle: device.modelName) {
            VStack(spacing: 12) {
                detailRow("连接", value: device.connectionLabel)
                Divider()
                detailRow("系统", value: device.operatingSystemVersion)
                Divider()
                detailRow("型号代码", value: device.modelCode)
                Divider()
                detailRow("设备标识", value: device.maskedIdentifier)
                Divider()
                HStack {
                    Text("状态")
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(
                        text: device.available ? "可用" : "不可用",
                        color: device.available ? .green : .orange
                    )
                }

                if let detail = device.statusDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var capabilitiesCard: some View {
        SectionCard("当前数据能力", subtitle: "未越狱 iPhone 的系统权限边界") {
            VStack(spacing: 12) {
                capabilityRow(
                    "连接、机型与系统版本",
                    available: true,
                    detail: "连接时自动刷新"
                )
                Divider()
                capabilityRow(
                    "电池健康、温度与存储",
                    available: true,
                    detail: "从 sysdiagnose 历史数据读取"
                )
                Divider()
                capabilityRow(
                    "应用内存与后台进程",
                    available: true,
                    detail: "从 PowerLog 与后台任务数据库分析"
                )
                Divider()
                capabilityRow(
                    "实时 CPU、实时内部温度",
                    available: false,
                    detail: "iOS 不向普通电脑应用开放"
                )
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func capabilityRow(
        _ title: String,
        available: Bool,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "lock.circle.fill")
                .foregroundStyle(available ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
