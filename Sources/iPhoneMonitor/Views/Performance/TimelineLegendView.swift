import SwiftUI
import iPhoneMonitorCore

struct TimelineLegendView: View {
    let series: [TimelineSeries]
    let colors: [Color]

    var body: some View {
        FlowLayout(spacing: 10) {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 5) {
                    Capsule()
                        .fill(colors[index % colors.count])
                        .frame(width: 14, height: 3)
                    Text(displayTitle(item))
                        .lineLimit(1)
                    if item.observerOverhead {
                        Text("监控工具自身开销")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .help(item.detail)
            }
        }
    }

    private func displayTitle(_ item: TimelineSeries) -> String {
        guard let processName = item.processName else { return item.title }
        let name = AppNameResolver.displayName(for: processName)
        return item.pid.map { "\(name)（PID \($0)）" } ?? name
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maximumWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: min(maximumWidth, max(0, x)), height: y + rowHeight), points)
    }
}
