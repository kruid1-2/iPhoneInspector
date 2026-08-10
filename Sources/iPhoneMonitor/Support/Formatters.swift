import Foundation

enum AppFormatters {
    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return byteFormatter.string(fromByteCount: value)
    }

    static func percent(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(fractionDigits)f%%", value)
    }

    static func identifier(_ value: String?, reveal: Bool) -> String {
        guard let value, !value.isEmpty else { return "—" }
        guard !reveal else { return value }
        guard value.count > 10 else { return "••••••••" }
        return "\(value.prefix(4))••••••\(value.suffix(4))"
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "尚未刷新" }
        return value.formatted(date: .abbreviated, time: .standard)
    }
}
