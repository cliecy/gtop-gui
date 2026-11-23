import GTopCore
import SwiftUI

struct SlurmJobsView: View {
    @Bindable var store: ClusterMonitorStore
    let searchText: String
    let onSelectHost: (String) -> Void
    let onNotify: (String) -> Void

    @State private var filterMode: SlurmJobFilterMode = .all
    @State private var selectedUser: String? = nil
    @State private var liveProbeTarget: SlurmLiveProbeTarget? = nil

    private var allItems: [(host: HostMonitorState, job: SlurmJobMetric)] {
        store.allSlurmJobs
    }

    private var userLeaderboard: [SlurmUserUsage] {
        let grouped = Dictionary(grouping: allItems, by: { $0.job.user })
        return grouped.map { user, entries in
            let running = entries.filter { $0.job.state.isRunning }
            let pending = entries.filter { $0.job.state.isPending }
            return SlurmUserUsage(
                user: user,
                runningGPUs: running.reduce(0) { $0 + $1.job.gpuCount },
                pendingGPUs: pending.reduce(0) { $0 + $1.job.gpuCount },
                runningJobs: running.count,
                pendingJobs: pending.count
            )
        }
        .sorted {
            if $0.runningGPUs != $1.runningGPUs { return $0.runningGPUs > $1.runningGPUs }
            return $0.pendingGPUs > $1.pendingGPUs
        }
    }

    private var filteredItems: [(host: HostMonitorState, job: SlurmJobMetric)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allItems.filter { item in
            let currentUser = item.host.slurm?.currentUser ?? item.host.remoteUsername
            switch filterMode {
            case .all: break
            case .mine: if !item.job.isOwnedBy(currentUser) { return false }
            case .running: if !item.job.state.isRunning { return false }
            case .pending: if !item.job.state.isPending { return false }
            }
            if let selectedUser, item.job.user != selectedUser { return false }
            guard !q.isEmpty else { return true }
            return item.host.config.alias.localizedCaseInsensitiveContains(q) ||
                item.job.jobID.localizedCaseInsensitiveContains(q) ||
                item.job.user.localizedCaseInsensitiveContains(q) ||
                item.job.name.localizedCaseInsensitiveContains(q) ||
                item.job.partition.localizedCaseInsensitiveContains(q) ||
                item.job.nodeListRaw.localizedCaseInsensitiveContains(q) ||
                item.job.reason.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Slurm 全局作业队列")
                            .font(.title2.weight(.bold))
                        Text("汇总 \(store.onlineSlurmHosts.count) 个在线 Slurm 集群的作业（共 \(filteredItems.count) 个）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("状态", selection: $filterMode) {
                        Text("全部 (\(allItems.count))").tag(SlurmJobFilterMode.all)
                        Text("我的作业 (\(store.mySlurmJobCount))").tag(SlurmJobFilterMode.mine)
                        Text("运行中").tag(SlurmJobFilterMode.running)
                        Text("排队中").tag(SlurmJobFilterMode.pending)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 400)
                }

                if !userLeaderboard.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                selectedUser = nil
                            } label: {
                                Text("全部用户")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        selectedUser == nil ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)

                            ForEach(userLeaderboard) { agg in
                                let active = selectedUser == agg.user
                                Button {
                                    selectedUser = active ? nil : agg.user
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "person.fill").font(.caption2)
                                        Text(agg.user).fontWeight(.semibold)
                                        Text("\(agg.runningGPUs) 卡\(agg.pendingGPUs > 0 ? " · +\(agg.pendingGPUs) PD" : "")")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                                        in: Capsule()
                                    )
                                    .overlay(Capsule().strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "暂无 Slurm 作业",
                        systemImage: "list.bullet.rectangle.portrait",
                        description: Text(store.onlineSlurmHosts.isEmpty
                            ? "选中并连接任意 Slurm 登录节点后，这里会自动汇总集群队列作业。"
                            : "当前没有符合筛选条件的作业。")
                    )
                    .padding(.vertical, 48)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("集群 / JobID").frame(width: 175, alignment: .leading)
                            Text("状态").frame(width: 66, alignment: .leading)
                            Text("用户").frame(width: 90, alignment: .leading)
                            Text("作业名").frame(width: 155, alignment: .leading)
                            Text("分区").frame(width: 82, alignment: .leading)
                            Text("GPU").frame(width: 78, alignment: .leading)
                            Text("时长").frame(width: 82, alignment: .trailing)
                            Text("节点 / 原因 & 操作").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.04))

                        Divider()

                        ForEach(filteredItems, id: \.job.id) { item in
                            slurmJobRow(host: item.host, job: item.job)
                            Divider()
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $liveProbeTarget) { target in
            SlurmNodeLiveGPUView(store: store, target: target, onNotify: onNotify)
        }
    }

    private func slurmJobRow(host: HostMonitorState, job: SlurmJobMetric) -> some View {
        let currentUser = host.slurm?.currentUser ?? host.remoteUsername
        let isMine = job.isOwnedBy(currentUser)
        let gpuLabel = job.gpuCount > 0 ? "\(job.gpuCount) \(job.gpuType ?? "GPU")" : "CPU"

        return HStack(spacing: 10) {
            Button {
                onSelectHost(host.config.alias)
            } label: {
                HStack(spacing: 5) {
                    Text(host.config.alias)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("#\(job.jobID)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 175, alignment: .leading)

            BadgePill(
                text: job.state.shortLabel,
                color: GTopTheme.slurmJobColor(job.state)
            )
            .frame(width: 66, alignment: .leading)

            HStack(spacing: 4) {
                Text(job.user)
                    .font(.caption.weight(isMine ? .bold : .medium))
                    .lineLimit(1)
                if isMine {
                    BadgePill(text: "我", color: .purple)
                }
            }
            .frame(width: 90, alignment: .leading)

            Text(job.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 155, alignment: .leading)

            Text(job.partition)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)

            Text(gpuLabel)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(job.gpuCount > 0 ? Color.indigo : Color.secondary)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)

            Text(job.elapsedTime)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .trailing)

            HStack(spacing: 6) {
                Text(job.state.isRunning ? job.nodeListRaw : job.reason)
                    .font(job.state.isRunning ? .system(.caption, design: .monospaced) : .caption)
                    .foregroundStyle(job.state.isRunning ? Color.primary : Color.orange)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if job.state.isRunning, let node = job.primaryNode, job.gpuCount > 0 {
                    Button {
                        liveProbeTarget = SlurmLiveProbeTarget(
                            loginAlias: host.config.alias,
                            nodeName: node,
                            jobID: job.jobID,
                            subtitle: job.name
                        )
                    } label: {
                        Label("实时 GPU", systemImage: "waveform.path.ecg")
                            .font(.caption2)
                    }
                    .controlSize(.small)
                }

                Button {
                    let cmd = "scontrol show job \(job.jobID)"
                    SystemActions.copyToClipboard(cmd)
                    onNotify("已复制：\(cmd)")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("复制 scontrol show job \(job.jobID)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isMine ? Color.purple.opacity(0.05) : Color.clear)
    }
}
