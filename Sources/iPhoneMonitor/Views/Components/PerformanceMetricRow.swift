import SwiftUI

struct PerformanceMetricRow: View {
    let title: String
    let value: String
    let source: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 145, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .monospacedDigit()
                    .textSelection(.enabled)
                Text("来源：\(source)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }
}
