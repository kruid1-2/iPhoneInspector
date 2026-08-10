import SwiftUI
import iPhoneMonitorCore

struct DataFieldRow: View {
    let title: String
    let value: String?
    let availability: DataAvailability
    let source: String
    var detail: String? = nil
    var updatedAt: Date? = nil
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if let value, !value.isEmpty {
                    Text(value)
                        .font(monospaced ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                } else {
                    Text(availability.message)
                        .foregroundStyle(.secondary)
                }
                Text("来源：\(source)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if availability == .stale, let updatedAt {
                    Text("上次成功读取：\(AppFormatters.date(updatedAt))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)
            AvailabilityBadge(availability: availability)
        }
        .padding(.vertical, 2)
    }
}

struct AvailabilityBadge: View {
    let availability: DataAvailability

    var body: some View {
        Text(availability.message)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var color: Color {
        switch availability {
        case .available: return .green
        case .demo: return .orange
        case .permissionDenied: return .red
        case .stale: return .orange
        default: return .secondary
        }
    }
}
