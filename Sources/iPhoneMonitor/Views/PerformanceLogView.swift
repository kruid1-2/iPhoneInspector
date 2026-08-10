import SwiftUI
import iPhoneMonitorCore

struct PerformanceLogView: View {
    @ObservedObject var store: PerformanceMonitorStore
    @State private var searchText = ""
    @State private var minimumLevel = "全部"
    @State private var pauseAutoScroll = false

    private let levels = ["全部", "debug", "info", "default", "error", "fault"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = store.latestLogSummary {
                HStack(spacing: 16) {
                    Label("已扫描 \(summary.eventsSeen)", systemImage: "doc.text.magnifyingglass")
                    Text("关键词事件 \(summary.keywordEventsEmitted)")
                    if summary.keywordEventsRateLimited > 0 {
                        Text("限流 \(summary.keywordEventsRateLimited)")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(summary.fullLogRetained ? "保留了完整日志" : "未保留完整日志")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            HStack {
                Picker("最低等级", selection: $minimumLevel) {
                    ForEach(levels, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 190)
                Toggle("暂停自动滚动", isOn: $pauseAutoScroll)
                Spacer()
                TextField("搜索日志", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("清空显示") { store.clearDisplayedLogs() }
                Text("\(filteredLogs.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                List(filteredLogs) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(event.timestamp?.formatted(date: .omitted, time: .standard) ?? "—")
                                .monospacedDigit()
                            Text(event.level)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(levelColor(event.level))
                            Text(event.process)
                                .font(.subheadline.weight(.medium))
                            if !event.subsystem.isEmpty {
                                Text(event.subsystem)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if let preview = event.messagePreview, !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        if !event.candidateTags.isEmpty {
                            Text(event.candidateTags.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .id(event.id)
                    .padding(.vertical, 3)
                }
                .onChange(of: filteredLogs.last?.id) { id in
                    guard !pauseAutoScroll, let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private var filteredLogs: [PerformanceLogEvent] {
        store.logs.filter { event in
            let haystack = [event.process, event.subsystem, event.category, event.messagePreview ?? "",
                            event.candidateTags.joined(separator: " ")].joined(separator: " ")
            let matchesSearch = searchText.isEmpty || haystack.localizedCaseInsensitiveContains(searchText)
            return matchesSearch && levelRank(event.level) >= levelRank(minimumLevel)
        }
    }

    private func levelRank(_ level: String) -> Int {
        switch level.casefolded {
        case "debug": return 0
        case "info": return 1
        case "default": return 2
        case "error": return 3
        case "fault": return 4
        default: return minimumLevel == "全部" ? 0 : -1
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.casefolded {
        case "error", "fault": return .red
        case "default": return .orange
        default: return .secondary
        }
    }
}

private extension String {
    var casefolded: String { folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}
