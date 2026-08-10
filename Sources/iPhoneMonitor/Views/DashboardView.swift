import SwiftUI
import iPhoneMonitorCore

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    let onImport: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                connectionCard

                if let snapshot = store.selectedSnapshot {
                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricCard(
                            title: "最高电池温度",
                            value: String(format: "%.2f°C", snapshot.maximumTemperature),
                            detail: "40°C 以上约 \(snapshot.hotMinutes.formatted(.number.precision(.fractionLength(1)))) 分钟",
                            systemImage: "thermometer.high",
                            tint: snapshot.maximumTemperature >= 43 ? .red : .orange
                        )
                        MetricCard(
                            title: "内存压力警告",
                            value: String(format: "%.1f%%", snapshot.memoryWarningPercent),
                            detail: "交换空间峰值 \(Int(snapshot.maximumSwapMB)) MB",
                            systemImage: "memorychip",
                            tint: snapshot.memoryWarningPercent >= 20 ? .orange : .blue
                        )
                        MetricCard(
                            title: "电池健康",
                            value: store.report?.batteryHealthPercent.map { "\($0)%" } ?? "—",
                            detail: store.report?.cycleCount.map { "\($0) 次循环" } ?? "诊断包未提供",
                            systemImage: "battery.75percent",
                            tint: .green
                        )
                        MetricCard(
                            title: "可用存储",
                            value: store.report?.freeStorageGB.map {
                                String(format: "%.1f GB", $0)
                            } ?? "—",
                            detail: "建议始终保留至少 10 GB",
                            systemImage: "internaldrive",
                            tint: .indigo
                        )
                    }

                    SectionCard(
                        "温度趋势",
                        subtitle: "\(snapshot.date) · 蓝色为平均值，橙色为最高值"
                    ) {
                        TemperatureChart(points: snapshot.temperaturePoints)
                    }

                    SectionCard("需要关注") {
                        if store.allAlerts.isEmpty {
                            Label("这份诊断中没有触发风险阈值", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            ForEach(store.allAlerts) { alert in
                                AlertRow(alert: alert)
                                if alert.id != store.allAlerts.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                } else {
                    SectionCard("还没有深度诊断数据") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("连接状态会自动刷新。要查看温度、内存和后台进程，请导入 iPhone 的 sysdiagnose 诊断包。")
                                .foregroundStyle(.secondary)
                            Button("导入诊断包", action: onImport)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }

                if let importError = store.importError {
                    SectionCard("导入失败") {
                        Label(importError, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(22)
        }
        .navigationTitle("健康总览")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("iPhone 健康监控")
                .font(.largeTitle.weight(.semibold))
            Text("连接状态实时刷新，性能问题通过诊断历史定位。")
                .foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        SectionCard("连接状态") {
            HStack(spacing: 14) {
                Image(systemName: store.primaryDevice?.available == true
                      ? "iphone.gen3.radiowaves.left.and.right"
                      : "iphone.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(store.primaryDevice?.available == true ? .green : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.primaryDevice?.name ?? "没有检测到 iPhone")
                        .font(.headline)
                    Text(store.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusPill(
                    text: store.primaryDevice?.available == true ? "已连接" : "未连接",
                    color: store.primaryDevice?.available == true ? .green : .secondary
                )
            }
        }
    }
}
