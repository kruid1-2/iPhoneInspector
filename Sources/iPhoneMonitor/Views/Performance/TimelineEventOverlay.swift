import SwiftUI
import iPhoneMonitorCore

struct TimelineEventOverlay: View {
    let events: [TimelineEvent]
    let selectedMarkerID: String?
    let onSelectMarker: (TimelineEvent) -> Void

    var body: some View {
        let markers = events.filter { $0.kind == .userMarker }
        if !markers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(markers) { marker in
                        Button {
                            onSelectMarker(marker)
                        } label: {
                            Label(
                                String(format: "+%.1f 秒 · %@", marker.relativeSeconds, marker.detail),
                                systemImage: selectedMarkerID == marker.id ? "flag.fill" : "flag"
                            )
                            .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .help("查看标记前 60 秒与后 120 秒")
                    }
                }
            }
        }
    }
}
