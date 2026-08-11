import Foundation

public enum PerformanceTimelineRange: String, CaseIterable, Identifiable, Sendable {
    case seconds30
    case minute1
    case minutes3
    case all

    public var id: String { rawValue }

    public var seconds: TimeInterval? {
        switch self {
        case .seconds30: return 30
        case .minute1: return 60
        case .minutes3: return 180
        case .all: return nil
        }
    }

    public var title: String {
        switch self {
        case .seconds30: return "最近 30 秒"
        case .minute1: return "最近 1 分钟"
        case .minutes3: return "最近 3 分钟"
        case .all: return "全部会话"
        }
    }
}

public enum TimelineSeriesKind: String, Sendable {
    case systemCPU
    case systemVM
    case processCPU
    case processMemory
    case batteryTemperature
    case batteryVoltage
    case batteryCurrent
    case energyCost
    case energyCPUCost
    case networkReceive
    case networkTransmit
}

public struct TimelinePoint: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let seriesID: String
    public let timestamp: Date?
    public let monotonicNS: UInt64
    public let relativeSeconds: Double
    public let value: Double

    public init(
        id: String,
        sessionID: String,
        seriesID: String,
        timestamp: Date?,
        monotonicNS: UInt64,
        relativeSeconds: Double,
        value: Double
    ) {
        self.id = id
        self.sessionID = sessionID
        self.seriesID = seriesID
        self.timestamp = timestamp
        self.monotonicNS = monotonicNS
        self.relativeSeconds = relativeSeconds
        self.value = value
    }
}

public struct TimelineSegment: Equatable, Identifiable, Sendable {
    public let id: String
    public let points: [TimelinePoint]

    public init(id: String, points: [TimelinePoint]) {
        self.id = id
        self.points = points
    }
}

public struct TimelineSeries: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let provider: String
    public let unitLabel: String
    public let kind: TimelineSeriesKind
    public let segments: [TimelineSegment]
    public let processIdentity: String?
    public let processName: String?
    public let pid: Int?
    public let observerOverhead: Bool

    public init(
        id: String,
        title: String,
        detail: String,
        provider: String,
        unitLabel: String,
        kind: TimelineSeriesKind,
        segments: [TimelineSegment],
        processIdentity: String? = nil,
        processName: String? = nil,
        pid: Int? = nil,
        observerOverhead: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.provider = provider
        self.unitLabel = unitLabel
        self.kind = kind
        self.segments = segments
        self.processIdentity = processIdentity
        self.processName = processName
        self.pid = pid
        self.observerOverhead = observerOverhead
    }

    public var points: [TimelinePoint] { segments.flatMap(\.points) }
    public var peak: Double? {
        segments.lazy.flatMap(\.points).reduce(nil as Double?) { current, point in
            max(current ?? -.infinity, point.value)
        }
    }

    public var isEmpty: Bool { segments.allSatisfy { $0.points.isEmpty } }
}

public enum TimelineEventKind: String, Sendable {
    case sessionStarted
    case sessionEnded
    case streamGap
    case userMarker
}

public struct TimelineEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let kind: TimelineEventKind
    public let timestamp: Date?
    public let monotonicNS: UInt64
    public let relativeSeconds: Double
    public let title: String
    public let detail: String
    public let provider: String?

    public init(
        id: String,
        sessionID: String,
        kind: TimelineEventKind,
        timestamp: Date?,
        monotonicNS: UInt64,
        relativeSeconds: Double,
        title: String,
        detail: String,
        provider: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.timestamp = timestamp
        self.monotonicNS = monotonicNS
        self.relativeSeconds = relativeSeconds
        self.title = title
        self.detail = detail
        self.provider = provider
    }
}

public struct PerformanceTimelineInput: Sendable {
    public let sessionID: String
    public let sessionStartMonotonicNS: UInt64
    public let sessionStartTimestamp: Date?
    public let sessionEndMonotonicNS: UInt64?
    public let systemSamples: [SystemPerformanceSample]
    public let processBatches: [ProcessPerformanceBatch]
    public let batterySamples: [BatteryTelemetrySample]
    public let energySamples: [EnergySample]
    public let networkSummaries: [NetworkSummary]
    public let gaps: [PerformanceStreamGap]
    public let markers: [PerformanceUserMarker]

    public init(
        sessionID: String,
        sessionStartMonotonicNS: UInt64,
        sessionStartTimestamp: Date?,
        sessionEndMonotonicNS: UInt64? = nil,
        systemSamples: [SystemPerformanceSample],
        processBatches: [ProcessPerformanceBatch],
        batterySamples: [BatteryTelemetrySample],
        energySamples: [EnergySample],
        networkSummaries: [NetworkSummary],
        gaps: [PerformanceStreamGap],
        markers: [PerformanceUserMarker]
    ) {
        self.sessionID = sessionID
        self.sessionStartMonotonicNS = sessionStartMonotonicNS
        self.sessionStartTimestamp = sessionStartTimestamp
        self.sessionEndMonotonicNS = sessionEndMonotonicNS
        self.systemSamples = systemSamples
        self.processBatches = processBatches
        self.batterySamples = batterySamples
        self.energySamples = energySamples
        self.networkSummaries = networkSummaries
        self.gaps = gaps
        self.markers = markers
    }
}

public struct PerformanceTimelineFrame: Equatable, Sendable {
    public static let empty = PerformanceTimelineFrame(
        sessionID: nil,
        range: .minute1,
        visibleLowerBound: 0,
        visibleUpperBound: 0,
        series: [],
        events: [],
        recommendedProcessIdentities: [],
        rawPointCount: 0,
        plottedPointCount: 0
    )

    public let sessionID: String?
    public let range: PerformanceTimelineRange
    public let visibleLowerBound: Double
    public let visibleUpperBound: Double
    public let series: [TimelineSeries]
    public let events: [TimelineEvent]
    public let recommendedProcessIdentities: [String]
    public let rawPointCount: Int
    public let plottedPointCount: Int

    public init(
        sessionID: String?,
        range: PerformanceTimelineRange,
        visibleLowerBound: Double,
        visibleUpperBound: Double,
        series: [TimelineSeries],
        events: [TimelineEvent],
        recommendedProcessIdentities: [String],
        rawPointCount: Int,
        plottedPointCount: Int
    ) {
        self.sessionID = sessionID
        self.range = range
        self.visibleLowerBound = visibleLowerBound
        self.visibleUpperBound = visibleUpperBound
        self.series = series
        self.events = events
        self.recommendedProcessIdentities = recommendedProcessIdentities
        self.rawPointCount = rawPointCount
        self.plottedPointCount = plottedPointCount
    }

    public func series(kind: TimelineSeriesKind) -> [TimelineSeries] {
        series.filter { $0.kind == kind }
    }
}

public enum TimelineDownsampler {
    public static func downsample(_ source: [TimelinePoint], maxPoints: Int) -> [TimelinePoint] {
        let ordered = source
            .filter { $0.value.isFinite }
            .enumerated()
            .sorted {
                if $0.element.monotonicNS == $1.element.monotonicNS { return $0.offset < $1.offset }
                return $0.element.monotonicNS < $1.element.monotonicNS
            }
            .map(\.element)
        guard maxPoints > 1, ordered.count > maxPoints else { return ordered }

        let interior = Array(ordered.dropFirst().dropLast())
        let budget = max(1, maxPoints - 2)
        let bucketCount = max(1, budget / 4)
        let bucketSize = max(1, Int(ceil(Double(interior.count) / Double(bucketCount))))
        var result: [TimelinePoint] = [ordered[0]]

        for start in stride(from: 0, to: interior.count, by: bucketSize) {
            let end = min(interior.count, start + bucketSize)
            let bucket = Array(interior[start..<end])
            guard !bucket.isEmpty else { continue }
            let candidates = [
                bucket.first,
                bucket.min { $0.value < $1.value },
                bucket.max { $0.value < $1.value },
                bucket.last
            ].compactMap { $0 }
            let unique = Dictionary(grouping: candidates, by: \.id).compactMap { $0.value.first }
            result.append(contentsOf: unique.sorted { $0.monotonicNS < $1.monotonicNS })
        }
        result.append(ordered[ordered.count - 1])

        if result.count <= maxPoints { return result }
        let removable = result.dropFirst().dropLast()
        let globalMin = removable.min { $0.value < $1.value }
        let globalMax = removable.max { $0.value < $1.value }
        var mustKeep = Set([ordered.first!.id, ordered.last!.id])
        if let globalMin { mustKeep.insert(globalMin.id) }
        if let globalMax { mustKeep.insert(globalMax.id) }
        let optional = result.filter { !mustKeep.contains($0.id) }
        let optionalBudget = max(0, maxPoints - mustKeep.count)
        let strideSize = max(1, Int(ceil(Double(optional.count) / Double(max(1, optionalBudget)))))
        let selectedOptional = optional.enumerated().compactMap { index, point in
            index.isMultiple(of: strideSize) ? point : nil
        }.prefix(optionalBudget)
        return (result.filter { mustKeep.contains($0.id) } + selectedOptional)
            .sorted { $0.monotonicNS < $1.monotonicNS }
    }

    public static func segments(
        points: [TimelinePoint],
        gaps: [PerformanceStreamGap],
        provider: String,
        seriesID: String
    ) -> [TimelineSegment] {
        let ordered = points.sorted { $0.monotonicNS < $1.monotonicNS }
        guard !ordered.isEmpty else { return [] }
        let relevantGapTimes = gaps.compactMap { gap -> UInt64? in
            guard gap.sessionID == nil || gap.sessionID == ordered[0].sessionID,
                  Self.gap(gap, appliesTo: provider)
            else { return nil }
            return gap.monotonicNS
        }.sorted()

        var chunks: [[TimelinePoint]] = [[ordered[0]]]
        for point in ordered.dropFirst() {
            let previous = chunks[chunks.count - 1].last!
            let crossesGap = relevantGapTimes.contains { $0 > previous.monotonicNS && $0 <= point.monotonicNS }
            if crossesGap {
                chunks.append([point])
            } else {
                chunks[chunks.count - 1].append(point)
            }
        }
        return chunks.enumerated().map { index, chunk in
            TimelineSegment(id: "\(seriesID)-segment-\(index)", points: chunk)
        }
    }

    private static func gap(_ gap: PerformanceStreamGap, appliesTo provider: String) -> Bool {
        let providerValue = gap.provider.lowercased()
        let streamValue = gap.stream.lowercased()
        let target = provider.lowercased()
        if providerValue == target || streamValue.contains(target) { return true }
        switch target {
        case "sysmon": return streamValue == "system_sample" || streamValue == "process_batch"
        case "battery": return streamValue == "battery_sample"
        case "energy": return streamValue == "energy_sample"
        case "network": return streamValue == "network_summary"
        default: return false
        }
    }
}

public enum PerformanceTimelineBuilder {
    private struct ProcessIdentityState {
        var token: String
        var generation: Int
    }

    private struct ProcessAccumulator {
        let identity: String
        let name: String
        let pid: Int
        let observerOverhead: Bool
        var cpu: [TimelinePoint]
        var memory: [TimelinePoint]
    }

    private struct ProcessCandidate {
        let identity: String
        let name: String
        let pid: Int
        let observerOverhead: Bool
        var peakCPU: Double
        var peakMemoryMiB: Double
    }

    public static func build(
        input: PerformanceTimelineInput,
        range: PerformanceTimelineRange,
        maxPointsPerSeries: Int = 420,
        processQuery: String = "",
        includeObserverProcesses: Bool = false
    ) -> PerformanceTimelineFrame {
        let allMonotonic = input.systemSamples.compactMap(\.monotonicNS)
            + input.processBatches.compactMap(\.monotonicNS)
            + input.batterySamples.compactMap(\.monotonicNS)
            + input.energySamples.compactMap(\.monotonicNS)
            + input.networkSummaries.compactMap(\.monotonicNS)
            + input.markers.compactMap(\.monotonicNS)
            + [input.sessionEndMonotonicNS].compactMap { $0 }
        let upperNS = allMonotonic.max() ?? input.sessionStartMonotonicNS
        let lowerNS: UInt64
        if let seconds = range.seconds {
            let width = UInt64(seconds * 1_000_000_000)
            lowerNS = upperNS > width ? upperNS - width : input.sessionStartMonotonicNS
        } else {
            lowerNS = input.sessionStartMonotonicNS
        }

        func belongs(_ sessionID: String?) -> Bool { sessionID == input.sessionID }
        func visible(_ monotonic: UInt64?) -> Bool {
            guard let monotonic else { return false }
            return monotonic >= lowerNS && monotonic <= upperNS
        }
        func relative(_ monotonic: UInt64) -> Double {
            guard monotonic >= input.sessionStartMonotonicNS else { return 0 }
            return Double(monotonic - input.sessionStartMonotonicNS) / 1_000_000_000
        }
        func point(
            seriesID: String,
            sequence: UInt64,
            sessionID: String?,
            timestamp: Date?,
            monotonic: UInt64?,
            value: Double?
        ) -> TimelinePoint? {
            guard belongs(sessionID), let monotonic, visible(monotonic), let value, value.isFinite else { return nil }
            return TimelinePoint(
                id: "\(seriesID)-\(monotonic)-\(sequence)",
                sessionID: input.sessionID,
                seriesID: seriesID,
                timestamp: timestamp,
                monotonicNS: monotonic,
                relativeSeconds: relative(monotonic),
                value: value
            )
        }

        let visibleGaps = input.gaps.filter { belongs($0.sessionID) && visible($0.monotonicNS) }
        var rawSeries: [TimelineSeries] = []
        var rawPointCount = 0

        func appendSeries(
            id: String,
            title: String,
            detail: String,
            provider: String,
            unit: String,
            kind: TimelineSeriesKind,
            points: [TimelinePoint],
            processIdentity: String? = nil,
            processName: String? = nil,
            pid: Int? = nil,
            observer: Bool = false
        ) {
            guard !points.isEmpty else { return }
            rawPointCount += points.count
            let sampled = TimelineDownsampler.downsample(points, maxPoints: maxPointsPerSeries)
            let segments = TimelineDownsampler.segments(
                points: sampled,
                gaps: visibleGaps,
                provider: provider,
                seriesID: id
            )
            rawSeries.append(
                TimelineSeries(
                    id: id,
                    title: title,
                    detail: detail,
                    provider: provider,
                    unitLabel: unit,
                    kind: kind,
                    segments: segments,
                    processIdentity: processIdentity,
                    processName: processName,
                    pid: pid,
                    observerOverhead: observer
                )
            )
        }

        let cpuID = "system.cpu.total"
        appendSeries(
            id: cpuID,
            title: "手机整体处理器负载",
            detail: "数值越高表示手机处理器整体越忙，不能直接理解为 CPU 百分比",
            provider: "sysmon",
            unit: "负载原始值",
            kind: .systemCPU,
            points: input.systemSamples.compactMap { sample in
                point(
                    seriesID: cpuID,
                    sequence: sample.id,
                    sessionID: sample.sessionID,
                    timestamp: sample.timestamp,
                    monotonic: sample.monotonicNS,
                    value: sample.metric("CPU_TotalLoad")?.value?.doubleValue
                )
            }
        )

        let availableVMKeys = Set(input.systemSamples.flatMap { sample in
            sample.metrics.keys.filter { $0.localizedCaseInsensitiveContains("vm") }
        })
        let preferredVMKeys = ["vmFreeCount", "vmCompressorPageCount", "vmUsedCount"]
        var vmKeys = preferredVMKeys.compactMap { preferred in
            availableVMKeys.first { $0.caseInsensitiveCompare(preferred) == .orderedSame }
        }
        vmKeys.append(contentsOf: availableVMKeys.sorted().filter { !vmKeys.contains($0) })
        for key in vmKeys {
            let seriesID = "system.vm.\(key)"
            appendSeries(
                id: seriesID,
                title: vmDisplayTitle(key),
                detail: "系统内存页数的原始计数，目前不换算为 GB",
                provider: "sysmon",
                unit: "内存页数（原始计数）",
                kind: .systemVM,
                points: input.systemSamples.compactMap { sample in
                    point(
                        seriesID: seriesID,
                        sequence: sample.id,
                        sessionID: sample.sessionID,
                        timestamp: sample.timestamp,
                        monotonic: sample.monotonicNS,
                        value: sample.metric(key)?.value?.doubleValue
                    )
                }
            )
        }

        let batches = input.processBatches
            .filter { belongs($0.sessionID) && visible($0.monotonicNS) }
            .sorted { ($0.monotonicNS ?? 0) < ($1.monotonicNS ?? 0) }

        func identity(
            for process: ProcessPerformanceSample,
            state: inout [Int: ProcessIdentityState]
        ) -> String {
            let startToken = ["startAbsTime", "startTime", "start_time", "procStartTime", "processStartTime"]
                .compactMap { process.metric($0)?.value?.displayString }
                .first
            let token = "\(process.name)|\(startToken ?? "unknown-start")"
            var current = state[process.pid] ?? ProcessIdentityState(token: token, generation: 0)
            if current.token != token {
                current = ProcessIdentityState(token: token, generation: current.generation + 1)
            }
            state[process.pid] = current
            return "\(process.pid):\(process.name):\(current.generation)"
        }

        // First pass records only compact process metadata and peaks. The raw
        // process batches stay in the Store; chart frames do not retain every
        // process history merely to draw the default five lines.
        var candidateState: [Int: ProcessIdentityState] = [:]
        var candidates: [String: ProcessCandidate] = [:]
        for batch in batches {
            for process in batch.processes {
                let processIdentity = identity(for: process, state: &candidateState)
                var candidate = candidates[processIdentity] ?? ProcessCandidate(
                    identity: processIdentity,
                    name: process.name,
                    pid: process.pid,
                    observerOverhead: process.observerOverhead,
                    peakCPU: -.infinity,
                    peakMemoryMiB: -.infinity
                )
                if let cpu = process.cpuRaw, cpu.isFinite {
                    candidate.peakCPU = max(candidate.peakCPU, cpu)
                }
                if let memory = process.physicalMemoryMiB, memory.isFinite {
                    candidate.peakMemoryMiB = max(candidate.peakMemoryMiB, memory)
                }
                candidates[processIdentity] = candidate
            }
        }

        let ranked = candidates.values.sorted {
            if $0.peakCPU == $1.peakCPU { return $0.identity < $1.identity }
            return $0.peakCPU > $1.peakCPU
        }
        var selectedIdentities = Set(ranked
            .filter { !$0.observerOverhead }
            .prefix(5)
            .map(\.identity))
        selectedIdentities.formUnion(candidates.values
            .filter { !$0.observerOverhead }
            .sorted {
                if $0.peakMemoryMiB == $1.peakMemoryMiB { return $0.identity < $1.identity }
                return $0.peakMemoryMiB > $1.peakMemoryMiB
            }
            .prefix(5)
            .map(\.identity))
        for candidate in ranked where ["SpringBoard", "backboardd"].contains(where: {
            candidate.name.caseInsensitiveCompare($0) == .orderedSame
        }) {
            selectedIdentities.insert(candidate.identity)
        }
        // Keep observer evidence available for a separate disclosure without
        // allowing it into the default high-load ranking.
        selectedIdentities.formUnion(ranked.filter(\.observerOverhead).prefix(5).map(\.identity))
        let normalizedQuery = processQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedQuery.isEmpty {
            selectedIdentities.formUnion(ranked.filter {
                $0.name.localizedCaseInsensitiveContains(normalizedQuery)
                    || String($0.pid).contains(normalizedQuery)
            }.prefix(5).map(\.identity))
        }

        var identityState: [Int: ProcessIdentityState] = [:]
        var processAccumulators: [String: ProcessAccumulator] = [:]
        for batch in batches {
            guard let monotonic = batch.monotonicNS else { continue }
            for process in batch.processes {
                let processIdentity = identity(for: process, state: &identityState)
                guard selectedIdentities.contains(processIdentity) else { continue }
                var accumulator = processAccumulators[processIdentity] ?? ProcessAccumulator(
                    identity: processIdentity,
                    name: process.name,
                    pid: process.pid,
                    observerOverhead: process.observerOverhead,
                    cpu: [],
                    memory: []
                )
                if let cpu = point(
                    seriesID: "process.cpu.\(processIdentity)",
                    sequence: batch.id,
                    sessionID: batch.sessionID,
                    timestamp: batch.timestamp,
                    monotonic: monotonic,
                    value: process.cpuRaw
                ) { accumulator.cpu.append(cpu) }
                if let memory = point(
                    seriesID: "process.memory.\(processIdentity)",
                    sequence: batch.id,
                    sessionID: batch.sessionID,
                    timestamp: batch.timestamp,
                    monotonic: monotonic,
                    value: process.physicalMemoryMiB
                ) { accumulator.memory.append(memory) }
                processAccumulators[processIdentity] = accumulator
            }
        }
        for accumulator in processAccumulators.values.sorted(by: { $0.identity < $1.identity }) {
            appendSeries(
                id: "process.cpu.\(accumulator.identity)",
                title: "\(accumulator.name) (PID \(accumulator.pid))",
                detail: accumulator.observerOverhead ? "监控工具自身开销 · 处理器负载原始值" : "应用或系统进程的处理器负载原始值",
                provider: "sysmon",
                unit: "处理器负载",
                kind: .processCPU,
                points: accumulator.cpu,
                processIdentity: accumulator.identity,
                processName: accumulator.name,
                pid: accumulator.pid,
                observer: accumulator.observerOverhead
            )
            appendSeries(
                id: "process.memory.\(accumulator.identity)",
                title: "\(accumulator.name) (PID \(accumulator.pid))",
                detail: accumulator.observerOverhead ? "监控工具自身开销 · 应用内存" : "应用物理内存占用",
                provider: "sysmon",
                unit: "MiB",
                kind: .processMemory,
                points: accumulator.memory,
                processIdentity: accumulator.identity,
                processName: accumulator.name,
                pid: accumulator.pid,
                observer: accumulator.observerOverhead
            )
        }

        let batteryFields: [(String, String, TimelineSeriesKind, String)] = [
            ("Temperature", "电池温度", .batteryTemperature, "电池温度原始值，不是 CPU 或 SoC 温度"),
            ("Voltage", "电池电压", .batteryVoltage, "电压原始值，单位未确认"),
            ("InstantAmperage", "电池电流", .batteryCurrent, "电流原始值，单位与符号未确认")
        ]
        for (field, title, kind, detail) in batteryFields {
            let seriesID = "battery.\(field)"
            appendSeries(
                id: seriesID,
                title: title,
                detail: detail,
                provider: "battery",
                unit: "原始值",
                kind: kind,
                points: input.batterySamples.compactMap { sample in
                    point(
                        seriesID: seriesID,
                        sequence: sample.id,
                        sessionID: sample.sessionID,
                        timestamp: sample.timestamp,
                        monotonic: sample.monotonicNS,
                        value: sample.metric(field)?.value?.doubleValue
                    )
                }
            )
        }

        let energyKeys = Set(input.energySamples.flatMap(\.metrics.keys))
        let cpuCostKey = energyKeys.sorted().first {
            $0.localizedCaseInsensitiveContains("cpu") && $0.localizedCaseInsensitiveContains("cost")
        }
        let distinctTotalCostKey = energyKeys.sorted().first {
            $0.localizedCaseInsensitiveContains("cost") && $0 != cpuCostKey
        }
        let totalCostKey = distinctTotalCostKey
            ?? (cpuCostKey == nil ? energyKeys.sorted().first { $0.localizedCaseInsensitiveContains("cost") } : nil)
        for (key, kind) in [(totalCostKey, TimelineSeriesKind.energyCost), (cpuCostKey, .energyCPUCost)] {
            guard let key else { continue }
            let seriesID = "energy.\(kind.rawValue).\(key)"
            appendSeries(
                id: seriesID,
                title: kind == .energyCPUCost ? "处理器能耗" : "整体能耗",
                detail: "DVT 内部评分，不是瓦特或焦耳",
                provider: "energy",
                unit: "能耗评分",
                kind: kind,
                points: input.energySamples.compactMap { sample in
                    point(
                        seriesID: seriesID,
                        sequence: sample.id,
                        sessionID: sample.sessionID,
                        timestamp: sample.timestamp,
                        monotonic: sample.monotonicNS,
                        value: sample.metrics[key]?.value?.doubleValue
                    )
                }
            )
        }

        let networkFields: [(String, TimelineSeriesKind, (NetworkSummary) -> Int?)] = [
            ("下载", .networkReceive, { $0.receivedBytesDelta }),
            ("上传", .networkTransmit, { $0.transmittedBytesDelta })
        ]
        let orderedNetwork = input.networkSummaries
            .filter { belongs($0.sessionID) }
            .sorted { ($0.monotonicNS ?? 0) < ($1.monotonicNS ?? 0) }
        for (title, kind, value) in networkFields {
            let seriesID = "network.\(kind.rawValue)"
            var previousMonotonicNS: UInt64?
            var ratePoints: [TimelinePoint] = []
            for summary in orderedNetwork {
                defer { previousMonotonicNS = summary.monotonicNS }
                guard let monotonic = summary.monotonicNS,
                      let previousMonotonicNS,
                      monotonic > previousMonotonicNS,
                      let byteDelta = value(summary),
                      byteDelta >= 0
                else { continue }
                let elapsedSeconds = Double(monotonic - previousMonotonicNS) / 1_000_000_000
                guard elapsedSeconds > 0 else { continue }
                if let ratePoint = point(
                    seriesID: seriesID,
                    sequence: summary.id,
                    sessionID: summary.sessionID,
                    timestamp: summary.timestamp,
                    monotonic: monotonic,
                    value: Double(byteDelta) / elapsedSeconds
                ) {
                    ratePoints.append(ratePoint)
                }
            }
            appendSeries(
                id: seriesID,
                title: title,
                detail: "按相邻真实采样时间计算的平均速度，不含地址、域名或载荷",
                provider: "network",
                unit: "bytes/s",
                kind: kind,
                points: ratePoints
            )
        }

        var events: [TimelineEvent] = [
            TimelineEvent(
                id: "session-start-\(input.sessionID)",
                sessionID: input.sessionID,
                kind: .sessionStarted,
                timestamp: input.sessionStartTimestamp,
                monotonicNS: input.sessionStartMonotonicNS,
                relativeSeconds: 0,
                title: "会话开始",
                detail: "相对时间 0 秒"
            )
        ]
        events += visibleGaps.compactMap { gap in
            guard let monotonic = gap.monotonicNS else { return nil }
            return TimelineEvent(
                id: "gap-\(gap.id)",
                sessionID: input.sessionID,
                kind: .streamGap,
                timestamp: gap.timestamp,
                monotonicNS: monotonic,
                relativeSeconds: relative(monotonic),
                title: "数据中断",
                detail: gap.observedGapMS.map {
                    "\(providerDisplayTitle(gap.provider))数据中断约 \(String(format: "%.1f", $0 / 1_000)) 秒"
                } ?? "\(providerDisplayTitle(gap.provider))数据中断，时长未知",
                provider: gap.provider
            )
        }
        events += input.markers.compactMap { marker in
            guard belongs(marker.sessionID), let monotonic = marker.monotonicNS, visible(monotonic) else { return nil }
            return TimelineEvent(
                id: "marker-\(marker.id)",
                sessionID: input.sessionID,
                kind: .userMarker,
                timestamp: marker.timestamp,
                monotonicNS: monotonic,
                relativeSeconds: relative(monotonic),
                title: "卡顿标记",
                detail: marker.note.isEmpty ? "无备注" : marker.note
            )
        }
        if let end = input.sessionEndMonotonicNS, visible(end) {
            events.append(
                TimelineEvent(
                    id: "session-end-\(input.sessionID)",
                    sessionID: input.sessionID,
                    kind: .sessionEnded,
                    timestamp: nil,
                    monotonicNS: end,
                    relativeSeconds: relative(end),
                    title: "会话结束",
                    detail: "最终数据已保留"
                )
            )
        }
        events.sort { $0.monotonicNS < $1.monotonicNS }

        let cpuProcesses = rawSeries.filter { $0.kind == .processCPU }
        var recommended: [String] = []
        for preferred in ["SpringBoard", "backboardd"] {
            if let identity = cpuProcesses.first(where: {
                $0.processName?.caseInsensitiveCompare(preferred) == .orderedSame
            })?.processIdentity {
                recommended.append(identity)
            }
        }
        let highest = cpuProcesses
            .filter { !$0.observerOverhead }
            .sorted { ($0.peak ?? -.infinity) > ($1.peak ?? -.infinity) }
            .compactMap(\.processIdentity)
        for identity in highest where !recommended.contains(identity) && recommended.count < 5 {
            recommended.append(identity)
        }

        let plottedPointCount = rawSeries.reduce(0) { $0 + $1.points.count }
        return PerformanceTimelineFrame(
            sessionID: input.sessionID,
            range: range,
            visibleLowerBound: relative(lowerNS),
            visibleUpperBound: relative(upperNS),
            series: rawSeries,
            events: events,
            recommendedProcessIdentities: recommended,
            rawPointCount: rawPointCount,
            plottedPointCount: plottedPointCount
        )
    }

    private static func vmDisplayTitle(_ rawField: String) -> String {
        switch rawField.lowercased() {
        case "vmusedcount": return "已使用页数"
        case "vmfreecount": return "空闲页数"
        case "vmcompressorpagecount": return "压缩内存页数"
        default: return rawField
        }
    }

    private static func providerDisplayTitle(_ provider: String) -> String {
        switch provider.lowercased() {
        case "sysmon", "system", "process": return "处理器"
        case "battery": return "电池"
        case "energy": return "能耗"
        case "network": return "网络"
        case "oslog": return "系统日志"
        default: return "性能"
        }
    }
}
