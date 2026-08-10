import Foundation

public enum PerformanceTrendDirection: String, Equatable, Sendable {
    case increasing
    case stable
    case decreasing
    case insufficientData
}

public enum LagCPUObservation: String, Equatable, Sendable {
    case high
    case similar
    case noClearIncrease
    case insufficientData
}

public enum LagEnergyObservation: String, Equatable, Sendable {
    case increased
    case noClearChange
    case insufficientData
}

public enum LagDataConfidence: String, Equatable, Sendable {
    case good
    case incomplete
}

public struct LagProcessObservation: Equatable, Sendable, Identifiable {
    public var id: String { identity }
    public let identity: String
    public let name: String
    public let pid: Int?
    public let cpuRaw: Double
}

public struct LagMemoryObservation: Equatable, Sendable {
    public let largestProcessIdentity: String?
    public let largestProcessName: String?
    public let largestProcessPID: Int?
    public let largestMiB: Double?
    public let fastestGrowthProcessIdentity: String?
    public let fastestGrowthProcessName: String?
    public let fastestGrowthProcessPID: Int?
    public let growthMiB: Double?
}

public struct PerformanceLagSummary: Equatable, Sendable, Identifiable {
    public var id: UInt64 { markerID }
    public let markerID: UInt64
    public let markerTimestamp: Date?
    public let note: String
    public let preWindowSeconds: Double
    public let postWindowSeconds: Double
    public let cpuObservation: LagCPUObservation
    public let busiestProcesses: [LagProcessObservation]
    public let appMemory: LagMemoryObservation
    public let freeMemoryTrend: PerformanceTrendDirection
    public let compressorTrend: PerformanceTrendDirection
    public let batteryTemperatureTrend: PerformanceTrendDirection
    public let batteryTemperatureStartRaw: Double?
    public let batteryTemperatureEndRaw: Double?
    public let energyObservation: LagEnergyObservation
    public let streamGapCount: Int
    public let streamGapSeconds: Double
    public let providerErrorCount: Int
    public let droppedCount: Int
    public let confidence: LagDataConfidence
}

public enum PerformanceInsightAnalyzer {
    public static func trend(
        points: [TimelinePoint],
        recentSeconds: Double? = nil,
        relativeThreshold: Double = 0.03
    ) -> PerformanceTrendDirection {
        let ordered = points.filter { $0.value.isFinite }.sorted { $0.monotonicNS < $1.monotonicNS }
        guard let latest = ordered.last else { return .insufficientData }
        let visible: [TimelinePoint]
        if let recentSeconds {
            visible = ordered.filter { latest.relativeSeconds - $0.relativeSeconds <= recentSeconds }
        } else {
            visible = ordered
        }
        guard visible.count >= 3 else { return .insufficientData }

        let groupSize = max(1, visible.count / 3)
        let first = median(visible.prefix(groupSize).map(\.value))
        let last = median(visible.suffix(groupSize).map(\.value))
        guard let first, let last else { return .insufficientData }
        let scale = max(abs(first), abs(last), 1)
        let threshold = scale * max(0, relativeThreshold)
        if last - first > threshold { return .increasing }
        if first - last > threshold { return .decreasing }
        return .stable
    }

    public static func lagSummary(
        input: PerformanceTimelineInput,
        marker: PerformanceUserMarker,
        providerErrorCount: Int,
        droppedCount: Int
    ) -> PerformanceLagSummary {
        let frame = PerformanceTimelineBuilder.build(
            input: input,
            range: .all,
            maxPointsPerSeries: 1_000,
            includeObserverProcesses: true
        )
        let markerNS = marker.monotonicNS ?? input.sessionStartMonotonicNS
        let markerSeconds = relativeSeconds(markerNS, start: input.sessionStartMonotonicNS)
        let allTimes = input.systemSamples.compactMap(\.monotonicNS)
            + input.processBatches.compactMap(\.monotonicNS)
            + input.batterySamples.compactMap(\.monotonicNS)
            + input.energySamples.compactMap(\.monotonicNS)
            + input.networkSummaries.compactMap(\.monotonicNS)
        let earliest = allTimes.min() ?? markerNS
        let latest = allTimes.max() ?? markerNS
        let preWindow = min(30, markerNS >= earliest ? Double(markerNS - earliest) / 1_000_000_000 : 0)
        let postWindow = min(10, latest >= markerNS ? Double(latest - markerNS) / 1_000_000_000 : 0)
        let lower = max(0, markerSeconds - 30)
        let upper = markerSeconds + 10

        let cpuSeries = frame.series(kind: .systemCPU).first
        let cpuObservation = assessCPU(
            points: cpuSeries?.points ?? [],
            markerSeconds: markerSeconds
        )
        let busiest = busiestProcesses(
            frame: frame,
            lower: markerSeconds - 3,
            upper: upper
        )
        let memory = memoryObservation(frame: frame, lower: lower, upper: upper, marker: markerSeconds)

        let freeMemory = frame.series(kind: .systemVM).first {
            $0.id.localizedCaseInsensitiveContains("vmfreecount")
        }
        let compressor = frame.series(kind: .systemVM).first {
            $0.id.localizedCaseInsensitiveContains("vmcompressorpagecount")
        }
        let freeTrend = trend(
            points: points(freeMemory, from: lower, through: upper),
            relativeThreshold: 0.01
        )
        let compressorTrend = trend(
            points: points(compressor, from: lower, through: upper),
            relativeThreshold: 0.01
        )

        let temperature = frame.series(kind: .batteryTemperature).first
        let temperaturePoints = points(temperature, from: lower, through: upper)
        let temperatureTrend = trend(points: temperaturePoints, relativeThreshold: 0.005)

        let energy = frame.series(kind: .energyCost).first ?? frame.series(kind: .energyCPUCost).first
        let energyObservation = assessEnergy(
            points: energy?.points ?? [],
            markerSeconds: markerSeconds
        )

        let gaps = input.gaps.filter { gap in
            guard gap.sessionID == nil || gap.sessionID == input.sessionID,
                  let monotonic = gap.monotonicNS
            else { return false }
            let seconds = relativeSeconds(monotonic, start: input.sessionStartMonotonicNS)
            return seconds >= lower && seconds <= upper
        }
        let gapSeconds = gaps.compactMap(\.observedGapMS).reduce(0, +) / 1_000
        let confidence: LagDataConfidence = gaps.isEmpty && providerErrorCount == 0 && droppedCount == 0
            ? .good : .incomplete

        return PerformanceLagSummary(
            markerID: marker.id,
            markerTimestamp: marker.timestamp,
            note: marker.note,
            preWindowSeconds: preWindow,
            postWindowSeconds: postWindow,
            cpuObservation: cpuObservation,
            busiestProcesses: busiest,
            appMemory: memory,
            freeMemoryTrend: freeTrend,
            compressorTrend: compressorTrend,
            batteryTemperatureTrend: temperatureTrend,
            batteryTemperatureStartRaw: temperaturePoints.first?.value,
            batteryTemperatureEndRaw: temperaturePoints.last?.value,
            energyObservation: energyObservation,
            streamGapCount: gaps.count,
            streamGapSeconds: gapSeconds,
            providerErrorCount: providerErrorCount,
            droppedCount: droppedCount,
            confidence: confidence
        )
    }

    private static func assessCPU(points: [TimelinePoint], markerSeconds: Double) -> LagCPUObservation {
        let historical = points.filter {
            $0.relativeSeconds >= max(0, markerSeconds - 120) && $0.relativeSeconds < markerSeconds - 5
        }
        let nearby = points.filter {
            $0.relativeSeconds >= markerSeconds - 5 && $0.relativeSeconds <= markerSeconds + 10
        }
        guard historical.count >= 3, !nearby.isEmpty,
              let baselineMedian = median(historical.map(\.value)),
              let nearbyMedian = median(nearby.map(\.value)),
              let nearbyPeak = nearby.map(\.value).max()
        else { return .insufficientData }

        let p90 = percentile(historical.map(\.value), percentile: 0.90) ?? baselineMedian
        let tolerance = max(max(abs(baselineMedian), abs(p90)) * 0.03, 0.000_001)
        if nearbyPeak > p90 + tolerance { return .high }
        if nearbyMedian <= baselineMedian + tolerance { return .noClearIncrease }
        return .similar
    }

    private static func busiestProcesses(
        frame: PerformanceTimelineFrame,
        lower: Double,
        upper: Double
    ) -> [LagProcessObservation] {
        frame.series(kind: .processCPU)
            .filter { !$0.observerOverhead }
            .compactMap { series -> LagProcessObservation? in
                guard let peak = points(series, from: lower, through: upper).map(\.value).max(),
                      let identity = series.processIdentity,
                      let name = series.processName
                else { return nil }
                return LagProcessObservation(
                    identity: identity,
                    name: name,
                    pid: series.pid,
                    cpuRaw: peak
                )
            }
            .sorted {
                if $0.cpuRaw == $1.cpuRaw { return $0.identity < $1.identity }
                return $0.cpuRaw > $1.cpuRaw
            }
            .prefix(3)
            .map { $0 }
    }

    private static func memoryObservation(
        frame: PerformanceTimelineFrame,
        lower: Double,
        upper: Double,
        marker: Double
    ) -> LagMemoryObservation {
        let series = frame.series(kind: .processMemory).filter { !$0.observerOverhead }
        let largest = series.compactMap { item -> (TimelineSeries, TimelinePoint)? in
            let nearby = points(item, from: marker - 5, through: upper)
            guard let closest = nearby.min(by: {
                abs($0.relativeSeconds - marker) < abs($1.relativeSeconds - marker)
            }) else { return nil }
            return (item, closest)
        }.max { $0.1.value < $1.1.value }

        let growth = series.compactMap { item -> (TimelineSeries, Double)? in
            let visible = points(item, from: lower, through: upper)
            guard let first = visible.first, let last = visible.last else { return nil }
            return (item, last.value - first.value)
        }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }

        return LagMemoryObservation(
            largestProcessIdentity: largest?.0.processIdentity,
            largestProcessName: largest?.0.processName,
            largestProcessPID: largest?.0.pid,
            largestMiB: largest?.1.value,
            fastestGrowthProcessIdentity: growth?.0.processIdentity,
            fastestGrowthProcessName: growth?.0.processName,
            fastestGrowthProcessPID: growth?.0.pid,
            growthMiB: growth?.1
        )
    }

    private static func assessEnergy(points: [TimelinePoint], markerSeconds: Double) -> LagEnergyObservation {
        let before = points.filter {
            $0.relativeSeconds >= max(0, markerSeconds - 30) && $0.relativeSeconds < markerSeconds
        }
        let after = points.filter {
            $0.relativeSeconds >= markerSeconds && $0.relativeSeconds <= markerSeconds + 10
        }
        guard before.count >= 2, !after.isEmpty,
              let beforeMedian = median(before.map(\.value)),
              let afterMedian = median(after.map(\.value))
        else { return .insufficientData }
        let tolerance = max(abs(beforeMedian) * 0.10, 0.000_001)
        return afterMedian > beforeMedian + tolerance ? .increased : .noClearChange
    }

    private static func points(
        _ series: TimelineSeries?,
        from lower: Double,
        through upper: Double
    ) -> [TimelinePoint] {
        (series?.points ?? [])
            .filter { $0.relativeSeconds >= lower && $0.relativeSeconds <= upper }
            .sorted { $0.monotonicNS < $1.monotonicNS }
    }

    private static func relativeSeconds(_ monotonic: UInt64, start: UInt64) -> Double {
        monotonic >= start ? Double(monotonic - start) / 1_000_000_000 : 0
    }

    private static func median<S: Sequence>(_ values: S) -> Double? where S.Element == Double {
        let ordered = values.filter(\.isFinite).sorted()
        guard !ordered.isEmpty else { return nil }
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double? {
        let ordered = values.filter(\.isFinite).sorted()
        guard !ordered.isEmpty else { return nil }
        let index = Int((Double(ordered.count - 1) * min(1, max(0, percentile))).rounded(.up))
        return ordered[index]
    }
}
