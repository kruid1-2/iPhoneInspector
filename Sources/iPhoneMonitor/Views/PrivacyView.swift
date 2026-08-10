import SwiftUI

struct PrivacyView: View {
    let onImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("数据范围与隐私")
                        .font(.largeTitle.weight(.semibold))
                    Text("明确区分实时可见数据、诊断历史和 iOS 禁止读取的数据。")
                        .foregroundStyle(.secondary)
                }

                SectionCard("程序会读取什么") {
                    privacyRow(
                        icon: "cable.connector",
                        title: "Apple 设备连接信息",
                        detail: "设备名称、机型、系统版本、连接方式和是否可用。"
                    )
                    Divider()
                    privacyRow(
                        icon: "battery.75percent",
                        title: "诊断包中的性能数据",
                        detail: "电池健康、温度、存储、内存压力、应用内存峰值和后台任务统计。"
                    )
                    Divider()
                    privacyRow(
                        icon: "externaldrive.badge.checkmark",
                        title: "只在本机处理",
                        detail: "程序不上传诊断包；导入压缩包时只临时提取必要数据库。"
                    )
                }

                SectionCard("程序不会读取什么") {
                    privacyRow(
                        icon: "photo.on.rectangle.angled",
                        title: "照片、聊天和文件内容",
                        detail: "分析器不会提取照片库、聊天数据库、浏览记录或网络内容。"
                    )
                    Divider()
                    privacyRow(
                        icon: "lock.fill",
                        title: "受 iOS 限制的实时指标",
                        detail: "未越狱设备不向普通电脑应用提供实时 CPU、真实内部温度和完整进程列表。"
                    )
                }

                SectionCard("如何在卡顿时抓取诊断") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. 问题发生时，快速按一下音量加、音量减，再同时短按侧边键约 1 秒。")
                        Text("2. 等待手机生成 sysdiagnose，并通过电脑复制出来。")
                        Text("3. 在本程序中导入 .tar.gz，选择发生问题的日期。")
                        Text("越接近问题发生时间，越容易定位温控、内存和后台任务。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("导入诊断包", action: onImport)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle("数据范围与隐私")
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
