import SwiftUI
import iPhoneMonitorCore

struct PerformanceProcessListView: View {
    enum SortMode: String, CaseIterable, Identifiable, Sendable {
        case cpu
        case memory

        var id: String { rawValue }
        var title: String { self == .cpu ? "处理器负载" : "应用内存" }
    }

    let processes: [ProcessPerformanceSample]
    @SceneStorage("performance.processes.search") private var searchText = ""
    @SceneStorage("performance.processes.sort") private var sortModeRaw = SortMode.cpu.rawValue
    @SceneStorage("performance.processes.highLoadOnly") private var highLoadOnly = false
    @State private var displayedProcesses: [ProcessPerformanceSample] = []
    @State private var filterTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("排序", selection: sortModeBinding) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Toggle("只看高负载", isOn: $highLoadOnly)
                Spacer()
                TextField("搜索进程", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Text("\(displayedProcesses.count) / \(processes.count) 个进程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Table(displayedProcesses) {
                TableColumn("PID") { process in
                    Text("\(process.pid)").monospacedDigit()
                }
                .width(min: 48, ideal: 58, max: 75)
                TableColumn("进程") { process in
                    HStack(spacing: 6) {
                        Text(AppNameResolver.displayName(for: process.name)).lineLimit(1)
                        if process.observerOverhead {
                            Text("监控工具自身开销")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.1), in: Capsule())
                        }
                    }
                }
                .width(min: 130, ideal: 210)
                TableColumn("处理器负载") { process in
                    Text(process.metric("cpuUsage")?.rawDisplay ?? "—").monospacedDigit()
                }
                .width(min: 90, ideal: 105)
                TableColumn("应用内存") { process in
                    Text(process.metric("physFootprint")?.confirmedDisplay ?? "—").monospacedDigit()
                }
                .width(min: 105, ideal: 125)
                TableColumn("常驻内存") { process in
                    Text(process.metric("memResidentSize")?.confirmedDisplay ?? "—").monospacedDigit()
                }
                .width(min: 90, ideal: 110)
                TableColumn("线程") { process in
                    Text(process.metric("threadCount")?.rawDisplay ?? "—").monospacedDigit()
                }
                .width(min: 45, ideal: 55)
                TableColumn("能耗评分") { process in
                    Text(process.metric("powerScore")?.rawDisplay ?? "—").monospacedDigit()
                }
                .width(min: 90, ideal: 110)
            }
        }
        .onAppear { rebuildDisplayedProcesses() }
        .onDisappear {
            filterTask?.cancel()
            filterTask = nil
        }
        .onChange(of: processes) { _ in rebuildDisplayedProcesses() }
        .onChange(of: searchText) { _ in rebuildDisplayedProcesses() }
        .onChange(of: sortMode) { _ in rebuildDisplayedProcesses() }
        .onChange(of: highLoadOnly) { _ in rebuildDisplayedProcesses() }
    }

    private func rebuildDisplayedProcesses() {
        filterTask?.cancel()
        let source = processes
        let query = searchText
        let mode = sortMode
        let highLoad = highLoadOnly
        filterTask = Task {
            let result = await Task.detached(priority: .utility) {
                let searched = source.filter { process in
                    let matchesSearch = query.isEmpty
                        || process.name.localizedCaseInsensitiveContains(query)
                        || String(process.pid).contains(query)
                    let matchesLoad = !highLoad
                        || (process.cpuRaw ?? 0) > 0
                        || (process.physicalMemoryMiB ?? 0) >= 100
                    return matchesSearch && matchesLoad
                }
                switch mode {
                case .cpu:
                    return searched.sorted { ($0.cpuRaw ?? -.infinity) > ($1.cpuRaw ?? -.infinity) }
                case .memory:
                    return searched.sorted {
                        ($0.physicalMemoryMiB ?? -.infinity) > ($1.physicalMemoryMiB ?? -.infinity)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            displayedProcesses = result
        }
    }

    private var sortMode: SortMode {
        SortMode(rawValue: sortModeRaw) ?? .cpu
    }

    private var sortModeBinding: Binding<SortMode> {
        Binding(
            get: { sortMode },
            set: { sortModeRaw = $0.rawValue }
        )
    }
}
