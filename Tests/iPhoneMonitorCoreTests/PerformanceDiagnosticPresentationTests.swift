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
            processDisplayNames: ["微信", "SpringBoard（系统界面）"]
        )

        XCTAssertTrue(presentation.overview.hasPrefix("卡顿附近存在数据中断或采集异常"))
        XCTAssertEqual(presentation.dataIntegrity, "不完整")
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("1 次数据中断"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("2 次数据源错误"))
        XCTAssertTrue(presentation.dataIntegrityDetail.contains("3 条队列丢弃"))
    }

    func testNeutralAndInsufficientLagSummariesStayMeasured() {
        let neutral = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(
                cpu: .noClearIncrease,
                freeMemoryTrend: .stable,
                compressorTrend: .stable,
                batteryTemperatureTrend: .stable,
                energy: .noClearChange
            ),
            processDisplayNames: ["微信", "SpringBoard（系统界面）", "相机"]
        )
        let insufficient = PerformanceDiagnosticPresenter.lagPresentation(
            summary: summary(),
            processDisplayNames: []
        )

        XCTAssertTrue(neutral.overview.contains("没有观察到单一、明确的同步变化"))
        XCTAssertEqual(neutral.processDisplayNames, ["微信", "SpringBoard（系统界面）"])
        XCTAssertEqual(neutral.dataIntegrity, "良好")
        XCTAssertTrue(insufficient.overview.hasPrefix("现有数据不足"))
        XCTAssertTrue(insufficient.phenomena.contains("用于比较的数据不足"))
        XCTAssertTrue(insufficient.processDisplayNames.isEmpty)
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
            processDisplayNames: ["微信", "SpringBoard（系统界面）"]
        )
        let allText = ([presentation.overview] + presentation.phenomena
            + presentation.processDisplayNames + [presentation.dataIntegrity, presentation.dataIntegrityDetail])
            .joined(separator: " ")

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

    private func summary(
        cpu: LagCPUObservation = .insufficientData,
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
            busiestProcesses: [],
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
