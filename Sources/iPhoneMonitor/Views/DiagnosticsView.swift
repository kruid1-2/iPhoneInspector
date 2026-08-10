import SwiftUI
import iPhoneMonitorCore

struct DiagnosticsView: View {
    @ObservedObject var store: DiagnosticStore
    let onImport: () -> Void
    let onDrop: (URL) -> Void
    @State private var selectedCategory: DiagnosticCategory?

    private var filteredRecords: [DiagnosticRecord] {
        guard let selectedCategory else { return store.allRecords }
        return store.allRecords.filter { $0.category == selectedCategory }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if store.isImporting {
                    SectionCard("正在导入") {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: store.progress)
                            Text(store.progressMessage)
                                .foregroundStyle(.secondary)
                            Button("取消导入") {
                                store.cancelImport()
                            }
                        }
                    }
                }

                if let error = store.lastError {
                    SectionCard("导入错误") {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if store.analyses.isEmpty {
                    importPrompt
                } else {
                    sourceSummary
                    categoryFilter
                    recordsList
                }
            }
            .padding(22)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onDrop(url)
            return true
        }
        .navigationTitle("诊断日志")
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageHeader(
                title: "诊断日志",
                subtitle: "支持拖放或选择 .ips、.panic、.log、.txt、.zip、.tar.gz 和诊断文件夹。"
            )
            Button("导入诊断文件", action: onImport)
                .buttonStyle(.borderedProminent)
                .disabled(store.isImporting)
        }
    }

    private var importPrompt: some View {
        SectionCard(
            "导入一份诊断日志开始分析",
            subtitle: "解析在本机进行，不上传任何文件"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("第一版优先扫描 panic-full、JetsamEvent、LowMemory、thermal、watchdog、崩溃、电池和存储相关摘要，不会尝试一次性读取 sysdiagnose 中的全部文件。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("选择文件或文件夹", action: onImport)
                        .buttonStyle(.borderedProminent)
                    Text("也可以把文件拖到这个页面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sourceSummary: some View {
        SectionCard("导入记录") {
            ForEach(store.analyses) { analysis in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.zipper")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(analysis.sourceName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(
                            "\(analysis.scannedFileCount) 个文件 · \(analysis.records.count) 条记录 · \(analysis.importedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !analysis.failures.isEmpty {
                            Text("\(analysis.failures.count) 个文件解析失败，其他结果仍已保留")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if analysis.retainedCopyName != nil {
                        StatusPill(text: "保留副本", color: .blue)
                    } else {
                        StatusPill(text: "只读分析", color: .secondary)
                    }
                }
                if analysis.id != store.analyses.last?.id {
                    Divider()
                }
            }
        }
    }

    private var categoryFilter: some View {
        SectionCard("记录类型") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    filterButton(title: "全部", category: nil, count: store.allRecords.count)
                    ForEach(DiagnosticCategory.allCases, id: \.rawValue) { category in
                        let count = store.allRecords.filter { $0.category == category }.count
                        if count > 0 {
                            filterButton(
                                title: category.label,
                                category: category,
                                count: count
                            )
                        }
                    }
                }
            }
        }
    }

    private var recordsList: some View {
        SectionCard(
            "解析结果",
            subtitle: "\(filteredRecords.count) 条；未知格式会保留受限长度的原始摘要"
        ) {
            if filteredRecords.isEmpty {
                Text("这个类别没有记录。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredRecords.prefix(200)) { record in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(record.category.label, systemImage: icon(for: record.category))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(record.timestamp?.formatted(
                                date: .abbreviated,
                                time: .shortened
                            ) ?? "时间未返回")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Text(record.summary)
                            .font(.callout)
                        if !record.evidence.isEmpty {
                            Text(record.evidence)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Text("来源：\(record.sourceFile)")
                            Spacer()
                            Text("可信度：\(record.confidence.label)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    if record.id != filteredRecords.prefix(200).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func filterButton(
        title: String,
        category: DiagnosticCategory?,
        count: Int
    ) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Text("\(title) \(count)")
        }
        .buttonStyle(.bordered)
        .tint(selectedCategory == category ? .accentColor : .secondary)
    }

    private func icon(for category: DiagnosticCategory) -> String {
        switch category {
        case .panic, .reset: return "arrow.counterclockwise.circle"
        case .jetsam, .lowMemory: return "memorychip"
        case .thermal: return "thermometer.high"
        case .watchdog: return "timer"
        case .crash, .springBoard, .backboard: return "app.badge"
        case .battery: return "battery.75percent"
        case .storage: return "internaldrive"
        case .power: return "bolt"
        case .unknown: return "questionmark.document"
        }
    }
}
