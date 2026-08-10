import SwiftUI
import iPhoneMonitorCore

struct DeviceHeaderBar: View {
    @ObservedObject var deviceStore: DeviceStore
    @ObservedObject var diagnosticStore: DiagnosticStore
    let onRefresh: () -> Void
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: connectionIcon)
                .font(.title2)
                .foregroundStyle(connectionColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(deviceStore.primaryDevice?.displayName ?? "未连接 iPhone")
                        .font(.headline)
                    if deviceStore.primaryDevice?.isDemoData == true {
                        StatusPill(text: "演示数据", color: .orange)
                    }
                }
                HStack(spacing: 9) {
                    Text(connectionSummary)
                    Text("·")
                    Text("最后刷新 \(AppFormatters.date(deviceStore.lastRefresh))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if diagnosticStore.isImporting {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: diagnosticStore.progress)
                        .frame(width: 120)
                    Text(diagnosticStore.progressMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button("取消") {
                    diagnosticStore.cancelImport()
                }
            }

            Button(action: onRefresh) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(deviceStore.isRefreshing)

            Button(action: onImport) {
                Label("导入诊断文件", systemImage: "square.and.arrow.down")
            }
            .disabled(diagnosticStore.isImporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var connectionSummary: String {
        guard let device = deviceStore.primaryDevice else {
            return deviceStore.statusMessage
        }
        let model = device.information.marketingName.value
            ?? device.information.productType.value
            ?? "型号未返回"
        return "\(model) · \(device.connectionType) · \(device.connectionState.label)"
    }

    private var connectionIcon: String {
        deviceStore.hasActiveConnection
            ? "iphone.gen3.radiowaves.left.and.right"
            : "iphone.slash"
    }

    private var connectionColor: Color {
        deviceStore.hasActiveConnection ? .green : .secondary
    }
}

struct DemoModeBanner: View {
    var body: some View {
        Label(
            "演示模式已开启：以下设备与数值均为演示数据，不是当前 iPhone 的实测结果。",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout.weight(.medium))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
    }
}
