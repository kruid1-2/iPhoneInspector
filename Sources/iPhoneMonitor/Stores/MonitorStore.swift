import Combine
import Foundation
import iPhoneMonitorCore

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var report: DiagnosticReport?
    @Published var selectedDate: String?
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var isImporting = false
    @Published private(set) var deviceError: String?
    @Published private(set) var importError: String?
    @Published private(set) var statusMessage = "正在等待设备…"
    @Published private(set) var lastDeviceRefresh: Date?

    private let deviceService = DeviceService()
    private let analyzer = DiagnosticAnalyzer()
    private var monitorTask: Task<Void, Never>?

    init() {
        report = ReportPersistence.load()
        selectedDate = report?.preferredDay?.date
    }

    var selectedSnapshot: DailySnapshot? {
        guard let report else { return nil }
        if let selectedDate,
           let selected = report.days.first(where: { $0.date == selectedDate }) {
            return selected
        }
        return report.preferredDay
    }

    var allAlerts: [HealthAlert] {
        (report?.generalAlerts ?? []) + (selectedSnapshot?.alerts ?? [])
    }

    var primaryDevice: DeviceInfo? {
        devices.first(where: \.available) ?? devices.first
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func requestDeviceRefresh() {
        Task { await refreshDevices() }
    }

    func refreshDevices() async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }

        do {
            let fetched = try await deviceService.fetchDevices()
            devices = fetched
            deviceError = nil
            lastDeviceRefresh = Date()

            if let connected = fetched.first(where: \.available) {
                statusMessage = "\(connected.name) 已通过 \(connected.connectionLabel) 连接"
            } else if fetched.isEmpty {
                statusMessage = "未检测到 iPhone"
            } else {
                statusMessage = "检测到 iPhone，但当前不可用"
            }
        } catch {
            devices = []
            deviceError = error.localizedDescription
            lastDeviceRefresh = Date()
            statusMessage = "设备读取失败"
        }
    }

    func importDiagnostics(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        statusMessage = "正在分析诊断包…"

        Task {
            let gainedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if gainedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let newReport = try await analyzer.analyze(sourceURL: url)
                report = newReport
                selectedDate = newReport.preferredDay?.date
                ReportPersistence.save(newReport)
                statusMessage = "诊断完成：\(newReport.sourceName)"
            } catch {
                importError = error.localizedDescription
                statusMessage = "诊断失败"
            }
            isImporting = false
        }
    }
}
