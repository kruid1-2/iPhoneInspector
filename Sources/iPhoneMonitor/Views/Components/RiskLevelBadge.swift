import SwiftUI
import iPhoneMonitorCore

struct RiskLevelBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    var color: Color {
        switch level {
        case .normal: return .green
        case .notice: return .blue
        case .moderate: return .orange
        case .high: return .red
        case .severe: return .red
        case .insufficient: return .secondary
        }
    }
}
