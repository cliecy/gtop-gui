import GTopCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: ClusterMonitorStore
    @Binding var selection: SidebarDestination?
    let onOpenRuleManager: () -> Void
    let onNotify: (String) -> Void

    @State private var showFilteredSection = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("监控视图") {
                    NavigationLink(value: SidebarDestination.overview) {
                        HStack {
                            Label("集群总览", systemImage: "square.grid.2x2")
                            Spacer()
                            if store.totalGPUCount > 0 {
                                Text("\(store.totalGPUCount) 卡")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    NavigationLink(value: SidebarDestination.idleGPUs) {
                        HStack {
                            Label("空闲 GPU", systemImage: "sparkles")
                            Spacer()
                            let idleCount = store.totalFreeGPUCount
                            if idleCount > 0 {
                                Text("\(idleCount)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.green)
                            } else {
                                Text("0")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if !store.onlineSlurmHosts.isEmpty {
                        NavigationLink(value: SidebarDestination.slurmJobs) {
                            HStack {
                                Label("Slurm 作业", systemImage: "square.stack.3d.up")
                                Spacer()
                                if store.mySlurmJobCount > 0 {
                                    Text("我 \(store.mySlurmJobCount)")
                                        .font(.caption2.weight(.semibold))
                                        .monospacedDigit()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.purple)
                                }
                                Text("\(store.allSlurmJobs.count)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    NavigationLink(value: SidebarDestination.allProcesses) {
                        HStack {
                            Label("全部进程", systemImage: "list.bullet.rectangle.portrait")
                            Spacer()
                            let procCount = store.allProcesses.count
                            if procCount > 0 {
                                Text("\(procCount)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if !store.groupSummaries.isEmpty {
                    Section("分组") {
                        ForEach(store.groupSummaries) { group in
                            NavigationLink(value: SidebarDestination.group(group.name)) {
                                HStack(spacing: 6) {
                                    Label(group.name, systemImage: "folder")
                                        .lineLimit(1)
                                    Spacer()
                                    if group.idleGPUs > 0 {
                                        Text("\(group.idleGPUs) 空")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.green)
                                            .monospacedDigit()
                                    }
                                    Text("\(group.onlineHosts)/\(group.totalHosts)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }

                Section("已选中监控 (\(store.monitoredHostStates.count))") {
                    if store.monitoredHostStates.isEmpty {
                        Text("尚未选中任何主机")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.monitoredHostStates) { host in
                            NavigationLink(value: SidebarDestination.host(host.config.alias)) {
                                HostSidebarRow(host: host)
                            }
                            .contextMenu {
                                hostContextMenu(host)
                            }
                        }
                    }
                }

                if !store.filteredOutHostStates.isEmpty {
                    Section {
                        DisclosureGroup(
                            isExpanded: $showFilteredSection,
                            content: {
                                ForEach(store.filteredOutHostStates) { host in
                                    NavigationLink(value: SidebarDestination.host(host.config.alias)) {
                                        HStack(spacing: 8) {
                                            Button {
                                                store.setHostSelected(host.config.alias, selected: true)
                                                onNotify("已选中监控：\(host.config.alias)")
                                            } label: {
                                                Image(systemName: "plus.circle")
                                                    .foregroundStyle(.blue)
                                            }
                                            .buttonStyle(.plain)
                                            .help("选中并开始监控此主机")

                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(host.config.alias)
                                                    .font(.callout)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                Text(host.matchReason)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                        }
                                    }
                                    .contextMenu {
                                        hostContextMenu(host)
                                    }
                                }
                            },
                            label: {
                                Text("未选中主机 (\(store.filteredOutHostStates.count))")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        )
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Footer bar
            HStack(spacing: 8) {
                Button(action: onOpenRuleManager) {
                    Label("过滤规则与主机", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)

                Spacer()

                if store.isDemoMode {
                    BadgePill(text: "演示", color: .purple)
                } else {
                    Text("\(store.onlineHostCount)/\(store.monitoredHostStates.count) 在线")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.bar)
        }
        .onAppear {
            if store.monitoredHostStates.isEmpty && !store.filteredOutHostStates.isEmpty {
                showFilteredSection = true
            }
        }
    }

    @ViewBuilder
    private func hostContextMenu(_ host: HostMonitorState) -> some View {
        Button {
            Task { await store.refreshHost(host.config.alias) }
        } label: {
            Label("立即刷新", systemImage: "arrow.clockwise")
        }
        .disabled(!host.isMonitored)

        Button {
            let cmd = "ssh \(host.config.alias)"
            SystemActions.copyToClipboard(cmd)
            onNotify("已复制：\(cmd)")
        } label: {
            Label("复制 SSH 命令", systemImage: "doc.on.doc")
        }

        Button {
            SystemActions.openSSHInTerminal(alias: host.config.alias)
        } label: {
            Label("在终端中连接", systemImage: "terminal")
        }

        Divider()

        let currentOverride = store.settings.manualOverrides[host.config.alias] ?? .auto
        if host.isMonitored {
            Button {
                store.setManualOverride(for: host.config.alias, override: .forceDisable)
            } label: {
                Label("暂停/排除此主机", systemImage: "eye.slash")
            }
        } else {
            Button {
                store.setManualOverride(for: host.config.alias, override: .forceEnable)
            } label: {
                Label("强制启用监控", systemImage: "checkmark.circle")
            }
        }

        if currentOverride != .auto {
            Button {
                store.setManualOverride(for: host.config.alias, override: .auto)
            } label: {
                Label("恢复跟随规则", systemImage: "arrow.uturn.backward")
            }
        }
    }
}

private struct HostSidebarRow: View {
    let host: HostMonitorState

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: host.status, size: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(host.config.alias)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if host.isSlurmCluster {
                        Text("Slurm")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
                if let slurm = host.slurm, host.status.isOnline {
                    Text("\(slurm.freeGPUs)/\(slurm.totalGPUs) 空 · \(slurm.runningJobs.count)R")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else if host.status.isOnline {
                    Text("\(host.gpus.count) GPU · \(Formatters.percent(host.averageGPUUtilization))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(host.status.label)
                        .font(.caption2)
                        .foregroundStyle(host.status.errorDetail != nil ? .red : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let slurm = host.slurm, host.status.isOnline, !slurm.gpuNodes.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(slurm.gpuNodes.prefix(8)) { node in
                        let frac = max(0.14, min(1.0, node.gpuAllocationPercent / 100.0))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(GTopTheme.slurmNodeColor(node.stateCategory))
                            .frame(width: 3.5, height: 14 * frac)
                    }
                }
                .frame(height: 14, alignment: .bottom)
            } else if host.status.isOnline && !host.gpus.isEmpty {
                MiniGPUHeatBars(gpus: host.gpus, maxHeight: 14, barWidth: 3.5)
            }
        }
        .padding(.vertical, 1)
    }
}
