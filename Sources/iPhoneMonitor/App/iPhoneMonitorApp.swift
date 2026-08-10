import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var performanceMonitorStore: PerformanceMonitorStore?
    private var terminationReplyPending = false
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.performanceMonitorStore?.shutdownForLifecycle()
                }
            }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let performanceMonitorStore, performanceMonitorStore.requiresShutdown else {
            return .terminateNow
        }
        guard !terminationReplyPending else { return .terminateLater }

        terminationReplyPending = true
        Task { @MainActor [weak self, weak sender] in
            await performanceMonitorStore.shutdownForLifecycle()
            self?.terminationReplyPending = false
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct iPhoneInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appStore = AppStore()

    var body: some Scene {
        WindowGroup("iPhone 诊断助手", id: "main") {
            ContentView(appStore: appStore)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear {
                    appDelegate.performanceMonitorStore = appStore.performanceMonitorStore
                }
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入诊断文件…") {
                    appStore.isImporterPresented = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("设备") {
                Button("刷新设备") {
                    appStore.deviceStore.requestRefresh(detailed: true)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appStore.deviceStore.isRefreshing)
            }
        }

        Settings {
            SettingsView(
                settingsStore: appStore.settingsStore,
                diagnosticStore: appStore.diagnosticStore,
                embedded: false
            )
        }
    }
}
