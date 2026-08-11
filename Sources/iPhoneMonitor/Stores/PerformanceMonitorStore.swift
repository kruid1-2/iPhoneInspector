import Combine
import Foundation
import iPhoneMonitorCore

@MainActor
final class PerformanceMonitorStore: ObservableObject {
    enum Limits {
        static let systemSamples = 600
        static let batterySamples = 300
        static let energySamples = 600
        static let networkSummaries = 300
        static let processBatches = 180
        static let logEvents = 750
        static let sessionEvents = 2_000
        static let diagnostics = 100
    }

    @Published private(set) var state: PerformanceSessionState = .idle
    @Published private(set) var helperPID: Int32?
    @Published private(set) var helperSource: PerformanceHelperLocation.Source?
    private(set) var capability: PerformanceCapability?
    private(set) var lastUpdate: Date?
    private(set) var sessionStartedAt: Date?
    @Published private(set) var sessionElapsed: TimeInterval = 0
    private(set) var lastMarkerAt: Date?
    private(set) var latestSystem: SystemPerformanceSample?
    private(set) var latestBattery: BatteryTelemetrySample?
    private(set) var latestBatteryReceivedAt: Date?
    private(set) var latestEnergy: EnergySample?
    private(set) var latestNetwork: NetworkSummary?
    private(set) var latestProcesses: [ProcessPerformanceSample] = []
    private(set) var logs: [PerformanceLogEvent] = []
    private(set) var latestLogSummary: PerformanceLogSummary?
    private(set) var streamGaps: [PerformanceStreamGap] = []
    private(set) var providerErrors: [PerformanceProviderError] = []
    private(set) var userMarkers: [PerformanceUserMarker] = []
    private(set) var providerStates: [String: String] = [:]
    private(set) var outputQueue = PerformanceOutputQueueStats(object: [:])
    @Published private(set) var compatibilityWarnings: [String] = []
    @Published private(set) var helperDiagnostics: [String] = []
    @Published private(set) var lastError: String?
    @Published private(set) var operationInFlight = false
    @Published private(set) var transportDescription = "尚未建立性能监控连接"
    @Published var oslogEnabled = false
    @Published private(set) var timelineFrame = PerformanceTimelineFrame.empty
    @Published private(set) var timelineRange: PerformanceTimelineRange = .minute1
    @Published private(set) var latestLagSummary: PerformanceLagSummary?
    @Published private(set) var lagSummaryPending = false
    private(set) var timelineRevision: UInt64 = 0

    private let service: PerformanceMonitorService
    private var eventTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var lifecycleShutdownTask: Task<Void, Never>?
    private var timelineBuildTask: Task<Void, Never>?
    private var lagSummaryTask: Task<Void, Never>?
    private var pendingMessages: [PerformanceMessage] = []
    private var timelineVisible = false
    private var diagnosisVisible = false
    private var timelineBuildGeneration: UInt64 = 0
    private var timelineDirty = false
    private var activeTimelineSessionID: String?
    private var sessionStartMonotonicNS: UInt64?
    private var sessionEndMonotonicNS: UInt64?
    private var receivedMessageCount = 0
    private var storeBatchPublishCount = 0
    private var timelineFramePublishCount = 0
    private var lastTimelineBuildStartedAt: Date?
    private var timelineProcessQuery = ""
    private var timelineIncludeObserverProcesses = false

    // Charts are a derived presentation cache. Raw Helper messages continue at
    // their configured rate; rebuilding the visible native Charts every four
    // seconds keeps this Intel Mac responsive without fabricating or dropping
    // source samples.
    private let timelineRefreshInterval: TimeInterval = 4

    private var systemBuffer = BoundedPerformanceBuffer<SystemPerformanceSample>(capacity: Limits.systemSamples)
    private var batteryBuffer = BoundedPerformanceBuffer<BatteryTelemetrySample>(capacity: Limits.batterySamples)
    private var energyBuffer = BoundedPerformanceBuffer<EnergySample>(capacity: Limits.energySamples)
    private var networkBuffer = BoundedPerformanceBuffer<NetworkSummary>(capacity: Limits.networkSummaries)
    private var processBuffer = BoundedPerformanceBuffer<ProcessPerformanceBatch>(capacity: Limits.processBatches)
    private var logBuffer = BoundedPerformanceBuffer<PerformanceLogEvent>(capacity: Limits.logEvents)
    private var gapBuffer = BoundedPerformanceBuffer<PerformanceStreamGap>(capacity: Limits.sessionEvents)
    private var errorBuffer = BoundedPerformanceBuffer<PerformanceProviderError>(capacity: Limits.sessionEvents)
    private var markerBuffer = BoundedPerformanceBuffer<PerformanceUserMarker>(capacity: Limits.sessionEvents)
    private var warningBuffer = BoundedPerformanceBuffer<String>(capacity: Limits.diagnostics)
    private var diagnosticBuffer = BoundedPerformanceBuffer<String>(capacity: Limits.diagnostics)

    init(service: PerformanceMonitorService = PerformanceMonitorService()) {
        self.service = service
        beginConsumingEvents()
    }

    deinit {
        eventTask?.cancel()
        flushTask?.cancel()
        elapsedTask?.cancel()
        timelineBuildTask?.cancel()
        lagSummaryTask?.cancel()
    }

    var canStart: Bool {
        !operationInFlight && [.idle, .helperReady, .helperFailed, .connectionLost].contains(state)
    }

    var canStop: Bool { !operationInFlight && state == .monitoring }
    var canMarkLag: Bool { !operationInFlight && state == .monitoring }
    var requiresShutdown: Bool { helperPID != nil || state != .idle }
    var droppedCount: Int { outputQueue.droppedCount }
    var providerErrorCount: Int { providerErrors.count }

    func setTimelineVisible(_ visible: Bool) {
        timelineVisible = visible
        if visible { scheduleTimelineBuild(force: true) }
    }

    func setDiagnosisVisible(_ visible: Bool) {
        diagnosisVisible = visible
        if visible { scheduleTimelineBuild(force: true) }
    }

    func setTimelineRange(_ range: PerformanceTimelineRange) {
        guard timelineRange != range else { return }
        timelineRange = range
        scheduleTimelineBuild(force: true)
    }

    func setTimelineProcessFilter(query: String, includeObserverProcesses: Bool) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard timelineProcessQuery != normalizedQuery
                || timelineIncludeObserverProcesses != includeObserverProcesses
        else { return }
        timelineProcessQuery = normalizedQuery
        timelineIncludeObserverProcesses = includeObserverProcesses
        timelineDirty = true
        scheduleTimelineBuild(force: true)
    }

    func startMonitoring() {
        guard canStart else { return }
        AppLogger.performance.info("start button pressed state=\(self.state.rawValue, privacy: .public)")
        operationInFlight = true
        lastError = nil
        resetSessionData()
        let config = PerformanceMonitoringConfiguration(enableOSLog: oslogEnabled)
        Task { [weak self] in
            guard let self else { return }
            await performStart(config: config)
        }
    }

    private func performStart(config: PerformanceMonitoringConfiguration) async {
        do {
            try await service.startMonitoring(config: config)
            AppLogger.performance.info("start request reached monitoring state")
        } catch let serviceError as PerformanceMonitorServiceError {
            let diagnostic = AppLogger.redactedDiagnostic(serviceError.localizedDescription)
            AppLogger.performance.error(
                "start request failed state=\(self.state.rawValue, privacy: .public) error=\(diagnostic, privacy: .public)"
            )
            lastError = serviceError.localizedDescription
        } catch {
            let diagnostic = AppLogger.redactedDiagnostic(error.localizedDescription)
            AppLogger.performance.error(
                "start request failed state=\(self.state.rawValue, privacy: .public) error=\(diagnostic, privacy: .public)"
            )
            lastError = error.localizedDescription
        }
        operationInFlight = false
    }

    func stopMonitoring() {
        guard canStop else { return }
        operationInFlight = true
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.stopMonitoring()
            } catch {
                lastError = error.localizedDescription
            }
            operationInFlight = false
        }
    }

    func markLag(note: String) {
        guard canMarkLag else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.markLag(note: note)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearDisplayedLogs() {
        objectWillChange.send()
        logBuffer.removeAll()
        logs = []
    }

    func shutdownForLifecycle() async {
        if let lifecycleShutdownTask {
            await lifecycleShutdownTask.value
            return
        }

        operationInFlight = true
        let task = Task { await service.shutdown() }
        lifecycleShutdownTask = task
        await task.value
        lifecycleShutdownTask = nil
        operationInFlight = false
    }

    private func beginConsumingEvents() {
        let events = service.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { break }
                handle(event)
            }
        }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { break }
                flushPendingMessages()
            }
        }
    }

    private func handle(_ event: PerformanceMonitorServiceEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
            if newState == .monitoring {
                startElapsedClock()
            } else {
                elapsedTask?.cancel()
                elapsedTask = nil
            }
        case .helperLocated(let source):
            helperSource = source
        case .helperStarted(let pid):
            helperPID = pid
        case .message(let message):
            receivedMessageCount += 1
            pendingMessages.append(message)
            if pendingMessages.count >= 200 { flushPendingMessages() }
        case .stderr(let diagnostic):
            diagnosticBuffer.append(diagnostic)
            helperDiagnostics = diagnosticBuffer.elements
        case .compatibilityWarning(let warning):
            warningBuffer.append(warning)
            compatibilityWarnings = warningBuffer.elements
        case .processExited(_, _):
            helperPID = nil
        }
    }

    private func flushPendingMessages() {
        guard !pendingMessages.isEmpty else { return }
        storeBatchPublishCount += 1
        objectWillChange.send()
        let messages = pendingMessages
        pendingMessages.removeAll(keepingCapacity: true)
        var logsChanged = false
        var gapsChanged = false
        var errorsChanged = false
        var markersChanged = false
        var receivedTimelineData = false

        for message in messages {
            lastUpdate = message.timestamp ?? Date()
            switch message.type {
            case .helperReady, .capabilities:
                capability = PerformanceCapability(message: message)
            case .sessionStarted:
                sessionStartedAt = message.timestamp ?? Date()
                sessionElapsed = 0
                activeTimelineSessionID = message.sessionID
                sessionStartMonotonicNS = message.monotonicNS
                sessionEndMonotonicNS = nil
                receivedTimelineData = true
                if let device = message.payload.object("device"),
                   device.string("developer_transport") == "userspace_rsd" {
                    transportDescription = "USB · 性能服务已连接"
                }
            case .systemSample:
                if let sample = SystemPerformanceSample(message: message) {
                    systemBuffer.append(sample)
                    latestSystem = sample
                    receivedTimelineData = true
                }
            case .processBatch:
                if let batch = ProcessPerformanceBatch(message: message) {
                    processBuffer.append(batch)
                    latestProcesses = batch.processes
                    receivedTimelineData = true
                }
            case .batterySample:
                if let sample = BatteryTelemetrySample(message: message) {
                    batteryBuffer.append(sample)
                    latestBattery = sample
                    latestBatteryReceivedAt = Date()
                    receivedTimelineData = true
                }
            case .energySample:
                if let sample = EnergySample(message: message) {
                    energyBuffer.append(sample)
                    latestEnergy = sample
                    receivedTimelineData = true
                }
            case .networkSummary:
                if let summary = NetworkSummary(message: message) {
                    networkBuffer.append(summary)
                    latestNetwork = summary
                    receivedTimelineData = true
                }
            case .logEvent:
                if let event = PerformanceLogEvent(message: message) {
                    logBuffer.append(event)
                    logsChanged = true
                }
            case .logSummary:
                latestLogSummary = PerformanceLogSummary(message: message)
            case .streamGap:
                if let gap = PerformanceStreamGap(message: message) {
                    gapBuffer.append(gap)
                    gapsChanged = true
                    receivedTimelineData = true
                }
            case .providerError, .commandError:
                if let error = PerformanceProviderError(message: message) {
                    errorBuffer.append(error)
                    errorsChanged = true
                    lastError = "\(error.provider)：\(error.summary)"
                }
            case .userMarker:
                if let marker = PerformanceUserMarker(message: message) {
                    markerBuffer.append(marker)
                    markersChanged = true
                    lastMarkerAt = marker.timestamp ?? Date()
                    receivedTimelineData = true
                    scheduleLagSummary(for: marker)
                }
            case .heartbeat:
                if let heartbeat = PerformanceHeartbeat(message: message) {
                    providerStates = heartbeat.providerStates
                    outputQueue = heartbeat.queue
                }
            case .providerStatus, .status:
                if let provider = message.payload.string("provider"),
                   let status = message.payload.string("status") {
                    providerStates[provider] = status
                }
            case .sessionEnded:
                sessionEndMonotonicNS = message.monotonicNS
                receivedTimelineData = true
                if let queue = message.payload.object("output_queue") {
                    outputQueue = PerformanceOutputQueueStats(object: queue)
                }
                if lagSummaryPending, let marker = markerBuffer.elements.last {
                    lagSummaryTask?.cancel()
                    buildLagSummary(for: marker)
                }
            case .unknown(let rawType):
                warningBuffer.append("未知消息 \(rawType)，\(message.payloadKeySummary)")
                compatibilityWarnings = warningBuffer.elements
            default:
                break
            }
        }

        if logsChanged { logs = logBuffer.elements }
        if gapsChanged { streamGaps = gapBuffer.elements }
        if errorsChanged { providerErrors = errorBuffer.elements }
        if markersChanged { userMarkers = markerBuffer.elements }
        if receivedTimelineData {
            timelineDirty = true
            scheduleTimelineBuild()
        }
    }

    private func scheduleTimelineBuild(force: Bool = false) {
        guard (timelineVisible || diagnosisVisible), force || timelineDirty,
              let sessionID = activeTimelineSessionID,
              let startMonotonic = sessionStartMonotonicNS
        else { return }

        let now = Date()
        if !force,
           let lastTimelineBuildStartedAt,
           now.timeIntervalSince(lastTimelineBuildStartedAt) < timelineRefreshInterval {
            // Keep timelineDirty set. The next one-second Store flush will retry,
            // while Helper sampling and raw bounded buffers continue unchanged.
            return
        }

        timelineDirty = false
        lastTimelineBuildStartedAt = now
        timelineBuildGeneration &+= 1
        let generation = timelineBuildGeneration
        let range = timelineRange
        let processQuery = timelineProcessQuery
        let includeObserverProcesses = timelineIncludeObserverProcesses
        guard let input = timelineInput(sessionID: sessionID, startMonotonic: startMonotonic) else { return }

        timelineBuildTask?.cancel()
        timelineBuildTask = Task { [weak self] in
            let frame = await Task.detached(priority: .utility) {
                PerformanceTimelineBuilder.build(
                    input: input,
                    range: range,
                    processQuery: processQuery,
                    includeObserverProcesses: includeObserverProcesses
                )
            }.value
            guard let self, !Task.isCancelled, generation == timelineBuildGeneration else { return }
            timelineFramePublishCount += 1
            timelineRevision &+= 1
            timelineFrame = frame
            if timelineFramePublishCount.isMultiple(of: 10) {
                AppLogger.performance.info(
                    "timeline counters messages=\(self.receivedMessageCount, privacy: .public) store_batches=\(self.storeBatchPublishCount, privacy: .public) timeline_frames=\(self.timelineFramePublishCount, privacy: .public) raw_points=\(frame.rawPointCount, privacy: .public) plotted_points=\(frame.plottedPointCount, privacy: .public)"
                )
            }
        }
    }

    private func scheduleLagSummary(for marker: PerformanceUserMarker) {
        lagSummaryTask?.cancel()
        lagSummaryPending = true
        lagSummaryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled else { return }
            buildLagSummary(for: marker)
        }
    }

    private func buildLagSummary(for marker: PerformanceUserMarker) {
        guard let sessionID = activeTimelineSessionID,
              let startMonotonic = sessionStartMonotonicNS,
              let input = timelineInput(sessionID: sessionID, startMonotonic: startMonotonic)
        else {
            lagSummaryPending = false
            return
        }
        let errorCount = errorBuffer.elements.count
        let droppedCount = outputQueue.droppedCount
        lagSummaryTask = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                PerformanceInsightAnalyzer.lagSummary(
                    input: input,
                    marker: marker,
                    providerErrorCount: errorCount,
                    droppedCount: droppedCount
                )
            }.value
            guard let self, !Task.isCancelled,
                  marker.id == markerBuffer.elements.last?.id
            else { return }
            latestLagSummary = summary
            lagSummaryPending = false
        }
    }

    private func timelineInput(
        sessionID: String,
        startMonotonic: UInt64
    ) -> PerformanceTimelineInput? {
        guard sessionID == activeTimelineSessionID else { return nil }
        return PerformanceTimelineInput(
            sessionID: sessionID,
            sessionStartMonotonicNS: startMonotonic,
            sessionStartTimestamp: sessionStartedAt,
            sessionEndMonotonicNS: sessionEndMonotonicNS,
            systemSamples: systemBuffer.elements,
            processBatches: processBuffer.elements,
            batterySamples: batteryBuffer.elements,
            energySamples: energyBuffer.elements,
            networkSummaries: networkBuffer.elements,
            gaps: gapBuffer.elements,
            markers: markerBuffer.elements
        )
    }

    private func resetSessionData() {
        systemBuffer.removeAll()
        batteryBuffer.removeAll()
        energyBuffer.removeAll()
        networkBuffer.removeAll()
        processBuffer.removeAll()
        logBuffer.removeAll()
        gapBuffer.removeAll()
        errorBuffer.removeAll()
        markerBuffer.removeAll()
        timelineBuildTask?.cancel()
        timelineBuildTask = nil
        lagSummaryTask?.cancel()
        lagSummaryTask = nil
        timelineBuildGeneration &+= 1
        timelineDirty = false
        activeTimelineSessionID = nil
        sessionStartMonotonicNS = nil
        sessionEndMonotonicNS = nil
        timelineFrame = .empty
        latestLagSummary = nil
        lagSummaryPending = false
        timelineRevision &+= 1
        receivedMessageCount = 0
        storeBatchPublishCount = 0
        timelineFramePublishCount = 0
        lastTimelineBuildStartedAt = nil
        timelineProcessQuery = ""
        timelineIncludeObserverProcesses = false
        latestSystem = nil
        latestBattery = nil
        latestBatteryReceivedAt = nil
        latestEnergy = nil
        latestNetwork = nil
        latestProcesses = []
        logs = []
        latestLogSummary = nil
        streamGaps = []
        providerErrors = []
        userMarkers = []
        providerStates = [:]
        outputQueue = PerformanceOutputQueueStats(object: [:])
        lastUpdate = nil
        sessionStartedAt = nil
        sessionElapsed = 0
        lastMarkerAt = nil
        transportDescription = "正在建立 USB 性能监控连接"
    }

    private func startElapsedClock() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                // stateChanged(.monitoring) can arrive before the one-second
                // message batch publishes session_started. Wait for that batch
                // instead of permanently ending the clock at 00:00:00.
                if let started = sessionStartedAt {
                    sessionElapsed = max(0, Date().timeIntervalSince(started))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
