import SwiftUI
import iPhoneMonitorCore

private enum TimelineMetricGroup: String, CaseIterable, Identifiable {
    case cpu
    case processes
    case memory
    case battery
    case energy
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "处理器"
        case .processes: return "应用与进程"
        case .memory: return "内存"
        case .battery: return "电池"
        case .energy: return "能耗"
        case .network: return "网络"
        }
    }
}

struct PerformanceTimelineView: View, Equatable {
    let frame: PerformanceTimelineFrame
    let revision: UInt64
    let range: PerformanceTimelineRange
    let onRangeChange: (PerformanceTimelineRange) -> Void
    let onProcessFilterChange: (String, Bool) -> Void
    let onVisibilityChange: (Bool) -> Void

    @SceneStorage("performance.timeline.marker") private var selectedMarkerID: String?
    @SceneStorage("performance.timeline.metric") private var selectedMetricGroupRaw = TimelineMetricGroup.cpu.rawValue
    @SceneStorage("performance.timeline.processSearch") private var processSearch = ""

    static func == (lhs: PerformanceTimelineView, rhs: PerformanceTimelineView) -> Bool {
        lhs.revision == rhs.revision && lhs.range == rhs.range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls

            if frame.sessionID == nil {
                TimelineEmptyStateView(message: "开始监控后，图表会按监控时间持续更新；缺失数据不会被补造。")
            } else {
                TimelineEventOverlay(
                    events: frame.events,
                    selectedMarkerID: selectedMarkerID,
                    onSelectMarker: focus(on:)
                )

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        selectedCharts
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .onAppear {
            onProcessFilterChange(processSearch, false)
            onVisibilityChange(true)
        }
        .onDisappear { onVisibilityChange(false) }
        .onChange(of: processSearch) { query in
            onProcessFilterChange(query, false)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker(
                    "时间范围",
                    selection: Binding(
                        get: { range },
                        set: {
                            selectedMarkerID = nil
                            onRangeChange($0)
                        }
                    )
                ) {
                    ForEach(PerformanceTimelineRange.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)

                Spacer()

                Text("收到 \(frame.rawPointCount) · 显示 \(frame.plottedPointCount) 个数据点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                Picker("指标", selection: metricGroupBinding) {
                    ForEach(TimelineMetricGroup.allCases) { group in
                        Text(group.title).tag(group)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)

                Spacer()
            }

            HStack(spacing: 10) {
                TextField("关注进程（名称或 PID）", text: $processSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                if let marker = selectedMarker {
                    Label(
                        "聚焦 +\(marker.relativeSeconds, specifier: "%.1f") 秒：前 60 秒 / 后 120 秒",
                        systemImage: "flag.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Button("退出聚焦") { selectedMarkerID = nil }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedCharts: some View {
        switch selectedMetricGroup {
        case .cpu:
            trendOverview(
                title: "现在的处理器状态",
                value: latestValue(frame.series(kind: .systemCPU).first).map(formatRaw) ?? "暂未获取到数据",
                trend: cpuTrendText,
                detail: "根据最近约 30 秒的真实样本判断趋势，不使用单个样本下结论。"
            )
            TimelineChartCard(
                title: "手机整体处理器负载",
                subtitle: "数值越高表示手机处理器整体越忙，不能直接理解为 CPU 百分比。",
                yAxisTitle: "负载原始值",
                valueLabel: "手机整体处理器负载",
                series: frame.series(kind: .systemCPU),
                events: chartEvents(provider: "sysmon"),
                xDomain: xDomain
            )
        case .processes:
            TimelineChartCard(
                title: "当前高负载应用",
                subtitle: processSubtitle,
                yAxisTitle: "处理器负载",
                valueLabel: "处理器负载",
                series: selectedProcessSeries(kind: .processCPU),
                events: chartEvents(provider: "sysmon"),
                xDomain: xDomain
            )
            TimelineChartCard(
                title: "应用内存占用",
                subtitle: "内存按已确认的字节数换算为 MiB；同一 PID 对应新进程时会另起一条线。",
                yAxisTitle: "内存（MiB）",
                valueLabel: "内存",
                series: selectedProcessSeries(kind: .processMemory),
                events: chartEvents(provider: "sysmon"),
                xDomain: xDomain
            )
            processMemorySummary
            if !observerSeries(kind: .processCPU).isEmpty {
                DisclosureGroup("监控自身开销") {
                    TimelineChartCard(
                        title: "监控工具相关进程",
                        subtitle: "这些进程来自监控链路，不进入默认高负载应用排名。",
                        yAxisTitle: "处理器负载",
                        valueLabel: "处理器负载",
                        series: observerSeries(kind: .processCPU),
                        events: chartEvents(provider: "sysmon"),
                        xDomain: xDomain
                    )
                    .padding(.top, 8)
                }
            }
        case .memory:
            memoryStatusOverview
            TimelineChartCard(
                title: "空闲内存趋势",
                subtitle: "主图只观察空闲内存页的变化方向；页大小未确认，因此不换算为 GB。",
                yAxisTitle: "内存页数（原始计数）",
                valueLabel: "空闲页数",
                series: [freeMemorySeries].compactMap { $0 },
                events: chartEvents(provider: "sysmon"),
                xDomain: xDomain
            )
            TimelineChartCard(
                title: "内存压缩趋势",
                subtitle: "持续增加通常说明内存使用正在变重，但不能单凭这一项判断内存不足。",
                yAxisTitle: "压缩页数（原始计数）",
                valueLabel: "压缩内存页数",
                series: [compressorSeries].compactMap { $0 },
                events: chartEvents(provider: "sysmon"),
                xDomain: xDomain
            )
            DisclosureGroup("详细数据") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(frame.series(kind: .systemVM)) { series in
                        HStack {
                            Text(series.title)
                            Spacer()
                            Text(latestValue(series).map(formatRaw) ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Text("以上均为设备返回的 VM 原始字段；没有可靠 page size 时不换算为 MiB 或 GB。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        case .battery:
            trendOverview(
                title: "电池温度变化",
                value: latestValue(frame.series(kind: .batteryTemperature).first).map {
                    "原始值 \(formatRaw($0))"
                } ?? "暂未获取到数据",
                trend: batteryTrendText,
                detail: "这里只判断升温或降温趋势；该值不是 CPU 或 SoC 温度，单位尚未确认。"
            )
            batteryCard(kind: .batteryTemperature, title: "电池温度趋势")
            DisclosureGroup("详细数据") {
                VStack(alignment: .leading, spacing: 14) {
                    batteryCard(kind: .batteryVoltage, title: "电池电压")
                    batteryCard(kind: .batteryCurrent, title: "电池电流")
                }
                .padding(.top, 8)
            }
        case .energy:
            trendOverview(
                title: "现在的能耗活动",
                value: latestValue(primaryEnergySeries).map(formatRaw) ?? "暂未获取到数据",
                trend: energyTrendText,
                detail: "这是相对评分的近期变化，不代表瓦特或焦耳。"
            )
            TimelineChartCard(
                title: "系统能耗活动",
                subtitle: "这是 Apple 性能接口提供的相对评分，用于比较不同时间的能耗变化，不代表瓦特或焦耳。",
                yAxisTitle: "能耗评分",
                valueLabel: "能耗评分",
                series: frame.series.filter {
                    $0.kind == .energyCost || $0.kind == .energyCPUCost
                },
                events: chartEvents(provider: "energy"),
                xDomain: xDomain
            )
        case .network:
            TimelineChartCard(
                title: "网络活动",
                subtitle: "根据相邻样本的真实时间差计算平均速度；不保留地址、域名或通信内容。",
                yAxisTitle: "网络速度",
                valueLabel: "网络速度",
                series: frame.series.filter {
                    $0.kind == .networkReceive || $0.kind == .networkTransmit
                },
                events: chartEvents(provider: "network"),
                xDomain: xDomain
            )
        }
    }

    private var selectedMetricGroup: TimelineMetricGroup {
        TimelineMetricGroup(rawValue: selectedMetricGroupRaw) ?? .cpu
    }

    private var metricGroupBinding: Binding<TimelineMetricGroup> {
        Binding(
            get: { selectedMetricGroup },
            set: { selectedMetricGroupRaw = $0.rawValue }
        )
    }

    private func batteryCard(kind: TimelineSeriesKind, title: String) -> some View {
        let subtitle: String
        switch kind {
        case .batteryTemperature:
            subtitle = "用于观察升温或降温趋势，当前单位尚未确认；它不是 CPU 或 SoC 温度。"
        case .batteryVoltage:
            subtitle = "设备返回的电压原始值；单位未确认，不换算伏特。"
        default:
            subtitle = "设备返回的电流原始值；单位与正负号语义未确认，不计算功率。"
        }
        return TimelineChartCard(
            title: title,
            subtitle: subtitle,
            yAxisTitle: kind == .batteryTemperature ? "温度原始值" : "原始值",
            valueLabel: title,
            series: frame.series(kind: kind),
            events: chartEvents(provider: "battery"),
            xDomain: xDomain
        )
    }

    private var selectedMarker: TimelineEvent? {
        frame.events.first { $0.id == selectedMarkerID && $0.kind == .userMarker }
    }

    private var xDomain: ClosedRange<Double> {
        let frameLower = frame.visibleLowerBound
        let frameUpper = max(frame.visibleUpperBound, frameLower + 1)
        guard let marker = selectedMarker else { return frameLower...frameUpper }
        let lower = max(0, marker.relativeSeconds - 60)
        let requestedUpper = marker.relativeSeconds + 120
        return lower...max(lower + 1, min(frameUpper, requestedUpper))
    }

    private func focus(on marker: TimelineEvent) {
        selectedMarkerID = marker.id
        if range != .all { onRangeChange(.all) }
    }

    private var processSubtitle: String {
        if processSearch.isEmpty {
            return "默认显示最多 5 个高负载应用或重要系统进程；监控工具自身开销单独列出。"
        }
        return "当前按名称或 PID 筛选；监控工具自身开销不会被自动列为卡顿嫌疑。"
    }

    private func selectedProcessSeries(kind: TimelineSeriesKind) -> [TimelineSeries] {
        let all = frame.series(kind: kind)
        let filteredObservers = all.filter { !$0.observerOverhead }
        if !processSearch.isEmpty {
            return filteredObservers.filter {
                ($0.processName?.localizedCaseInsensitiveContains(processSearch) == true)
                    || ($0.pid.map(String.init)?.contains(processSearch) == true)
            }.prefix(5).map { $0 }
        }

        var selected = filteredObservers.filter {
            guard let identity = $0.processIdentity else { return false }
            return frame.recommendedProcessIdentities.contains(identity)
        }
        selected.sort {
            let left = $0.processIdentity.flatMap(frame.recommendedProcessIdentities.firstIndex) ?? .max
            let right = $1.processIdentity.flatMap(frame.recommendedProcessIdentities.firstIndex) ?? .max
            return left < right
        }
        return Array(selected.prefix(5))
    }

    private var freeMemorySeries: TimelineSeries? {
        frame.series(kind: .systemVM).first { $0.id.localizedCaseInsensitiveContains("vmfreecount") }
    }

    private var compressorSeries: TimelineSeries? {
        frame.series(kind: .systemVM).first { $0.id.localizedCaseInsensitiveContains("vmcompressorpagecount") }
    }

    private var primaryEnergySeries: TimelineSeries? {
        frame.series(kind: .energyCost).first ?? frame.series(kind: .energyCPUCost).first
    }

    private var cpuTrendText: String {
        trendText(
            PerformanceInsightAnalyzer.trend(
                points: frame.series(kind: .systemCPU).first?.points ?? [],
                recentSeconds: 30,
                relativeThreshold: 0.08
            ),
            increasing: "正在升高",
            stable: "较平稳",
            decreasing: "正在降低"
        )
    }

    private var batteryTrendText: String {
        trendText(
            PerformanceInsightAnalyzer.trend(
                points: frame.series(kind: .batteryTemperature).first?.points ?? [],
                recentSeconds: 30,
                relativeThreshold: 0.005
            ),
            increasing: "正在升温",
            stable: "基本稳定",
            decreasing: "正在降温"
        )
    }

    private var energyTrendText: String {
        trendText(
            PerformanceInsightAnalyzer.trend(
                points: primaryEnergySeries?.points ?? [],
                recentSeconds: 30,
                relativeThreshold: 0.10
            ),
            increasing: "正在升高",
            stable: "平稳",
            decreasing: "正在降低"
        )
    }

    private var memoryStatusOverview: some View {
        SectionCard("系统内存状态") {
            VStack(alignment: .leading, spacing: 10) {
                memoryTrendRow(
                    "空闲内存趋势",
                    trend: PerformanceInsightAnalyzer.trend(
                        points: freeMemorySeries?.points ?? [],
                        recentSeconds: 30,
                        relativeThreshold: 0.01
                    ),
                    increasing: "空闲空间正在增加",
                    decreasing: "空闲空间正在减少"
                )
                Divider()
                memoryTrendRow(
                    "内存压缩趋势",
                    trend: PerformanceInsightAnalyzer.trend(
                        points: compressorSeries?.points ?? [],
                        recentSeconds: 30,
                        relativeThreshold: 0.01
                    ),
                    increasing: "内存压缩增加",
                    decreasing: "内存压缩减少"
                )
                DisclosureGroup("怎么看？") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("空闲空间减少：系统剩余的空闲内存页正在变少。")
                        Text("内存压缩增加：iOS 正在更多地压缩内存内容来节省空间。")
                        Text("这两个指标主要用于观察变化趋势，目前不能直接换算成剩余多少 GB，也不能单独证明系统内存不足。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                }
            }
        }
    }

    private var processMemorySummary: some View {
        let items = selectedProcessSeries(kind: .processMemory).compactMap { series -> (TimelineSeries, Double, Double?)? in
            guard let latest = latestValue(series) else { return nil }
            let cutoff = (series.points.last?.relativeSeconds ?? 0) - 30
            let earlier = series.points.filter { $0.relativeSeconds >= cutoff }.first?.value
            return (series, latest, earlier.map { latest - $0 })
        }.sorted { $0.1 > $1.1 }

        return SectionCard("应用内存概览") {
            if items.isEmpty {
                Text("暂未获取到可确认的应用内存数据。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items, id: \.0.id) { item in
                        HStack {
                            Text(item.0.processName.map(AppNameResolver.displayName) ?? item.0.title)
                            Spacer()
                            Text(String(format: "%.1f MiB", item.1))
                                .monospacedDigit()
                            if let delta = item.2 {
                                Text(memoryDelta(delta))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func observerSeries(kind: TimelineSeriesKind) -> [TimelineSeries] {
        Array(frame.series(kind: kind).filter(\.observerOverhead).prefix(5))
    }

    private func trendOverview(title: String, value: String, trend: String, detail: String) -> some View {
        SectionCard(title) {
            HStack(alignment: .firstTextBaseline) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(trend).foregroundStyle(.secondary)
                Spacer()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func memoryTrendRow(
        _ title: String,
        trend: PerformanceTrendDirection,
        increasing: String,
        decreasing: String
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(trendText(trend, increasing: increasing, stable: "基本稳定", decreasing: decreasing))
                .fontWeight(.medium)
        }
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

    private func latestValue(_ series: TimelineSeries?) -> Double? {
        series?.points.max(by: { $0.monotonicNS < $1.monotonicNS })?.value
    }

    private func formatRaw(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private func memoryDelta(_ value: Double) -> String {
        if abs(value) < 0.1 { return "最近 30 秒基本稳定" }
        return String(format: "%@ 最近 30 秒%@ %.1f MiB", value > 0 ? "↑" : "↓", value > 0 ? "增加" : "减少", abs(value))
    }

    private func chartEvents(provider: String) -> [TimelineEvent] {
        frame.events.filter { event in
            guard event.relativeSeconds >= xDomain.lowerBound,
                  event.relativeSeconds <= xDomain.upperBound
            else { return false }
            if event.kind == .userMarker { return true }
            guard event.kind == .streamGap else { return false }
            let eventProvider = event.provider?.lowercased() ?? ""
            return eventProvider == provider.lowercased()
                || (provider == "sysmon" && ["system", "process"].contains(eventProvider))
        }
    }
}
