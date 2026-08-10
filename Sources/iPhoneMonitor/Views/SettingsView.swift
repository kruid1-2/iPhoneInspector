import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var diagnosticStore: DiagnosticStore
    let embedded: Bool

    @State private var showClearConfirmation = false
    @State private var clearError: String?

    var body: some View {
        Group {
            if embedded {
                ScrollView {
                    settingsContent
                        .padding(22)
                }
            } else {
                settingsContent
                    .padding(20)
                    .frame(width: 520, height: 560)
            }
        }
        .alert("清除所有本地诊断记录？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                do {
                    try diagnosticStore.clearAll()
                } catch {
                    clearError = error.localizedDescription
                }
            }
        } message: {
            Text("这会删除应用保存的解析结果和受控导入副本，原始文件不会被修改。")
        }
        .alert(
            "无法清除数据",
            isPresented: Binding(
                get: { clearError != nil },
                set: { if !$0 { clearError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(clearError ?? "")
        }
        .navigationTitle("设置")
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if embedded {
                PageHeader(
                    title: "设置",
                    subtitle: "偏好设置保存在本机，不使用账户或云端同步。"
                )
            }

            SectionCard("设备检测") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("自动检测设备", isOn: $settingsStore.autoDetection)
                    HStack {
                        Text("检测间隔")
                        Slider(
                            value: $settingsStore.detectionInterval,
                            in: 3...60,
                            step: 1
                        )
                        Text("\(Int(settingsStore.detectionInterval)) 秒")
                            .monospacedDigit()
                            .frame(width: 54, alignment: .trailing)
                    }
                    .disabled(!settingsStore.autoDetection)
                    Text("定时检测只运行轻量设备命令；详细字段在连接或手动刷新时读取。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SectionCard("隐私与显示") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        "显示完整序列号和 UDID",
                        isOn: $settingsStore.showFullIdentifiers
                    )
                    Toggle(
                        "保留导入文件副本",
                        isOn: $settingsStore.keepImportedCopies
                    )
                    Stepper(
                        "诊断摘要保留 \(settingsStore.retentionDays) 天",
                        value: $settingsStore.retentionDays,
                        in: 1...365
                    )
                    Text("应用不会上传设备信息或诊断文件，也不会默认记录完整 UDID、序列号或文件内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SectionCard("本地数据") {
                HStack {
                    Button("打开应用数据目录") {
                        let url = diagnosticStore.dataDirectoryURL()
                        try? FileManager.default.createDirectory(
                            at: url,
                            withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(url)
                    }
                    Button("清除本地诊断记录", role: .destructive) {
                        showClearConfirmation = true
                    }
                    Spacer()
                }
            }

            SectionCard("演示模式") {
                Toggle("启用演示模式", isOn: $settingsStore.demoMode)
                Text("默认关闭。开启后会在所有相关页面醒目标注“演示数据”，不会冒充真实 iPhone。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SectionCard("关于与隐私") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("iPhone 诊断助手 · iPhone Inspector")
                        .font(.headline)
                    Text("未越狱 iPhone 不允许普通电脑应用稳定读取实时 CPU、芯片真实温度、每个 App 的实时内存、完整后台进程和受保护日志。本应用不会尝试突破这些限制。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("开发版暂不启用 App Sandbox，以便调用本地只读设备工具和让用户选择诊断文件；应用不使用 sudo、不修改 iPhone、不连接服务器。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
