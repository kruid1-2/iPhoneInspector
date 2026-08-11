import Foundation

public struct PerformanceDiagnosticSnapshot: Equatable, Sendable {
    public let processor: String
    public let memory: String
    public let memoryExplanation: String
    public let batteryTemperature: String
    public let energy: String
    public let dataQuality: String

    public var allText: String {
        [processor, memory, memoryExplanation, batteryTemperature, energy, dataQuality]
            .joined(separator: " ")
    }
}

public struct PerformanceLagDiagnosticPresentation: Equatable, Sendable {
    public let overview: String
    public let phenomena: [String]
    public let processDisplayNames: [String]
    public let dataIntegrity: String
    public let dataIntegrityDetail: String
}

public enum PerformanceDiagnosticPresenter {
    public static func liveSnapshot(
        frame: PerformanceTimelineFrame,
        streamGapCount: Int,
        providerErrorCount: Int,
        droppedCount: Int
    ) -> PerformanceDiagnosticSnapshot {
        let processorTrend = trend(in: frame, kind: .systemCPU, threshold: 0.08)
        let freeMemoryTrend = PerformanceInsightAnalyzer.trend(
            points: frame.series(kind: .systemVM).first {
                $0.id.localizedCaseInsensitiveContains("vmfreecount")
            }?.points ?? [],
            recentSeconds: 30,
            relativeThreshold: 0.01
        )
        let compressorTrend = PerformanceInsightAnalyzer.trend(
            points: frame.series(kind: .systemVM).first {
                $0.id.localizedCaseInsensitiveContains("vmcompressorpagecount")
            }?.points ?? [],
            recentSeconds: 30,
            relativeThreshold: 0.01
        )
        let batteryTrend = trend(in: frame, kind: .batteryTemperature, threshold: 0.005)
        let energySeries = frame.series(kind: .energyCost).first
            ?? frame.series(kind: .energyCPUCost).first
        let energyTrend = PerformanceInsightAnalyzer.trend(
            points: energySeries?.points ?? [],
            recentSeconds: 30,
            relativeThreshold: 0.10
        )
        let memory = memoryPresentation(free: freeMemoryTrend, compressor: compressorTrend)
        let hasIncompleteData = streamGapCount > 0 || providerErrorCount > 0 || droppedCount > 0

        return PerformanceDiagnosticSnapshot(
            processor: trendText(
                processorTrend,
                increasing: "正在升高",
                stable: "较平稳",
                decreasing: "正在降低"
            ),
            memory: memory.status,
            memoryExplanation: memory.explanation,
            batteryTemperature: trendText(
                batteryTrend,
                increasing: "正在升温",
                stable: "稳定",
                decreasing: "正在降温"
            ),
            energy: trendText(
                energyTrend,
                increasing: "正在升高",
                stable: "平稳",
                decreasing: "正在降低"
            ),
            dataQuality: hasIncompleteData ? "不完整" : "良好"
        )
    }

    public static func lagPresentation(
        summary: PerformanceLagSummary,
        processDisplayNames: [String]
    ) -> PerformanceLagDiagnosticPresentation {
        let names = Array(processDisplayNames.prefix(2))
        let phenomena = lagPhenomena(summary)

        return PerformanceLagDiagnosticPresentation(
            overview: lagOverview(summary, processDisplayNames: names),
            phenomena: phenomena,
            processDisplayNames: names,
            dataIntegrity: summary.confidence == .good ? "良好" : "不完整",
            dataIntegrityDetail: dataIntegrityDetail(summary)
        )
    }

    private static func trend(
        in frame: PerformanceTimelineFrame,
        kind: TimelineSeriesKind,
        threshold: Double
    ) -> PerformanceTrendDirection {
        PerformanceInsightAnalyzer.trend(
            points: frame.series(kind: kind).first?.points ?? [],
            recentSeconds: 30,
            relativeThreshold: threshold
        )
    }

    private static func trendText(
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

    private static func memoryPresentation(
        free: PerformanceTrendDirection,
        compressor: PerformanceTrendDirection
    ) -> (status: String, explanation: String) {
        if free == .insufficientData, compressor == .insufficientData {
            return ("数据不足", "样本不足，暂时无法判断内存趋势。")
        }
        if free == .decreasing, compressor == .increasing {
            return ("内存使用正在变重", "观察到空闲空间减少，同时内存压缩增加。")
        }
        if compressor == .increasing {
            return ("压缩正在增加", "观察到内存压缩趋势正在增加。")
        }
        if free == .decreasing {
            return ("空闲空间正在减少", "观察到空闲空间趋势正在减少。")
        }
        return ("基本稳定", "最近的内存趋势基本稳定。")
    }

    private static func lagOverview(
        _ summary: PerformanceLagSummary,
        processDisplayNames: [String]
    ) -> String {
        if summary.confidence == .incomplete {
            return "卡顿附近存在数据中断或采集异常，以下观察参考有限。"
        }
        if hasInsufficientLagData(summary) {
            return "现有数据不足，暂时无法概括卡顿附近的变化；建议再次出现时继续标记。"
        }

        let processText = processDisplayNames.isEmpty
            ? "相关进程"
            : processDisplayNames.joined(separator: "、")
        if summary.cpuObservation == .high, (summary.appMemory.growthMiB ?? 0) > 0 {
            return "卡顿附近同时观察到较高的处理器活动和应用内存增长，\(processText)值得继续观察；这些现象只是在时间上接近，不能单独说明原因。"
        }
        if summary.cpuObservation == .high {
            return "卡顿附近观察到较高的处理器活动，\(processText)的活动可能相关，建议继续观察后续卡顿是否重复出现。"
        }
        if summary.freeMemoryTrend == .decreasing, summary.compressorTrend == .increasing {
            return "卡顿前后观察到空闲内存减少、内存压缩增加，说明当时系统内存活动变重，值得继续观察。"
        }
        return "当前数据没有观察到单一、明确的同步变化；建议再次出现卡顿时继续标记并结合当时操作观察。"
    }

    private static func lagPhenomena(_ summary: PerformanceLagSummary) -> [String] {
        var result: [String] = []

        switch summary.cpuObservation {
        case .high:
            result.append("处理器活动处于最近一段时间的较高水平")
        case .similar:
            result.append("处理器活动与之前大致相近")
        case .noClearIncrease:
            result.append("处理器活动没有明显升高")
        case .insufficientData:
            break
        }

        if (summary.appMemory.growthMiB ?? 0) > 0 {
            result.append("观察到应用内存增长")
        }
        if summary.freeMemoryTrend == .decreasing, summary.compressorTrend == .increasing {
            result.append("空闲内存减少，内存压缩增加")
        } else {
            if summary.freeMemoryTrend == .decreasing {
                result.append("空闲内存正在减少")
            }
            if summary.compressorTrend == .increasing {
                result.append("内存压缩正在增加")
            }
        }

        switch summary.batteryTemperatureTrend {
        case .increasing:
            result.append("电池温度正在升高")
        case .decreasing:
            result.append("电池温度正在降低")
        case .stable, .insufficientData:
            break
        }

        switch summary.energyObservation {
        case .increased:
            result.append("能耗评分有所升高")
        case .noClearChange:
            result.append("能耗变化不明显")
        case .insufficientData:
            break
        }

        if result.isEmpty, hasInsufficientLagData(summary) {
            result.append("用于比较的数据不足")
        }
        return result
    }

    private static func hasInsufficientLagData(_ summary: PerformanceLagSummary) -> Bool {
        summary.cpuObservation == .insufficientData
            && summary.appMemory.largestMiB == nil
            && summary.appMemory.growthMiB == nil
            && summary.freeMemoryTrend == .insufficientData
            && summary.compressorTrend == .insufficientData
            && summary.batteryTemperatureTrend == .insufficientData
            && summary.energyObservation == .insufficientData
    }

    private static func dataIntegrityDetail(_ summary: PerformanceLagSummary) -> String {
        guard summary.confidence == .incomplete else {
            return "采集期间未记录数据中断、数据源错误或队列丢弃。"
        }

        var details: [String] = []
        if summary.streamGapCount > 0 {
            details.append("\(summary.streamGapCount) 次数据中断")
        }
        if summary.providerErrorCount > 0 {
            details.append("\(summary.providerErrorCount) 次数据源错误")
        }
        if summary.droppedCount > 0 {
            details.append("\(summary.droppedCount) 条队列丢弃")
        }
        if details.isEmpty {
            return "采集完整性不足，部分观察可能不完整。"
        }
        return details.joined(separator: "、") + "，部分观察可能不完整。"
    }
}
