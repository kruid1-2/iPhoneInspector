import Foundation
import XCTest
@testable import iPhoneMonitorCore

final class PerformanceDiagnosticPresentationTests: XCTestCase {
    func testLiveSnapshotUsesTrendsWithoutRawUnits() {
        let snapshot = PerformanceDiagnosticPresenter.liveSnapshot(
            frame: frame(
                cpu: [10, 10, 12, 16],
                freeMemory: [100, 100, 90, 80],
                compressor: [10, 10, 12, 16],
                batteryTemperature: [4_000, 4_000, 4_030, 4_060],
                energy: [10, 10, 12, 16]
            ),
            streamGapCount: 0,
            providerErrorCount: 0,
            droppedCount: 0
        )

        XCTAssertEqual(snapshot.processor, "正在升高")
        XCTAssertEqual(snapshot.memory, "内存使用正在变重")
        XCTAssertEqual(snapshot.batteryTemperature, "正在升温")
        XCTAssertEqual(snapshot.energy, "正在升高")
        XCTAssertEqual(snapshot.dataQuality, "良好")
        XCTAssertFalse(snapshot.allText.contains("%"))
        XCTAssertFalse(snapshot.allText.contains("℃"))
    }

    func testLiveSnapshotDistinguishesMemorySignalsAndIncompleteData() {
        let compressor = PerformanceDiagnosticPresenter.liveSnapshot(
            frame: frame(
                cpu: [10, 10, 10],
                freeMemory: [100, 100, 100],
                compressor: [10, 10, 12, 16],
                batteryTemperature: [4_000, 4_000, 4_000],
                energy: [10, 10, 10]
            ),
            streamGapCount: 0,
            providerErrorCount: 1,
            droppedCount: 0
        )
        let fallingFreeMemory = PerformanceDiagnosticPresenter.liveSnapshot(
            frame: frame(freeMemory: [100, 100, 90, 80]),
            streamGapCount: 0,
            providerErrorCount: 0,
            droppedCount: 1
        )

        XCTAssertEqual(compressor.processor, "较平稳")
        XCTAssertEqual(compressor.memory, "压缩正在增加")
        XCTAssertEqual(compressor.batteryTemperature, "稳定")
        XCTAssertEqual(compressor.energy, "平稳")
        XCTAssertEqual(compressor.dataQuality, "不完整")
        XCTAssertEqual(fallingFreeMemory.memory, "空闲空间正在减少")
        XCTAssertEqual(fallingFreeMemory.dataQuality, "不完整")
    }

    func testLiveSnapshotReportsInsufficientDataInsteadOfInferringFromOnePoint() {
        let snapshot = PerformanceDiagnosticPresenter.liveSnapshot(
            frame: frame(cpu: [10], freeMemory: [100], compressor: [10], batteryTemperature: [4_000], energy: [10]),
            streamGapCount: 0,
            providerErrorCount: 0,
            droppedCount: 0
        )

        XCTAssertEqual(snapshot.processor, "数据不足")
        XCTAssertEqual(snapshot.memory, "数据不足")
        XCTAssertEqual(snapshot.batteryTemperature, "数据不足")
        XCTAssertEqual(snapshot.energy, "数据不足")
    }

    func testLiveSnapshotReportsPartialMemoryDataWhenFreeTrendIsInsufficient() {
        let snapshot = PerformanceDiagnosticPresenter.liveSnapshot(
            frame: frame(freeMemory: [100], compressor: [10, 10, 10]),
            streamGapCount: 0,
            providerErrorCount: 0,
            droppedCount: 0
        )

        XCTAssertEqual(snapshot.memory, "内存数据部分不足")
        XCTAssertEqual(snapshot.memoryExplanation, "内存压缩趋势基本稳定，但空闲空间数据不足。")
    }

    func testLiveSnapshotReportsPartialMemoryDataWhenCompressorTrendIsInsufficient() {
        let snapshot = PerformanceDiagnosticPresenter.liveSnapshot(
            frame: frame(freeMemory: [100, 100, 100], compressor: [10]),
            streamGapCount: 0,
            providerErrorCount: 0,
            droppedCount: 0
        )

        XCTAssertEqual(snapshot.memory, "内存数据部分不足")
        XCTAssertEqual(snapshot.memoryExplanation, "空闲空间基本稳定，但内存压缩趋势数据不足。")
    }

    func testIncompleteLagOverviewLeadsWithLimitedReference() {
        let presentation = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(
                cpu: .high,
                memory: memory(growth: 40),
                streamGapCount: 1,
                providerErrorCount: 2,
                droppedCount: 3,
                confidence: .incomplete
            ),
            processDisplayName: { $0 }
        )

        XCTAssertEqual(presentation.confidence, .incomplete)
        XCTAssertTrue(presentation.overview.contains("卡顿分析依赖范围"))
        XCTAssertTrue(presentation.overview.contains("本次监控会话"))
        XCTAssertFalse(presentation.overview.contains("卡顿附近存在"))
        XCTAssertEqual(presentation.dataIntegrity, "不完整")
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("1 次数据中断"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("2 次采集组件异常"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("3 条采集消息丢弃"))
        XCTAssertEqual(presentation.integrityIssues.map(\.kind), [.streamGap, .providerError, .droppedMessage])
        XCTAssertEqual(
            presentation.integrityIssues.map(\.scope),
            [.analysisDependencyWindow, .monitoringSession, .monitoringSession]
        )
    }

    func testProviderErrorsUseSessionScopeAndUnknownTiming() {
        let presentation = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(providerErrorCount: 2, confidence: .incomplete),
            processDisplayName: { $0 }
        )

        XCTAssertTrue(presentation.dataIntegrityDetail.contains("本次监控会话"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("2 次采集组件异常"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("发生时间无法确认"))
        XCTAssertFalse(presentation.overview.contains("卡顿附近存在数据中断或采集异常"))
        XCTAssertEqual(presentation.integrityIssues.map(\.kind), [.providerError])
        XCTAssertEqual(presentation.integrityIssues.map(\.scope), [.monitoringSession])
    }

    func testDroppedMessagesUseSessionCumulativeScopeAndUnknownTiming() {
        let presentation = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(droppedCount: 3, confidence: .incomplete),
            processDisplayName: { $0 }
        )

        XCTAssertTrue(presentation.dataIntegrityDetail.contains("本次监控会话累计"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("3 条采集消息丢弃"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("具体发生时间无法确认"))
        XCTAssertFalse(presentation.overview.contains("卡顿附近存在数据中断或采集异常"))
        XCTAssertEqual(presentation.integrityIssues.map(\.kind), [.droppedMessage])
        XCTAssertEqual(presentation.integrityIssues.map(\.scope), [.monitoringSession])
    }

    func testBothLagViewsDelegateToSharedLagPresenter() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewPaths = [
            "Sources/iPhoneMonitor/Views/Performance/LagSummaryView.swift",
            "Sources/iPhoneMonitor/Views/Performance/PerformanceDiagnosticView.swift"
        ]

        for path in viewPaths {
            let source = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(
                source.contains("PerformanceDiagnosticPresenter.lagPresentation("),
                "\(path) must keep using the shared lag presentation"
            )
        }
    }

    func testGoodHighCPUAndMemoryGrowthKeepsMeasuredOverview() {
        let presentation = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(
                cpu: .high,
                busiestProcesses: [
                    process(identity: "100:WeChat:0", name: "WeChat", pid: 100, cpuRaw: 90),
                    process(identity: "200:SpringBoard:0", name: "SpringBoard", pid: 200, cpuRaw: 70)
                ],
                memory: memory(growth: 40)
            ),
            processDisplayName: { name in
                name == "WeChat" ? "微信" : "SpringBoard（系统界面）"
            }
        )

        XCTAssertEqual(presentation.confidence, .good)
        XCTAssertEqual(
            presentation.overview,
            "卡顿附近同时观察到较高的处理器活动和应用内存增长，微信、SpringBoard（系统界面）值得继续观察；这些现象只是在时间上接近，不能单独说明原因。"
        )
        XCTAssertEqual(
            presentation.phenomena,
            ["处理器活动处于最近一段时间的较高水平", "观察到应用内存增长"]
        )
        XCTAssertEqual(presentation.dataIntegrity, "良好")
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("截至摘要生成时"))
    }

    func testNeutralAndInsufficientLagSummariesStayMeasured() {
        let neutralProcesses = [
            process(identity: "100:WeChat:0", name: "微信", pid: 100, cpuRaw: 30),
            process(identity: "200:SpringBoard:0", name: "SpringBoard（系统界面）", pid: 200, cpuRaw: 20),
            process(identity: "300:Camera:0", name: "相机", pid: 300, cpuRaw: 10)
        ]
        let neutral = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(
                cpu: .noClearIncrease,
                busiestProcesses: neutralProcesses,
                freeMemoryTrend: .stable,
                compressorTrend: .stable,
                batteryTemperatureTrend: .stable,
                energy: .noClearChange
            ),
            processDisplayName: { $0 }
        )
        let insufficient = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(),
            processDisplayName: { $0 }
        )

        XCTAssertTrue(neutral.overview.contains("没有观察到单一、明确的同步变化"))
        XCTAssertEqual(neutral.relatedProcesses.map(\.displayName), ["微信", "SpringBoard（系统界面）", "相机"])
        XCTAssertEqual(neutral.dataIntegrity, "良好")
        XCTAssertEqual(insufficient.overview, "现有数据不足，暂时无法概括卡顿附近的变化；建议再次出现时继续标记。")
        XCTAssertEqual(insufficient.phenomena, ["用于比较的数据不足"])
        XCTAssertTrue(insufficient.relatedProcesses.isEmpty)
        XCTAssertFalse(insufficient.overview.contains("没有观察到单一、明确的同步变化"))
    }

    func testLagPresentationPreservesDistinctProcessIdentitiesWhenDisplayNamesMatch() {
        let presentation = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(
                cpu: .high,
                busiestProcesses: [
                    process(identity: "101:com.tencent.xin:0", name: "com.tencent.xin", pid: 101, cpuRaw: 60),
                    process(identity: "101:com.tencent.xin:1", name: "WeChat", pid: 101, cpuRaw: 55)
                ]
            ),
            processDisplayName: { _ in "微信" }
        )

        XCTAssertEqual(
            presentation.relatedProcesses.map(\.identity),
            ["101:com.tencent.xin:0", "101:com.tencent.xin:1"]
        )
        XCTAssertEqual(presentation.relatedProcesses.map(\.displayName), ["微信", "微信"])
        XCTAssertEqual(presentation.relatedProcesses.map(\.id), presentation.relatedProcesses.map(\.identity))
        XCTAssertEqual(presentation.relatedProcesses.map(\.pid), [101, 101])
        XCTAssertEqual(presentation.relatedProcesses.map(\.cpuRaw), [60, 55])
    }

    func testLagPhenomenaDescribeMemoryTemperatureAndEnergyWithoutCausalClaims() {
        let presentation = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(
                cpu: .similar,
                memory: memory(growth: 40),
                freeMemoryTrend: .decreasing,
                compressorTrend: .increasing,
                batteryTemperatureTrend: .increasing,
                energy: .increased
            ),
            processDisplayName: { $0 == "WeChat" ? "微信" : $0 }
        )
        let allText = ([presentation.overview] + presentation.phenomena
            + presentation.relatedProcesses.map(\.displayName)
            + [
                presentation.processor,
                presentation.applicationMemory,
                presentation.systemMemory,
                presentation.batteryTemperature,
                presentation.energy,
                presentation.dataIntegrity,
                presentation.dataIntegrityDetail
            ])
            .joined(separator: " ")

        XCTAssertEqual(presentation.processor, "卡顿附近的处理器负载与之前大致相近")
        XCTAssertTrue(presentation.applicationMemory.contains("微信在分析窗口内增加约 40.0 MiB"))
        XCTAssertTrue(presentation.systemMemory.contains("空闲内存页减少"))
        XCTAssertTrue(presentation.systemMemory.contains("压缩内存页增加"))
        XCTAssertEqual(presentation.batteryTemperature, "正在升温")
        XCTAssertEqual(presentation.energy, "卡顿附近的能耗评分有所升高")
        XCTAssertTrue(presentation.phenomena.contains("观察到应用内存增长"))
        XCTAssertTrue(presentation.phenomena.contains("空闲内存减少，内存压缩增加"))
        XCTAssertTrue(presentation.phenomena.contains("电池温度正在升高"))
        XCTAssertTrue(presentation.phenomena.contains("能耗评分有所升高"))
        for forbidden in ["根因就是", "一定是", "确定由", "硬件故障"] {
            XCTAssertFalse(allText.contains(forbidden), "Unexpected causal claim: \(forbidden)")
        }
    }

    private func frame(
        cpu: [Double] = [],
        freeMemory: [Double] = [],
        compressor: [Double] = [],
        batteryTemperature: [Double] = [],
        energy: [Double] = []
    ) -> PerformanceTimelineFrame {
        let definitions: [(String, TimelineSeriesKind, [Double])] = [
            ("cpu", .systemCPU, cpu),
            ("vmFreeCount", .systemVM, freeMemory),
            ("vmCompressorPageCount", .systemVM, compressor),
            ("temperature", .batteryTemperature, batteryTemperature),
            ("energy", .energyCost, energy)
        ]
        let series = definitions.compactMap { id, kind, values -> TimelineSeries? in
            guard !values.isEmpty else { return nil }
            let points = values.enumerated().map { index, value in
                TimelinePoint(
                    id: "\(id)-\(index)",
                    sessionID: "presentation-session",
                    seriesID: id,
                    timestamp: nil,
                    monotonicNS: UInt64(index) * 10_000_000_000,
                    relativeSeconds: Double(index) * 10,
                    value: value
                )
            }
            return TimelineSeries(
                id: id,
                title: id,
                detail: "",
                provider: "test",
                unitLabel: "raw",
                kind: kind,
                segments: [TimelineSegment(id: "\(id)-segment", points: points)]
            )
        }
        return PerformanceTimelineFrame(
            sessionID: "presentation-session",
            range: .minute1,
            visibleLowerBound: 0,
            visibleUpperBound: 30,
            series: series,
            events: [],
            recommendedProcessIdentities: [],
            rawPointCount: series.reduce(0) { $0 + $1.points.count },
            plottedPointCount: series.reduce(0) { $0 + $1.points.count }
        )
    }

    private func memory(growth: Double? = nil) -> LagMemoryObservation {
        LagMemoryObservation(
            largestProcessIdentity: growth == nil ? nil : "wechat:100",
            largestProcessName: growth == nil ? nil : "WeChat",
            largestProcessPID: growth == nil ? nil : 100,
            largestMiB: growth == nil ? nil : 180,
            fastestGrowthProcessIdentity: growth == nil ? nil : "wechat:100",
            fastestGrowthProcessName: growth == nil ? nil : "WeChat",
            fastestGrowthProcessPID: growth == nil ? nil : 100,
            growthMiB: growth
        )
    }

    private func process(
        identity: String,
        name: String,
        pid: Int?,
        cpuRaw: Double
    ) -> LagProcessObservation {
        LagProcessObservation(identity: identity, name: name, pid: pid, cpuRaw: cpuRaw)
    }

    private func summary(
        cpu: LagCPUObservation = .insufficientData,
        busiestProcesses: [LagProcessObservation] = [],
        memory: LagMemoryObservation? = nil,
        freeMemoryTrend: PerformanceTrendDirection = .insufficientData,
        compressorTrend: PerformanceTrendDirection = .insufficientData,
        batteryTemperatureTrend: PerformanceTrendDirection = .insufficientData,
        energy: LagEnergyObservation = .insufficientData,
        streamGapCount: Int = 0,
        providerErrorCount: Int = 0,
        droppedCount: Int = 0,
        confidence: LagDataConfidence = .good
    ) -> PerformanceLagSummary {
        PerformanceLagSummary(
            markerID: 1,
            markerTimestamp: nil,
            note: "",
            preWindowSeconds: 30,
            postWindowSeconds: 10,
            cpuObservation: cpu,
            busiestProcesses: busiestProcesses,
            appMemory: memory ?? self.memory(),
            freeMemoryTrend: freeMemoryTrend,
            compressorTrend: compressorTrend,
            batteryTemperatureTrend: batteryTemperatureTrend,
            batteryTemperatureStartRaw: nil,
            batteryTemperatureEndRaw: nil,
            energyObservation: energy,
            streamGapCount: streamGapCount,
            streamGapSeconds: streamGapCount > 0 ? 3 : 0,
            providerErrorCount: providerErrorCount,
            droppedCount: droppedCount,
            confidence: confidence
        )
    }
}
