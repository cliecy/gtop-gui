import Charts
import GTopCore
import SwiftUI

enum SlurmDetailTab: String, CaseIterable, Identifiable {
    case nodes = "分区与计算节点"
    case jobs = "作业队列 (squeue)"
    case trend = "分配率趋势"

    var id: String { rawValue }
}

enum SlurmJobFilterMode: String, CaseIterable, Identifiable {
    case all = "全部"
    case mine = "我的作业"
    case running = "运行中"
    case pending = "排队中"

    var id: String { rawValue }
}

struct SlurmHostDetailView: View {
    @Bindable var store: ClusterMonitorStore
    let host: HostMonitorState
    let slurm: SlurmClusterSnapshot
    let onNotify: (String) -> Void

    @State private var activeTab: SlurmDetailTab = .nodes
    @State private var selectedPartition: String? = nil
    @State private var onlyFreeNodes: Bool = false
    @State private var nodeSearch: String = ""

    @State private var jobFilterMode: SlurmJobFilterMode = .all
    @State private var selectedUserFilter: String? = nil
    @State private var jobSearch: String = ""

    @State private var liveProbeTarget: SlurmLiveProbeTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Slurm Cluster KPI Strip
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                spacing: 12
            ) {
                KPICard(
                    title: "集群空闲 GPU",
                    value: "\(slurm.freeGPUs) / \(slurm.totalGPUs)",
                    subtitle: "已分配 \(slurm.allocatedGPUs) 卡 · \(slurm.freeGPUNodes.count) 个节点有余卡",
                    icon: "sparkles",
                    accent: .green,
                    progress: slurm.totalGPUs > 0 ? Double(slurm.freeGPUs) / Double(slurm.totalGPUs) : 0
                )

                KPICard(
                    title: "GPU 分配率",
                    value: Formatters.percent(slurm.totalGPUs > 0 ? slurm.allocationPercent : nil),
                    subtitle: "GPU 计算节点 \(slurm.gpuNodes.count) 台（共 \(slurm.nodes.count) 节点）",
                    icon: "cpu",
                    accent: GTopTheme.utilizationColor(slurm.allocationPercent),
                    progress: slurm.allocationPercent / 100.0
                )

                KPICard(
                    title: "作业队列",
                    value: "\(slurm.runningJobs.count) R / \(slurm.pendingJobs.count) PD",
                    subtitle: "我的作业：\(slurm.myJobs.count)（\(slurm.myRunningJobs.count) 运行中）",
                    icon: "list.bullet.rectangle.portrait",
                    accent: .purple
                )

                KPICard(
                    title: "活跃分区",
                    value: "\(slurm.partitions.count) 个分区",
                    subtitle: "登录用户：\(slurm.currentUser ?? host.config.user ?? "—")",
                    icon: "square.stack.3d.up",
                    accent: .blue
                )
            }

            // Tab Switcher
            HStack {
                Picker("视图", selection: $activeTab) {
                    ForEach(SlurmDetailTab.allCases) { tab in
                        Text(tabTitle(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)

                Spacer()

                if activeTab == .nodes {
                    Toggle("仅看有空闲 GPU", isOn: $onlyFreeNodes)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            }

            switch activeTab {
            case .nodes:
                nodesAndPartitionsSection
            case .jobs:
                jobsSection
            case .trend:
                allocationTrendSection
            }
        }
        .sheet(item: $liveProbeTarget) { target in
            SlurmNodeLiveGPUView(store: store, target: target, onNotify: onNotify)
        }
    }

    private func tabTitle(_ tab: SlurmDetailTab) -> String {
        switch tab {
        case .nodes: return "分区与节点 (\(slurm.gpuNodes.count))"
        case .jobs: return "作业队列 (\(slurm.jobs.count))"
        case .trend: return "分配率趋势"
        }
    }

    // MARK: - Tab 1: Partitions & Compute Nodes

    private var nodesAndPartitionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Partition cards strip
            if !slurm.partitions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        partitionChip(
                            title: "全部分区",
                            subtitle: "\(slurm.freeGPUs)/\(slurm.totalGPUs) 空闲",
                            detail: "\(slurm.gpuNodes.count) GPU 节点",
                            isDefault: false,
                            isSelected: selectedPartition == nil,
                            hasFree: slurm.freeGPUs > 0
                        ) {
                            selectedPartition = nil
                        }

                        ForEach(slurm.partitions) { part in
                            partitionChip(
                                title: part.name,
                                subtitle: "\(part.freeGPUs)/\(part.totalGPUs) 空闲",
                                detail: part.gpuTypes.isEmpty ? "\(part.totalNodes) 节点" : part.gpuTypes.joined(separator: "/"),
                                isDefault: part.isDefault,
                                isSelected: selectedPartition == part.name,
                                hasFree: part.freeGPUs > 0
                            ) {
                                selectedPartition = (selectedPartition == part.name) ? nil : part.name
                            }
                        }
                    }
                }
            }

            HStack {
                TextField("搜索计算节点名 / GPU 型号 / 分区…", text: $nodeSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Spacer()

                Text("点击「实时 nvidia-smi」可按需探测单台计算节点的利用率、显存、温度与进程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let filteredNodes = visibleNodes
            if filteredNodes.isEmpty {
                ContentUnavailableView(
                    "暂无匹配的计算节点",
                    systemImage: "server.rack",
                    description: Text("请调整分区筛选或取消「仅看有空闲 GPU」。")
                )
                .padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("计算节点").frame(width: 155, alignment: .leading)
                        Text("状态").frame(width: 90, alignment: .leading)
                        Text("GPU 型号").frame(width: 95, alignment: .leading)
                        Text("GPU 分配 (已用/总计)").frame(width: 165, alignment: .leading)
                        Text("CPU / Load").frame(width: 115, alignment: .leading)
                        Text("内存").frame(width: 115, alignment: .leading)
                        Text("运行中作业 / 操作").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04))

                    Divider()

                    ForEach(filteredNodes) { node in
                        nodeRow(node)
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
    }

    private var visibleNodes: [SlurmNodeMetric] {
        let q = nodeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return slurm.nodes.filter { node in
            if onlyFreeNodes && !node.hasFreeGPUs { return false }
            if let part = selectedPartition, !node.partitions.contains(part) { return false }
            guard !q.isEmpty else { return true }
            return node.name.localizedCaseInsensitiveContains(q) ||
                node.gpuType.localizedCaseInsensitiveContains(q) ||
                node.rawState.localizedCaseInsensitiveContains(q) ||
                node.partitions.contains(where: { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    private func nodeRow(_ node: SlurmNodeMetric) -> some View {
        let nodeJobs = slurm.runningJobs(onNode: node.name)
        let myJobOnNode = nodeJobs.first(where: { $0.isOwnedBy(slurm.currentUser) })

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(GTopTheme.slurmNodeColor(node.stateCategory))
                        .frame(width: 7, height: 7)
                    Text(node.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Text(node.partitions.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 155, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                BadgePill(
                    text: node.stateCategory.displayName,
                    color: GTopTheme.slurmNodeColor(node.stateCategory)
                )
                if let reason = node.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(reason)
                }
            }
            .frame(width: 90, alignment: .leading)

            Text(node.gpuType)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 95, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(node.allocatedGPUs) / \(node.totalGPUs)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                    Spacer()
                    if node.hasFreeGPUs {
                        Text("\(node.freeGPUs) 空闲")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.green)
                    } else if node.totalGPUs > 0 {
                        Text(node.stateCategory.isSchedulable ? "满载" : "不可调度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if node.totalGPUs > 0 {
                    MetricProgressBar(
                        fraction: node.gpuAllocationPercent / 100.0,
                        tint: node.hasFreeGPUs ? .blue : GTopTheme.slurmNodeColor(node.stateCategory),
                        height: 6
                    )
                }
            }
            .frame(width: 165, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(node.cpusAllocated)/\(node.cpusTotal) C")
                    .font(.caption2.monospacedDigit())
                if let load = node.cpuLoad {
                    Text(String(format: "Load %.1f", load))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 115, alignment: .leading)

            Text(Formatters.memoryPair(
                usedMiB: Double(node.memoryAllocatedMiB),
                totalMiB: Double(node.memoryTotalMiB)
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 115, alignment: .leading)

            HStack(spacing: 6) {
                if !nodeJobs.isEmpty {
                    let users = Array(Set(nodeJobs.map(\.user))).sorted()
                    ForEach(users.prefix(2), id: \.self) { user in
                        let isMe = slurm.currentUser?.caseInsensitiveCompare(user) == .orderedSame
                        BadgePill(
                            text: isMe ? "\(user)(我)" : user,
                            color: isMe ? .purple : .secondary
                        )
                    }
                    if users.count > 2 {
                        Text("+\(users.count - 2)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                if node.totalGPUs > 0 {
                    Button {
                        liveProbeTarget = SlurmLiveProbeTarget(
                            loginAlias: host.config.alias,
                            nodeName: node.name,
                            jobID: myJobOnNode?.jobID,
                            subtitle: node.gpuType
                        )
                    } label: {
                        Label("实时 nvidia-smi", systemImage: "waveform.path.ecg")
                            .font(.caption2)
                    }
                    .controlSize(.small)
                    .help(myJobOnNode != nil
                        ? "通过你的作业 #\(myJobOnNode!.jobID) 或 SSH 探测实时 nvidia-smi"
                        : "通过登录节点按需探测该计算节点的实时 nvidia-smi")
                }

                if node.hasFreeGPUs {
                    Button {
                        let cmd = node.suggestedSrunCommand(preferredPartition: selectedPartition)
                        SystemActions.copyToClipboard(cmd)
                        onNotify("已复制：\(cmd)")
                    } label: {
                        Label("复制 srun", systemImage: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("复制申请此空闲节点的 srun 交互命令")
                } else {
                    Button {
                        let cmd = "scontrol show node \(node.name)"
                        SystemActions.copyToClipboard(cmd)
                        onNotify("已复制：\(cmd)")
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("复制 scontrol show node \(node.name)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func partitionChip(
        title: String,
        subtitle: String,
        detail: String,
        isDefault: Bool,
        isSelected: Bool,
        hasFree: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    if isDefault {
                        BadgePill(text: "默认", color: .blue)
                    }
                }
                Text(subtitle)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(hasFree ? .green : .secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 2: Slurm Jobs (squeue)

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Controls row
            HStack(spacing: 10) {
                Picker("筛选", selection: $jobFilterMode) {
                    Text("全部 (\(slurm.jobs.count))").tag(SlurmJobFilterMode.all)
                    Text("我的作业 (\(slurm.myJobs.count))").tag(SlurmJobFilterMode.mine)
                    Text("运行中 (\(slurm.runningJobs.count))").tag(SlurmJobFilterMode.running)
                    Text("排队中 (\(slurm.pendingJobs.count))").tag(SlurmJobFilterMode.pending)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                Spacer()

                TextField("搜索 JobID / 用户 / 作业名 / 节点 / 原因…", text: $jobSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            // Per-user GPU usage leaderboard
            if !slurm.userSummaries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedUserFilter = nil
                        } label: {
                            Text("全部用户")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selectedUserFilter == nil ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(slurm.userSummaries) { agg in
                            let active = selectedUserFilter == agg.user
                            let isMe = slurm.currentUser?.caseInsensitiveCompare(agg.user) == .orderedSame
                            Button {
                                selectedUserFilter = active ? nil : agg.user
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: isMe ? "person.crop.circle.fill" : "person.fill")
                                        .font(.caption2)
                                        .foregroundStyle(isMe ? .purple : .secondary)
                                    Text(isMe ? "\(agg.user) (我)" : agg.user)
                                        .fontWeight(.semibold)
                                    Text("\(agg.runningGPUs) 卡\(agg.pendingGPUs > 0 ? " · +\(agg.pendingGPUs) 排队" : "")")
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

            let jobs = filteredJobs
            if jobs.isEmpty {
                ContentUnavailableView(
                    "暂无匹配的 Slurm 作业",
                    systemImage: "list.bullet.rectangle.portrait",
                    description: Text("当前队列为空，或没有符合筛选条件的作业。")
                )
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Job ID").frame(width: 78, alignment: .leading)
                        Text("状态").frame(width: 68, alignment: .leading)
                        Text("用户").frame(width: 95, alignment: .leading)
                        Text("作业名").frame(width: 155, alignment: .leading)
                        Text("分区").frame(width: 88, alignment: .leading)
                        Text("GPU").frame(width: 82, alignment: .leading)
                        Text("时长 / 限时").frame(width: 120, alignment: .trailing)
                        Text("节点 / 排队原因 & 操作").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04))

                    Divider()

                    ForEach(jobs) { job in
                        jobRow(job)
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
    }

    private var filteredJobs: [SlurmJobMetric] {
        let q = jobSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return slurm.jobs.filter { job in
            switch jobFilterMode {
            case .all: break
            case .mine: if !job.isOwnedBy(slurm.currentUser) { return false }
            case .running: if !job.state.isRunning { return false }
            case .pending: if !job.state.isPending { return false }
            }
            if let user = selectedUserFilter, job.user != user { return false }
            guard !q.isEmpty else { return true }
            return job.jobID.localizedCaseInsensitiveContains(q) ||
                job.user.localizedCaseInsensitiveContains(q) ||
                job.name.localizedCaseInsensitiveContains(q) ||
                job.partition.localizedCaseInsensitiveContains(q) ||
                job.nodeListRaw.localizedCaseInsensitiveContains(q) ||
                job.reason.localizedCaseInsensitiveContains(q)
        }
    }

    private func jobRow(_ job: SlurmJobMetric) -> some View {
        let isMine = job.isOwnedBy(slurm.currentUser)
        return HStack(spacing: 10) {
            Text(job.jobID)
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 78, alignment: .leading)

            BadgePill(
                text: job.state.shortLabel,
                color: GTopTheme.slurmJobColor(job.state)
            )
            .frame(width: 68, alignment: .leading)

            HStack(spacing: 4) {
                Text(job.user)
                    .font(.caption.weight(isMine ? .bold : .medium))
                    .lineLimit(1)
                if isMine {
                    BadgePill(text: "我", color: .purple)
                }
            }
            .frame(width: 95, alignment: .leading)

            Text(job.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(job.name)
                .frame(width: 155, alignment: .leading)

            Text(job.partition)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)

            Group {
                if job.gpuCount > 0 {
                    let suffix = job.gpuType.map { " \($0)" } ?? ""
                    Text("\(job.gpuCount)\(suffix)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.indigo)
                } else {
                    Text("CPU (\(job.numCPUs))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(width: 82, alignment: .leading)

            Text("\(job.elapsedTime) / \(job.timeLimit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .trailing)

            HStack(spacing: 6) {
                if job.state.isRunning {
                    Text(job.nodeListRaw)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .help(job.expandedNodes.joined(separator: ", "))
                } else {
                    Text(job.reason.isEmpty ? "等待调度" : job.reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if job.state.isRunning, let primaryNode = job.primaryNode, job.gpuCount > 0 {
                    Button {
                        liveProbeTarget = SlurmLiveProbeTarget(
                            loginAlias: host.config.alias,
                            nodeName: primaryNode,
                            jobID: job.jobID,
                            subtitle: "Job #\(job.jobID) · \(job.name)"
                        )
                    } label: {
                        Label("实时 GPU", systemImage: "waveform.path.ecg")
                            .font(.caption2)
                    }
                    .controlSize(.small)
                    .help("在节点 \(primaryNode) 探测此作业的实时 nvidia-smi")
                }

                Menu {
                    Button("复制 scontrol show job \(job.jobID)") {
                        let cmd = "scontrol show job \(job.jobID)"
                        SystemActions.copyToClipboard(cmd)
                        onNotify("已复制：\(cmd)")
                    }
                    if job.state.isRunning, let node = job.primaryNode {
                        Button("复制进入作业环境 srun --overlap") {
                            let cmd = "srun --jobid=\(job.jobID) --overlap --pty bash"
                            SystemActions.copyToClipboard(cmd)
                            onNotify("已复制：\(cmd)")
                        }
                        Button("复制查看节点 nvidia-smi 命令") {
                            let cmd = "srun --jobid=\(job.jobID) --overlap -w \(node) nvidia-smi"
                            SystemActions.copyToClipboard(cmd)
                            onNotify("已复制：\(cmd)")
                        }
                    }
                    Divider()
                    Button("复制取消作业命令 scancel \(job.jobID)") {
                        let cmd = "scancel \(job.jobID)"
                        SystemActions.copyToClipboard(cmd)
                        onNotify("已复制：\(cmd)")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isMine ? Color.purple.opacity(0.05) : Color.clear)
    }

    // MARK: - Tab 3: Cluster GPU Allocation History Trend

    private var allocationTrendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Slurm 集群 GPU 分配率实时曲线", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Text("当前已分配 \(slurm.allocatedGPUs) / \(slurm.totalGPUs) 卡 (\(Formatters.percent(slurm.allocationPercent)))")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.purple)
            }

            if host.hostHistory.count < 2 {
                ContentUnavailableView(
                    "正在积累历史采样点…",
                    systemImage: "chart.xyaxis.line",
                    description: Text("将在下一次刷新后绘制 Slurm 集群 GPU 分配率变化曲线。")
                )
                .frame(height: 240)
            } else {
                Chart(host.hostHistory) { pt in
                    AreaMark(
                        x: .value("时间", pt.timestamp),
                        y: .value("GPU 分配率", pt.gpuUtilization)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.32), Color.purple.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("时间", pt.timestamp),
                        y: .value("GPU 分配率", pt.gpuUtilization)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(.purple)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel(format: .dateTime.hour().minute().second()).font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel {
                            if let n = value.as(Double.self) {
                                Text("\(Int(n))%").font(.caption2).monospacedDigit()
                            }
                        }
                    }
                }
                .frame(height: 240)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
