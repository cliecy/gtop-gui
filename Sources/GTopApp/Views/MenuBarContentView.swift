import AppKit
import GTopCore
import SwiftUI

struct MenuBarContentView: View {
    @Bindable var store: ClusterMonitorStore
    let onOpenMainWindow: (SidebarDestination?) -> Void

    private func openMainWindow(_ destination: SidebarDestination?) {
        onOpenMainWindow(destination)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "cpu.fill")
                        .foregroundStyle(.green)
                    Text("GTop")
                        .font(.headline)
                    if store.isDemoMode {
                        BadgePill(text: "演示", color: .purple)
                    }
                    if store.isPaused {
                        BadgePill(text: "已暂停", color: .orange)
                    }
                }
                Spacer()
                Text("\(Int(store.settings.refreshIntervalSeconds))s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 3 compact summary pills
            HStack(spacing: 8) {
                miniStat(
                    title: "在线主机",
                    value: "\(store.onlineHostCount)/\(store.monitoredHostStates.count)",
                    color: .primary
                )
                miniStat(
                    title: "空闲 GPU",
                    value: "\(store.totalFreeGPUCount)/\(store.totalGPUCount)",
                    color: store.totalFreeGPUCount == 0 ? .secondary : .green
                )
                miniStat(
                    title: store.allOnlineGPUs.isEmpty && !store.onlineSlurmHosts.isEmpty ? "Slurm 作业" : "平均算力",
                    value: store.allOnlineGPUs.isEmpty && !store.onlineSlurmHosts.isEmpty
                        ? "\(store.allSlurmJobs.filter { $0.job.state.isRunning }.count)R / \(store.allSlurmJobs.filter { $0.job.state.isPending }.count)PD"
                        : Formatters.percent(store.allOnlineGPUs.isEmpty ? nil : store.averageClusterGPUUtilization),
                    color: store.allOnlineGPUs.isEmpty && !store.onlineSlurmHosts.isEmpty
                        ? .purple
                        : GTopTheme.utilizationColor(store.averageClusterGPUUtilization)
                )
            }

            Divider()

            if store.monitoredHostStates.isEmpty {
                VStack(spacing: 6) {
                    Text("暂无监控中的服务器")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("打开主窗口配置规则") {
                        openMainWindow(.overview)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.monitoredHostStates) { host in
                            Button {
                                openMainWindow(.host(host.config.alias))
                            } label: {
                                HStack(spacing: 8) {
                                    StatusDot(status: host.status, size: 7)

                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(host.config.alias)
                                                .font(.callout.weight(.medium))
                                                .lineLimit(1)
                                            if host.isSlurmCluster {
                                                BadgePill(text: "Slurm", color: .purple)
                                            }
                                        }
                                        if let slurm = host.slurm, host.status.isOnline {
                                            Text("空闲 \(slurm.freeGPUs)/\(slurm.totalGPUs) 卡 · \(slurm.runningJobs.count)R/\(slurm.pendingJobs.count)PD")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        } else if host.status.isOnline {
                                            Text("显存 \(Formatters.percent(host.memoryPercent)) · 空闲 \(host.idleGPUs(threshold: store.settings.idleThreshold).count)/\(host.gpus.count)")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text(host.status.label)
                                                .font(.caption2)
                                                .foregroundStyle(host.status.errorDetail != nil ? .red : .secondary)
                                        }
                                    }

                                    Spacer()

                                    if let slurm = host.slurm, host.status.isOnline {
                                        Text(Formatters.percent(slurm.allocationPercent))
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(.purple)
                                    } else if host.status.isOnline && !host.gpus.isEmpty {
                                        MiniGPUHeatBars(gpus: host.gpus, maxHeight: 16, barWidth: 4)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()

            // Footer buttons
            HStack(spacing: 8) {
                Button {
                    openMainWindow(.overview)
                } label: {
                    Label("打开主窗口", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    Task { await store.refreshAllNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("立即刷新全部主机")

                Button {
                    store.togglePause()
                } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                }
                .controlSize(.small)
                .help(store.isPaused ? "恢复监控" : "暂停监控")

                Spacer()

                Button("退出") {
                    store.shutdown()
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 350)
    }

    private func miniStat(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
