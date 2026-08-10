import SwiftUI
import iPhoneMonitorCore

struct SidebarView: View {
    @Binding var selection: InspectorSection?
    let device: ConnectedDevice?
    let riskCount: Int
    let performanceState: PerformanceSessionState

    var body: some View {
        List(selection: $selection) {
            Section("诊断") {
                ForEach(InspectorSection.allCases) { section in
                    HStack(spacing: 9) {
                        Image(systemName: section.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 17)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                                .lineLimit(1)
                            if let detail = detail(for: section) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(
                                        section == .risks && riskCount > 0
                                            ? Color.orange
                                            : Color.secondary
                                    )
                                    .lineLimit(1)
                            }
                        }
                    }
                    .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("iPhone 诊断助手")
    }

    private func detail(for section: InspectorSection) -> String? {
        switch section {
        case .device:
            guard let device else { return "未连接" }
            return device.isDemoData ? "演示数据" : device.connectionState.label
        case .risks where riskCount > 0:
            return "\(riskCount) 项需要关注"
        case .performance:
            return performanceState.label
        default:
            return nil
        }
    }
}
