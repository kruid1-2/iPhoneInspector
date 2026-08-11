import SwiftUI
import iPhoneMonitorCore

struct PerformanceDiagnosticView: View {
    @ObservedObject var store: PerformanceMonitorStore
    @ObservedObject var deviceStore: DeviceStore
    let onMarkLag: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "性能诊断",
                    subtitle: "根据真实采样数据整理近期变化；观察到的现象不等同于已经确认的原因。"
                )

                sessionControls
                recentLagSummary
                liveOverview

                if let lastError = store.lastError {
                    SectionCard("当前错误") {
                        Label(lastError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(22)
        }
    }

    private var sessionControls: some View {
        SectionCard("监控状态") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("开始监控") { store.startMonitoring() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canStart)
                    Button("停止监控") { store.stopMonitoring() }
                        .disabled(!store.canStop)
                    Button("刚刚发生卡顿") { onMarkLag() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canMarkLag)
                    Spacer()
                    if store.operationInFlight {
                        ProgressView().controlSize(.small)
                    }
                }

                HStack(spacing: 14) {
                    Label(store.state.label, systemImage: "waveform.path.ecg")
                    Label(deviceStatus, systemImage: "cable.connector")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if store.lagSummaryPending {
                    Label("正在收集卡顿后的约 10 秒数据…", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var liveOverview: some View {
        let snapshot = PerformanceDiagnosticPresenter.liveSnapshot(
            frame: store.timelineFrame,
            streamGapCount: store.streamGaps.count,
            providerErrorCount: store.providerErrorCount,
            droppedCount: store.droppedCount
        )

        return SectionCard("现在的状态", subtitle: "以下均为近期趋势，不展示未经确认单位的原始主指标。") {
            ViewThatFits(in: .horizontal) {
                diagnosticGrid(snapshot, columnCount: 2)
                    .frame(minWidth: 460)
                diagnosticGrid(snapshot, columnCount: 1)
            }
        }
    }

    @ViewBuilder
    private var recentLagSummary: some View {
        if store.lagSummaryPending || store.latestLagSummary != nil {
            let presentation = store.latestLagSummary.map(lagPresentation)

            SectionCard("刚才发生了什么") {
                if store.lagSummaryPending {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在收集卡顿后的约 10 秒数据…")
                    }
                }

                if let summary = store.latestLagSummary {
                    if store.lagSummaryPending { Divider() }
                    Label(
                        summary.markerTimestamp.map(AppFormatters.date) ?? "标记时间未知",
                        systemImage: "flag.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if let presentation {
                SectionCard("一句话概览") {
                    Text(presentation.overview)
                        .font(.body.weight(.medium))
                }

                SectionCard("主要现象") {
                    if presentation.phenomena.isEmpty {
                        Text("没有足够的变化可供概括。")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(presentation.phenomena, id: \.self) { phenomenon in
                                Label(phenomenon, systemImage: "circle.fill")
                                    .font(.subheadline)
                            }
                        }
                    }
                }

                SectionCard("可能相关进程") {
                    if presentation.relatedProcesses.isEmpty {
                        Text("进程数据不足，暂不列出相关进程。")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(presentation.relatedProcesses) { process in
                                Label(process.displayName, systemImage: "app.dashed")
                            }
                            Text("这些进程只是在卡顿附近的活动中被观察到，不能单独说明原因。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SectionCard("数据完整性") {
                    Label(presentation.dataIntegrity, systemImage: "checkmark.shield")
                        .font(.body.weight(.medium))
                    Text(presentation.dataIntegrityDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            SectionCard("刚才发生了什么") {
                Text("再次感觉卡顿时，点击“刚刚发生卡顿”。系统会保留卡顿前后的真实数据，并在约 10 秒后给出观察摘要。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deviceStatus: String {
        guard let device = deviceStore.primaryDevice else { return "未连接 iPhone" }
        return "\(device.modelName) · \(device.connectionState.label)"
    }

    private func lagPresentation(_ summary: PerformanceLagSummary) -> PerformanceLagDiagnosticPresentation {
        PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary,
            processDisplayName: { AppNameResolver.displayName(for: $0) }
        )
    }

    private func diagnosticItem(
        _ title: String,
        _ value: String,
        _ detail: String,
        _ image: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: image)
                .font(.subheadline.weight(.medium))
            Text(value)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func diagnosticGrid(
        _ snapshot: PerformanceDiagnosticSnapshot,
        columnCount: Int
    ) -> some View {
        let columns = Array(repeating: GridItem(.flexible(minimum: 210), spacing: 14), count: columnCount)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            diagnosticItem("处理器", snapshot.processor, "观察最近约 30 秒的整体变化。", "cpu")
            diagnosticItem("内存", snapshot.memory, snapshot.memoryExplanation, "memorychip")
            diagnosticItem("电池温度", snapshot.batteryTemperature, "只判断变化趋势，不等同于 CPU 或 SoC 温度。", "thermometer.medium")
            diagnosticItem("能耗活动", snapshot.energy, "相对评分的近期变化，不代表功耗。", "bolt")
            diagnosticItem("数据质量", snapshot.dataQuality, "数据中断、数据源错误或队列丢弃会降低可参考性。", "checkmark.shield")
        }
    }
}
