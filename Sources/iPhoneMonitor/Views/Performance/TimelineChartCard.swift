import Charts
import SwiftUI
import iPhoneMonitorCore

struct TimelineChartCard: View {
    let title: String
    let subtitle: String
    let yAxisTitle: String
    let valueLabel: String
    let series: [TimelineSeries]
    let events: [TimelineEvent]
    let xDomain: ClosedRange<Double>

    @State private var selection: ChartSelection?

    static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .indigo, .mint
    ]

    var body: some View {
        SectionCard(title) {
            VStack(alignment: .leading, spacing: 10) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if series.allSatisfy(\.isEmpty) {
                    TimelineEmptyStateView(message: "当前时间范围没有真实样本；不会补造或连接缺失数据。")
                } else {
                    Chart {
                        ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                            ForEach(item.segments) { segment in
                                ForEach(segment.points) { point in
                                    LineMark(
                                        x: .value("相对时间（秒）", point.relativeSeconds),
                                        y: .value(item.unitLabel, point.value),
                                        series: .value("连续段", segment.id)
                                    )
                                    .foregroundStyle(Self.palette[index % Self.palette.count])
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                                    .interpolationMethod(.linear)
                                }
                            }
                        }

                        ForEach(events.filter { $0.kind == .streamGap }) { event in
                            RuleMark(x: .value("数据中断", event.relativeSeconds))
                                .foregroundStyle(.secondary.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .annotation(position: .top, alignment: .leading) {
                                    Image(systemName: "waveform.path.badge.minus")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help("\(event.title)：\(event.detail)")
                                }
                        }

                        ForEach(events.filter { $0.kind == .userMarker }) { event in
                            RuleMark(x: .value("卡顿标记", event.relativeSeconds))
                                .foregroundStyle(.orange)
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .annotation(position: .top, alignment: .trailing) {
                                    Image(systemName: "flag.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .help("+\(String(format: "%.1f", event.relativeSeconds)) 秒：\(event.detail)")
                                }
                        }

                        if let selection {
                            RuleMark(x: .value("选中时间", selection.point.relativeSeconds))
                                .foregroundStyle(.secondary.opacity(0.55))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            PointMark(
                                x: .value("监控时间", selection.point.relativeSeconds),
                                y: .value(valueLabel, selection.point.value)
                            )
                            .foregroundStyle(selection.color)
                            .symbolSize(34)
                            .annotation(position: .top, spacing: 8) {
                                tooltip(selection)
                            }
                        }
                    }
                    .chartXScale(domain: xDomain)
                    .chartXAxisLabel("监控时间", position: .bottom, alignment: .center)
                    .chartYAxisLabel(yAxisTitle, position: .leading, alignment: .center)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let seconds = value.as(Double.self) {
                                    Text(Self.elapsed(seconds))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(minHeight: 185, idealHeight: 210)
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        updateSelection(at: location, proxy: proxy, geometry: geometry)
                                    case .ended:
                                        selection = nil
                                    }
                                }
                        }
                    }

                    TimelineLegendView(series: series, colors: Self.palette)

                    if let range = valueRange {
                        Text("真实可见范围：\(format(range.lowerBound)) ～ \(format(range.upperBound))；纵轴自动适配且不裁剪异常点。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var valueRange: ClosedRange<Double>? {
        var minimum: Double?
        var maximum: Double?
        for item in series {
            for segment in item.segments {
                for point in segment.points where point.value.isFinite {
                    minimum = min(minimum ?? .infinity, point.value)
                    maximum = max(maximum ?? -.infinity, point.value)
                }
            }
        }
        guard let minimum, let maximum else { return nil }
        return minimum...maximum
    }

    private func format(_ value: Double) -> String {
        if abs(value) >= 10_000 { return String(format: "%.3g", value) }
        return String(format: "%.3f", value)
    }

    private func updateSelection(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        let plotFrame = geometry[proxy.plotAreaFrame]
        guard plotFrame.contains(location) else {
            selection = nil
            return
        }
        let plotX = location.x - plotFrame.minX
        guard let seconds: Double = proxy.value(atX: plotX) else {
            selection = nil
            return
        }

        selection = series.enumerated().compactMap { index, item -> ChartSelection? in
            guard let point = item.points.min(by: {
                abs($0.relativeSeconds - seconds) < abs($1.relativeSeconds - seconds)
            }) else { return nil }
            return ChartSelection(
                series: item,
                point: point,
                color: Self.palette[index % Self.palette.count]
            )
        }.min {
            abs($0.point.relativeSeconds - seconds) < abs($1.point.relativeSeconds - seconds)
        }
    }

    private func tooltip(_ selection: ChartSelection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.elapsed(selection.point.relativeSeconds))
                .font(.caption.weight(.semibold))
            Text(displayTitle(selection.series))
                .font(.caption)
            Text("\(valueLabel)：\(formattedValue(selection.point.value, unit: selection.series.unitLabel))")
                .font(.caption.monospacedDigit())
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).stroke(.quaternary)
        }
    }

    private func displayTitle(_ item: TimelineSeries) -> String {
        guard let processName = item.processName else { return item.title }
        let name = AppNameResolver.displayName(for: processName)
        return item.pid.map { "\(name)（PID \($0)）" } ?? name
    }

    private func formattedValue(_ value: Double, unit: String) -> String {
        if unit == "bytes/s" {
            if value >= 1_048_576 { return String(format: "%.1f MB/s", value / 1_048_576) }
            if value >= 1_024 { return String(format: "%.1f KB/s", value / 1_024) }
            return String(format: "%.0f B/s", value)
        }
        if unit == "MiB" { return String(format: "%.1f MiB", value) }
        if value.rounded() == value { return "\(Int(value)) \(unit)" }
        return String(format: "%.2f %@", value, unit)
    }

    static func elapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒"
    }
}

private struct ChartSelection {
    let series: TimelineSeries
    let point: TimelinePoint
    let color: Color
}
