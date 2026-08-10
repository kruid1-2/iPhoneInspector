import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var appStore: AppStore
    @ObservedObject private var deviceStore: DeviceStore
    @ObservedObject private var diagnosticStore: DiagnosticStore
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var performanceStore: PerformanceMonitorStore
    @SceneStorage("selectedInspectorSection") private var selectionRaw = InspectorSection.overview.rawValue

    init(appStore: AppStore) {
        self.appStore = appStore
        deviceStore = appStore.deviceStore
        diagnosticStore = appStore.diagnosticStore
        settingsStore = appStore.settingsStore
        performanceStore = appStore.performanceMonitorStore
    }

    private var selection: Binding<InspectorSection?> {
        Binding {
            InspectorSection(rawValue: selectionRaw)
        } set: { newValue in
            selectionRaw = (newValue ?? .overview).rawValue
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: selection,
                device: deviceStore.primaryDevice,
                riskCount: appStore.riskFindings.filter { $0.level >= .moderate }.count,
                performanceState: performanceStore.state
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                DeviceHeaderBar(
                    deviceStore: deviceStore,
                    diagnosticStore: diagnosticStore,
                    onRefresh: {
                        deviceStore.requestRefresh(detailed: true)
                    },
                    onImport: {
                        appStore.isImporterPresented = true
                    }
                )
                Divider()

                if settingsStore.demoMode {
                    DemoModeBanner()
                }

                detailView(for: InspectorSection(rawValue: selectionRaw) ?? .overview)
            }
        }
        .fileImporter(
            isPresented: $appStore.isImporterPresented,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            appStore.importDiagnostics(from: url)
        }
        .task {
            deviceStore.startMonitoring(settings: settingsStore)
        }
        .onDisappear {
            deviceStore.stopMonitoring()
            Task { await performanceStore.shutdownForLifecycle() }
        }
    }

    @ViewBuilder
    private func detailView(for section: InspectorSection) -> some View {
        switch section {
        case .overview:
            OverviewView(appStore: appStore)
        case .device:
            DeviceInformationView(
                deviceStore: deviceStore,
                settingsStore: settingsStore
            )
        case .battery:
            BatteryView(
                battery: appStore.effectiveBattery,
                isDemo: settingsStore.demoMode,
                hasDevice: deviceStore.primaryDevice != nil
            )
        case .storage:
            StorageView(
                storage: appStore.effectiveStorage,
                riskService: appStore.riskService,
                isDemo: settingsStore.demoMode
            )
        case .performance:
            PerformanceMonitorView(
                store: performanceStore,
                deviceStore: deviceStore
            )
        case .diagnostics:
            DiagnosticsView(
                store: diagnosticStore,
                onImport: { appStore.isImporterPresented = true },
                onDrop: appStore.importDiagnostics
            )
        case .risks:
            RiskFindingsView(findings: appStore.riskFindings)
        case .settings:
            SettingsView(
                settingsStore: settingsStore,
                diagnosticStore: diagnosticStore,
                embedded: true
            )
        }
    }

    private static var importTypes: [UTType] {
        var types: [UTType] = [.folder, .plainText, .data, .archive]
        for extensionName in ["ips", "panic", "log", "txt", "zip", "gz", "tgz"] {
            if let type = UTType(filenameExtension: extensionName) {
                types.append(type)
            }
        }
        return Array(Set(types))
    }
}
