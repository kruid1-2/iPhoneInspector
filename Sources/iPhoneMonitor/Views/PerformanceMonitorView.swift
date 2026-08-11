import SwiftUI
import iPhoneMonitorCore

private enum PerformanceDetailTab: String, CaseIterable, Identifiable {
    case timeline
    case processes
    case logs
    case events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "时间线"
        case .processes: return "全部进程"
        case .logs: return "实时日志"
        case .events: return "事件"
        }
    }
}

private enum PerformancePage: String, CaseIterable, Identifiable {
    case diagnosis
    case details

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagnosis: return "诊断"
        case .details: return "详细数据"
        }
    }
}

struct PerformanceMonitorView: View {
    @ObservedObject var store: PerformanceMonitorStore
    @ObservedObject var deviceStore: DeviceStore

    @State private var showMarkerSheet = false
    @State private var markerNote = ""
    @State private var selectedPage: PerformancePage = .diagnosis
    @State private var selectedDetailTab: PerformanceDetailTab = .timeline

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("性能页面", selection: $selectedPage) {
                ForEach(PerformancePage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .padding(.top, 14)
            .padding(.bottom, 8)

            switch selectedPage {
            case .diagnosis:
                PerformanceDiagnosticView(
                    store: store,
                    deviceStore: deviceStore,
                    onMarkLag: { store.markLag(note: "") }
                )
            case .details:
                detailedPage
            }
        }
        .navigationTitle("性能监控")
        .onAppear { updateTimelineVisibility() }
        .onDisappear {
            store.setDiagnosisVisible(false)
            store.setTimelineVisible(false)
        }
        .onChange(of: selectedPage) { _ in updateTimelineVisibility() }
        .onChange(of: selectedDetailTab) { _ in updateTimelineVisibility() }
        .sheet(isPresented: $showMarkerSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("标记刚刚发生的卡顿")
                    .font(.title2.weight(.semibold))
                Text("备注可留空。标记将使用当前 Helper 时间线，不会修改 iPhone。")
                    .foregroundStyle(.secondary)
                TextField("例如：切换 App 时明显停顿", text: $markerNote)
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { showMarkerSheet = false }
                    Button("添加标记") {
                        store.markLag(note: markerNote)
                        markerNote = ""
                        showMarkerSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 460)
        }
    }

    private var detailedPage: some View {
        VSplitView {
            upperStatusPane
                .frame(minHeight: 220, idealHeight: 430)

            detailPerformancePane
                .frame(minHeight: 250, idealHeight: 320)
        }
    }

    private func updateTimelineVisibility() {
        store.setDiagnosisVisible(selectedPage == .diagnosis)
        store.setTimelineVisible(selectedPage == .details && selectedDetailTab == .timeline)
    }

    private var upperStatusPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "性能监控",
                    subtitle: "通过只读方式观察手机的真实运行状态；尚未确认的单位会明确保留为原始值。"
                )
                controlSection
                statusSection
                LagSummaryView(
                    summary: store.latestLagSummary,
                    isPending: store.lagSummaryPending
                )
                metricsSection
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

    private var detailPerformancePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("详细性能区域", selection: $selectedDetailTab) {
                ForEach(PerformanceDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            .frame(maxWidth: .infinity, alignment: .center)

            selectedDetailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var selectedDetailContent: some View {
        switch selectedDetailTab {
        case .timeline:
            PerformanceTimelineView(
                frame: store.timelineFrame,
                revision: store.timelineRevision,
                range: store.timelineRange,
                onRangeChange: store.setTimelineRange,
                onProcessFilterChange: store.setTimelineProcessFilter,
                onVisibilityChange: store.setTimelineVisible
            )
            .equatable()
        case .processes:
            PerformanceProcessListView(processes: store.latestProcesses)
        case .logs:
            PerformanceLogView(store: store)
        case .events:
            eventList
        }
    }

    private var controlSection: some View {
        SectionCard("会话控制") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("开始监控") { store.startMonitoring() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canStart)
                    Button("停止监控") { store.stopMonitoring() }
                        .disabled(!store.canStop)
                    Button("刚刚发生卡顿") { showMarkerSheet = true }
                        .disabled(!store.canMarkLag)
                    Spacer()
                    if store.operationInFlight { ProgressView().controlSize(.small) }
                }

                Divider()

                Toggle("启用实时系统日志（下次会话生效）", isOn: $store.oslogEnabled)
                    .disabled(store.state == .monitoring || store.operationInFlight)
                if store.oslogEnabled {
                    Label(
                        "实时系统日志会显著增加 Mac 的 CPU 和内存占用。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("默认平衡模式：处理器、进程、电池、能耗和网络；实时系统日志关闭。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusSection: some View {
        SectionCard("连接与状态") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                statusItem("监控服务", store.state.label, "cpu")
                statusItem("USB 设备", usbStatus, "cable.connector")
                statusItem("性能连接", store.transportDescription, "point.3.connected.trianglepath.dotted")
                statusItem("会话时长", duration(store.sessionElapsed), "timer")
                statusItem("最后更新", store.lastUpdate.map(AppFormatters.date) ?? "尚未收到数据", "clock")
                statusItem("监控进程 PID", store.helperPID.map(String.init) ?? "—", "number")
            }
            if let marker = store.lastMarkerAt {
                Label("最近卡顿标记：\(AppFormatters.date(marker))", systemImage: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var metricsSection: some View {
        ViewThatFits(in: .horizontal) {
            metricsGrid(columnCount: 4)
                .frame(minWidth: 1_180)
            metricsGrid(columnCount: 2)
                .frame(minWidth: 600)
            metricsGrid(columnCount: 1)
        }
    }

    @ViewBuilder
    private func metricsGrid(columnCount: Int) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
            if columnCount == 4 {
                GridRow(alignment: .top) {
                    systemMetricsCard
                    batteryMetricsCard
                    energyMetricsCard
                    dataQualityCard
                }
            } else if columnCount == 2 {
                GridRow(alignment: .top) {
                    systemMetricsCard
                    batteryMetricsCard
                }
                GridRow(alignment: .top) {
                    energyMetricsCard
                    dataQualityCard
                }
            } else {
                GridRow { systemMetricsCard }
                GridRow { batteryMetricsCard }
                GridRow { energyMetricsCard }
                GridRow { dataQualityCard }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var systemMetricsCard: some View {
        SectionCard("系统与内存") {
            VStack(alignment: .leading, spacing: 0) {
                PerformanceMetricRow(
                    title: "手机整体处理器负载",
                    value: "\(systemMetric("CPU_TotalLoad")) · \(cpuTrendText)",
                    source: "Apple 性能监控接口",
                    detail: "原始负载值；数值越高表示手机整体越忙，不添加百分号。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "CPU 核心数量",
                    value: systemMetric("CPUCount"),
                    source: "Apple 性能监控接口",
                    detail: "设备返回的原始计数。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "空闲内存趋势",
                    value: freeMemoryTrendText,
                    source: "Apple 性能监控接口",
                    detail: "使用 vmFreeCount 的最近趋势；原始页计数在时间线详细数据中。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "内存压缩趋势",
                    value: compressorTrendText,
                    source: "Apple 性能监控接口",
                    detail: "使用 vmCompressorPageCount 的最近趋势；不能单独证明内存不足。"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var batteryMetricsCard: some View {
        SectionCard("电池与供电") {
            VStack(alignment: .leading, spacing: 0) {
                PerformanceMetricRow(
                    title: "当前电量",
                    value: batteryMetric("CurrentCapacity", confirmed: true),
                    source: "设备电池诊断接口",
                    detail: "设备实时返回。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "充电状态",
                    value: batteryMetric("IsCharging", confirmed: true),
                    source: "设备电池诊断接口",
                    detail: "布尔原始状态。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "电池温度",
                    value: "\(batteryMetric("Temperature")) · \(batteryTrendText)",
                    source: "设备电池诊断接口",
                    detail: "电池温度原始值，不是 CPU 或 SoC 温度。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "电压 / 电流",
                    value: "\(batteryMetric("Voltage")) / \(batteryMetric("InstantAmperage"))",
                    source: "设备电池诊断接口",
                    detail: "原始值，单位与电流符号尚未确认。"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var energyMetricsCard: some View {
        SectionCard("能耗与网络") {
            VStack(alignment: .leading, spacing: 0) {
                PerformanceMetricRow(
                    title: "系统能耗活动",
                    value: "\(firstEnergyMetric) · \(energyTrendText)",
                    source: "Apple 性能监控接口",
                    detail: "相对评分，用于比较变化，不是瓦特或焦耳。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "下载",
                    value: networkRate(.networkReceive),
                    source: "Apple 网络监控接口",
                    detail: "按相邻真实采样时间计算平均速度；不保留地址、端口或通信内容。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "上传",
                    value: networkRate(.networkTransmit),
                    source: "Apple 网络监控接口",
                    detail: "按相邻真实采样时间计算平均速度。"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dataQualityCard: some View {
        SectionCard("数据质量") {
            VStack(alignment: .leading, spacing: 0) {
                PerformanceMetricRow(
                    title: "数据中断",
                    value: "\(store.streamGaps.count)",
                    source: "监控采样状态",
                    detail: "空档保留，不插值或复制旧样本。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "队列丢弃",
                    value: "\(store.droppedCount)",
                    source: "监控服务状态",
                    detail: "有界队列明确报告的丢弃数。"
                )
                Divider()
                PerformanceMetricRow(
                    title: "数据源错误",
                    value: "\(store.providerErrorCount)",
                    source: "监控服务状态",
                    detail: "单个非核心数据源失败不会结束整个会话。"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var eventList: some View {
        List {
            if store.userMarkers.isEmpty && store.streamGaps.isEmpty && store.providerErrors.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "flag")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("本次会话暂无事件")
                        .font(.headline)
                    Text("卡顿标记、数据中断和数据源错误会显示在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            ForEach(store.userMarkers) { marker in
                Label(
                    "卡顿标记 · \(marker.note.isEmpty ? "无备注" : marker.note)",
                    systemImage: "flag.fill"
                )
                .foregroundStyle(.orange)
            }
            ForEach(store.streamGaps) { gap in
                Label(
                    "\(providerTitle(gap.provider))数据中断 \(gap.observedGapMS.map { String(format: "约 %.1f 秒", $0 / 1_000) } ?? "时长未知")",
                    systemImage: "waveform.path.badge.minus"
                )
            }
            ForEach(store.providerErrors) { error in
                Label("\(error.provider)：\(error.summary)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func statusItem(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.medium)).lineLimit(2)
            }
        }
    }

    private var usbStatus: String {
        guard let device = deviceStore.primaryDevice else { return "未连接" }
        return "\(device.modelName) · \(device.connectionState.label)"
    }

    private func systemMetric(_ name: String) -> String {
        store.latestSystem?.metric(name)?.rawDisplay ?? "—"
    }

    private var cpuTrendText: String {
        trendText(
            timelineTrend(kind: .systemCPU, threshold: 0.08),
            increasing: "正在升高",
            stable: "较平稳",
            decreasing: "正在降低"
        )
    }

    private var freeMemoryTrendText: String {
        let series = store.timelineFrame.series(kind: .systemVM).first {
            $0.id.localizedCaseInsensitiveContains("vmfreecount")
        }
        return trendText(
            PerformanceInsightAnalyzer.trend(points: series?.points ?? [], recentSeconds: 30, relativeThreshold: 0.01),
            increasing: "空闲空间正在增加",
            stable: "基本稳定",
            decreasing: "空闲空间正在减少"
        )
    }

    private var compressorTrendText: String {
        let series = store.timelineFrame.series(kind: .systemVM).first {
            $0.id.localizedCaseInsensitiveContains("vmcompressorpagecount")
        }
        return trendText(
            PerformanceInsightAnalyzer.trend(points: series?.points ?? [], recentSeconds: 30, relativeThreshold: 0.01),
            increasing: "内存压缩增加",
            stable: "基本稳定",
            decreasing: "内存压缩减少"
        )
    }

    private var batteryTrendText: String {
        trendText(
            timelineTrend(kind: .batteryTemperature, threshold: 0.005),
            increasing: "正在升温",
            stable: "基本稳定",
            decreasing: "正在降温"
        )
    }

    private var energyTrendText: String {
        let series = store.timelineFrame.series(kind: .energyCost).first
            ?? store.timelineFrame.series(kind: .energyCPUCost).first
        return trendText(
            PerformanceInsightAnalyzer.trend(points: series?.points ?? [], recentSeconds: 30, relativeThreshold: 0.10),
            increasing: "正在升高",
            stable: "平稳",
            decreasing: "正在降低"
        )
    }

    private func timelineTrend(kind: TimelineSeriesKind, threshold: Double) -> PerformanceTrendDirection {
        PerformanceInsightAnalyzer.trend(
            points: store.timelineFrame.series(kind: kind).first?.points ?? [],
            recentSeconds: 30,
            relativeThreshold: threshold
        )
    }

    private func trendText(
        _ trend: PerformanceTrendDirection,
        increasing: String,
        stable: String,
        decreasing: String
    ) -> String {
        switch trend {
        case .increasing: return increasing
        case .stable: return stable
        case .decreasing: return decreasing
        case .insufficientData: return "数据不足"
        }
    }

    private func batteryMetric(_ name: String, confirmed: Bool = false) -> String {
        guard let metric = store.latestBattery?.metric(name) else { return "—" }
        return confirmed ? metric.confirmedDisplay : "\(metric.rawDisplay)（原始值）"
    }

    private var firstEnergyMetric: String {
        guard let sample = store.latestEnergy,
              let key = sample.metrics.keys.sorted().first,
              let metric = sample.metrics[key]
        else { return "—" }
        return metric.rawDisplay
    }

    private func networkRate(_ kind: TimelineSeriesKind) -> String {
        guard let value = store.timelineFrame.series(kind: kind).first?.points.last?.value else { return "—" }
        if value >= 1_048_576 { return String(format: "%.1f MB/s", value / 1_048_576) }
        if value >= 1_024 { return String(format: "%.1f KB/s", value / 1_024) }
        return String(format: "%.0f B/s", value)
    }

    private func providerTitle(_ provider: String) -> String {
        switch provider.lowercased() {
        case "sysmon", "system", "process": return "处理器"
        case "battery": return "电池"
        case "energy": return "能耗"
        case "network": return "网络"
        case "oslog": return "系统日志"
        default: return "性能"
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
