import Foundation

public enum PerformanceSessionState: String, CaseIterable, Equatable, Sendable {
    case idle
    case locatingHelper
    case startingHelper
    case helperReady
    case startingSession
    case monitoring
    case stoppingSession
    case shuttingDown
    case connectionLost
    case helperFailed
    case protocolMismatch

    public var label: String {
        switch self {
        case .idle: return "未启动"
        case .locatingHelper: return "正在定位 Helper"
        case .startingHelper: return "正在启动 Helper"
        case .helperReady: return "Helper 已就绪"
        case .startingSession: return "正在建立监控会话"
        case .monitoring: return "监控中"
        case .stoppingSession: return "正在停止会话"
        case .shuttingDown: return "正在关闭 Helper"
        case .connectionLost: return "连接已中断"
        case .helperFailed: return "Helper 失败"
        case .protocolMismatch: return "协议版本不兼容"
        }
    }
}

public struct PerformanceMonitoringConfiguration: Equatable, Sendable {
    public var sampleIntervalMS = 1_000
    public var batteryIntervalMS = 2_000
    public var energyIntervalMS = 1_000
    public var summaryIntervalMS = 2_000
    public var heartbeatIntervalMS = 5_000
    public var maxProcesses = 30
    public var maxLogEventsPerInterval = 10
    public var enableOSLog = false

    public init(enableOSLog: Bool = false) {
        self.enableOSLog = enableOSLog
    }

    public var helperPayload: [String: Any] {
        [
            "sample_interval_ms": sampleIntervalMS,
            "battery_interval_ms": batteryIntervalMS,
            "energy_interval_ms": energyIntervalMS,
            "summary_interval_ms": summaryIntervalMS,
            "heartbeat_interval_ms": heartbeatIntervalMS,
            "max_processes": maxProcesses,
            "max_log_events_per_interval": maxLogEventsPerInterval,
            "enable_sysmon": true,
            "enable_battery": true,
            "enable_energy": true,
            "enable_oslog": enableOSLog,
            "enable_network": true,
            "emit_log_messages": enableOSLog
        ]
    }
}
