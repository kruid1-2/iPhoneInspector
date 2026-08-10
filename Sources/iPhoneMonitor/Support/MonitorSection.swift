import Foundation

enum MonitorSection: String, CaseIterable, Identifiable {
    case overview
    case device
    case diagnostics
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .device: return "连接的 iPhone"
        case .diagnostics: return "深度诊断"
        case .privacy: return "数据范围与隐私"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .device: return "iphone.gen3"
        case .diagnostics: return "waveform.path.ecg"
        case .privacy: return "lock.shield"
        }
    }
}
