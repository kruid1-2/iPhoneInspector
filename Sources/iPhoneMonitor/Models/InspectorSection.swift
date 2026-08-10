import Foundation

enum InspectorSection: String, CaseIterable, Identifiable {
    case overview
    case device
    case battery
    case storage
    case performance
    case diagnostics
    case risks
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .device: return "设备信息"
        case .battery: return "电池"
        case .storage: return "存储"
        case .performance: return "性能监控"
        case .diagnostics: return "诊断日志"
        case .risks: return "风险提示"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .device: return "iphone.gen3"
        case .battery: return "battery.75percent"
        case .storage: return "internaldrive"
        case .performance: return "waveform.path.ecg.rectangle"
        case .diagnostics: return "doc.text.magnifyingglass"
        case .risks: return "exclamationmark.shield"
        case .settings: return "gearshape"
        }
    }
}
