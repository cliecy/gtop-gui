import GTopCore
import SwiftUI

struct MainWindowView: View {
    @Bindable var store: ClusterMonitorStore
    @Bindable var coordinator: AppCoordinator

    @State private var searchText: String = ""
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                selection: $coordinator.selection,
                onOpenRuleManager: { coordinator.showRuleManager = true },
                onNotify: showToast
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            ZStack(alignment: .bottom) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ToastOverlay(message: toastMessage)
            }
            .animation(.spring(duration: 0.28), value: toastMessage)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索主机、GPU 型号、用户或进程")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Refresh interval selector
                Menu {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0, 30.0], id: \.self) { sec in
                        Button {
                            store.updateSettings { $0.refreshIntervalSeconds = sec }
                        } label: {
                            if store.settings.refreshIntervalSeconds == sec {
                                Label("\(Int(sec)) 秒", systemImage: "checkmark")
                            } else {
                                Text("\(Int(sec)) 秒")
                            }
                        }
                    }
                } label: {
                    Label("\(Int(store.settings.refreshIntervalSeconds))s", systemImage: "clock")
                }
                .help("修改刷新间隔")

                Button {
                    store.togglePause()
                } label: {
                    Label(
                        store.isPaused ? "继续监控" : "暂停",
                        systemImage: store.isPaused ? "play.fill" : "pause.fill"
                    )
                }
                .help(store.isPaused ? "恢复自动轮询" : "暂停自动轮询")

                Button {
                    Task { await store.refreshAllNow() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshingAll)
                .help("立即刷新全部主机 (⌘R)")

                Button {
                    coordinator.showRuleManager = true
                } label: {
                    Label("选择主机 / 规则", systemImage: "checklist")
                }
                .help("勾选要监控的主机、配置过滤规则与分组 (⌘,)")

                Button {
                    store.toggleDemoMode()
                    showToast(store.isDemoMode ? "已切换至演示模式" : "已切回真实 SSH 配置模式")
                } label: {
                    Label(
                        store.isDemoMode ? "退出演示" : "演示模式",
                        systemImage: store.isDemoMode ? "stop.circle.fill" : "sparkles.tv"
                    )
                }
                .tint(store.isDemoMode ? .purple : nil)
                .help("切换内置模拟 GPU 集群数据用于预览界面")
            }
        }
        .sheet(isPresented: $coordinator.showRuleManager) {
            RuleManagerView(store: store)
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch coordinator.selection ?? .overview {
        case .overview:
            ClusterOverviewView(
                store: store,
                groupFilter: nil,
                searchText: searchText,
                onSelectDestination: { coordinator.selection = $0 },
                onOpenRuleManager: { coordinator.showRuleManager = true },
                onNotify: showToast
            )
        case .group(let groupName):
            ClusterOverviewView(
                store: store,
                groupFilter: groupName,
                searchText: searchText,
                onSelectDestination: { coordinator.selection = $0 },
                onOpenRuleManager: { coordinator.showRuleManager = true },
                onNotify: showToast
            )
        case .idleGPUs:
            IdleGPUsView(
                store: store,
                searchText: searchText,
                onSelectHost: { coordinator.selection = .host($0) },
                onNotify: showToast
            )
        case .slurmJobs:
            SlurmJobsView(
                store: store,
                searchText: searchText,
                onSelectHost: { coordinator.selection = .host($0) },
                onNotify: showToast
            )
        case .allProcesses:
            AllProcessesView(
                store: store,
                searchText: searchText,
                onSelectHost: { coordinator.selection = .host($0) },
                onNotify: showToast
            )
        case .host(let alias):
            HostDetailView(
                store: store,
                alias: alias,
                onNotify: showToast
            )
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toastMessage = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }
}
