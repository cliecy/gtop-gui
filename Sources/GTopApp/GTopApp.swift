import AppKit
import GTopCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppCoordinator {
    var selection: SidebarDestination? = .overview
    var showRuleManager: Bool = false
}

final class GTopAppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var onReopenMainWindow: (() -> Void)?
    @MainActor var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            onReopenMainWindow?()
        }
        return true
    }
}

/// Isolated Commands struct so menu updates never re-evaluate `GTopApp.body`.
struct GTopCommands: Commands {
    let store: ClusterMonitorStore
    let coordinator: AppCoordinator

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("选择主机、过滤规则与设置…") {
                coordinator.showRuleManager = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("监控") {
            Button("立即刷新全部主机") {
                Task { await store.refreshAllNow() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(store.isPaused ? "恢复自动轮询" : "暂停自动轮询") {
                store.togglePause()
            }
            .keyboardShortcut("p", modifiers: .command)

            Divider()

            Button("重新解析 SSH Config") {
                store.reloadSSHConfig()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(store.isDemoMode ? "退出演示模式" : "切换演示模式") {
                store.toggleDemoMode()
            }
        }
    }
}

/// Thin root view that captures `@Environment(\.openWindow)` inside a View (safe for SwiftUI)
/// and wires up the native AppKit `StatusBarController` once.
private struct RootSceneView: View {
    let store: ClusterMonitorStore
    let coordinator: AppCoordinator
    let appDelegate: GTopAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowView(
            store: store,
            coordinator: coordinator
        )
        .onAppear {
            store.startIfNeeded()
            if appDelegate.statusBarController == nil {
                let controller = StatusBarController(
                    store: store,
                    coordinator: coordinator,
                    onOpenMainWindow: { destination in
                        if let destination {
                            coordinator.selection = destination
                        }
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                )
                controller.start()
                appDelegate.statusBarController = controller
            }
            appDelegate.onReopenMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            appDelegate.onTerminate = { [store, appDelegate] in
                Task { @MainActor in
                    appDelegate.statusBarController?.stop()
                    store.shutdown()
                }
            }
        }
    }
}

@main
struct GTopApp: App {
    @NSApplicationDelegateAdaptor(GTopAppDelegate.self) private var appDelegate

    private let store: ClusterMonitorStore
    private let coordinator = AppCoordinator()

    init() {
        self.store = ClusterMonitorStore(autoStart: false)
    }

    var body: some Scene {
        Window("GTop — SSH GPU 实时监控", id: "main") {
            RootSceneView(
                store: store,
                coordinator: coordinator,
                appDelegate: appDelegate
            )
        }
        .defaultSize(width: 1220, height: 780)
        .commands {
            GTopCommands(store: store, coordinator: coordinator)
        }
    }
}
