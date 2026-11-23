import GTopCore
import SwiftUI

enum OverviewLayoutMode: String, CaseIterable, Identifiable {
    case cards = "主机卡片"
    case matrix = "GPU 矩阵"

    var id: String { rawValue }
}

struct ClusterOverviewView: View {
    @Bindable var store: ClusterMonitorStore
    let groupFilter: String?
    let searchText: String
    let onSelectDestination: (SidebarDestination) -> Void
    let onOpenRuleManager: () -> Void
    let onNotify: (String) -> Void

    @State private var layoutMode: OverviewLayoutMode = .cards
    @State private var quickFilterText: String = ""
    @State private var quickGroupName: String = "GPU 集群"
    @State private var onlyIdleMatrix: Bool = false

    private var scopedHosts: [HostMonitorState] {
        var hosts = store.monitoredHostStates
        if let groupFilter {
            hosts = hosts.filter { $0.effectiveGroup == groupFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            hosts = hosts.filter { host in
                host.config.alias.localizedCaseInsensitiveContains(query) ||
                (host.config.hostName?.localizedCaseInsensitiveContains(query) ?? false) ||
                host.effectiveGroup.localizedCaseInsensitiveContains(query) ||
                host.gpus.contains(where: { $0.name.localizedCaseInsensitiveContains(query) }) ||
                host.activeUsers.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
                (host.slurm?.nodes.contains(where: {
                    $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.gpuType.localizedCaseInsensitiveContains(query)
                }) ?? false) ||
                (host.slurm?.partitions.contains(where: { $0.name.localizedCaseInsensitiveContains(query) }) ?? false) ||
                (host.slurm?.jobs.contains(where: {
                    $0.user.localizedCaseInsensitiveContains(query) ||
                    $0.name.localizedCaseInsensitiveContains(query)
                }) ?? false)
            }
        }
        return hosts
    }

    private var onlineScopedHosts: [HostMonitorState] {
        scopedHosts.filter { $0.status.isOnline }
    }

    private var scopedSlurmHosts: [HostMonitorState] {
        onlineScopedHosts.filter(\.isSlurmCluster)
    }

    private var scopedGPUs: [(host: HostMonitorState, gpu: GPUMetric)] {
        onlineScopedHosts.flatMap { host in
            host.gpus.map { (host: host, gpu: $0) }
        }
    }

    private var scopedSlurmTotalGPUs: Int {
        scopedSlurmHosts.reduce(0) { $0 + ($1.slurm?.totalGPUs ?? 0) }
    }

    private var scopedSlurmFreeGPUs: Int {
        scopedSlurmHosts.reduce(0) { $0 + ($1.slurm?.freeGPUs ?? 0) }
    }

    private var scopedSlurmAllocGPUs: Int {
        scopedSlurmHosts.reduce(0) { $0 + ($1.slurm?.allocatedGPUs ?? 0) }
    }

    private var scopedTotalCombinedGPUs: Int {
        scopedGPUs.count + scopedSlurmTotalGPUs
    }

    private var scopedIdleCount: Int {
        scopedGPUs.filter { $0.gpu.isIdle(threshold: store.settings.idleThreshold) }.count + scopedSlurmFreeGPUs
    }

    private var scopedSlurmRunningJobs: Int {
        scopedSlurmHosts.reduce(0) { $0 + ($1.slurm?.runningJobs.count ?? 0) }
    }

    private var scopedSlurmPendingJobs: Int {
        scopedSlurmHosts.reduce(0) { $0 + ($1.slurm?.pendingJobs.count ?? 0) }
    }

    private var scopedAvgUtil: Double {
        let utils = scopedGPUs.compactMap(\.gpu.gpuUtilization)
        guard !utils.isEmpty else { return 0 }
        return utils.reduce(0, +) / Double(utils.count)
    }

    private var scopedMemUsedMiB: Double {
        scopedGPUs.compactMap(\.gpu.memoryUsedMiB).reduce(0, +)
    }

    private var scopedMemTotalMiB: Double {
        scopedGPUs.compactMap(\.gpu.memoryTotalMiB).reduce(0, +)
    }

    private var scopedMemPercent: Double {
        guard scopedMemTotalMiB > 0 else { return 0 }
        return (scopedMemUsedMiB / scopedMemTotalMiB) * 100.0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = store.configError, !store.isDemoMode {
                    configErrorBanner(error)
                }

                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(groupFilter ?? "集群总览")
                            .font(.title2.weight(.bold))
                        Text(subtitleText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !scopedHosts.isEmpty {
                        Picker("布局", selection: $layoutMode) {
                            ForEach(OverviewLayoutMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }

                // KPI Strip
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                    spacing: 12
                ) {
                    KPICard(
                        title: "在线主机",
                        value: "\(onlineScopedHosts.count) / \(scopedHosts.count)",
                        subtitle: avgLatencyLabel,
                        icon: "server.rack",
                        accent: .green,
                        progress: scopedHosts.isEmpty ? 0 : Double(onlineScopedHosts.count) / Double(scopedHosts.count)
                    )

                    Button {
                        onSelectDestination(.idleGPUs)
                    } label: {
                        KPICard(
                            title: "空闲 GPU",
                            value: "\(scopedIdleCount) / \(scopedTotalCombinedGPUs)",
                            subtitle: scopedSlurmTotalGPUs > 0
                                ? "直连 \(scopedGPUs.filter { $0.gpu.isIdle(threshold: store.settings.idleThreshold) }.count) + Slurm \(scopedSlurmFreeGPUs) · 点击发现"
                                : "阈值 ≤ \(Int(store.settings.idleThreshold.maxGPUUtilization))% 算力 · 点击筛选",
                            icon: "sparkles",
                            accent: .green,
                            progress: scopedTotalCombinedGPUs == 0 ? 0 : Double(scopedIdleCount) / Double(scopedTotalCombinedGPUs)
                        )
                    }
                    .buttonStyle(.plain)

                    if scopedGPUs.isEmpty && scopedSlurmTotalGPUs > 0 {
                        let allocPct = Double(scopedSlurmAllocGPUs) / Double(scopedSlurmTotalGPUs) * 100.0
                        KPICard(
                            title: "Slurm GPU 分配率",
                            value: Formatters.percent(allocPct),
                            subtitle: "已分配 \(scopedSlurmAllocGPUs) / \(scopedSlurmTotalGPUs) 卡",
                            icon: "cpu",
                            accent: .purple,
                            progress: allocPct / 100.0
                        )

                        Button {
                            onSelectDestination(.slurmJobs)
                        } label: {
                            KPICard(
                                title: "Slurm 作业队列",
                                value: "\(scopedSlurmRunningJobs) R / \(scopedSlurmPendingJobs) PD",
                                subtitle: "我的作业 \(store.mySlurmJobCount) 个 · 点击查看队列",
                                icon: "square.stack.3d.up",
                                accent: .purple
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        KPICard(
                            title: "直连平均算力",
                            value: Formatters.percent(scopedGPUs.isEmpty ? nil : scopedAvgUtil),
                            subtitle: scopedSlurmTotalGPUs > 0
                                ? "Slurm 作业 \(scopedSlurmRunningJobs)R/\(scopedSlurmPendingJobs)PD · 直连 \(onlineScopedHosts.reduce(0) { $0 + $1.allProcesses.count }) 进程"
                                : "活跃进程 \(onlineScopedHosts.reduce(0) { $0 + $1.allProcesses.count }) 个",
                            icon: "cpu",
                            accent: GTopTheme.utilizationColor(scopedAvgUtil),
                            progress: scopedAvgUtil / 100.0
                        )

                        KPICard(
                            title: "直连总显存占用",
                            value: Formatters.percent(scopedMemTotalMiB > 0 ? scopedMemPercent : nil),
                            subtitle: Formatters.memoryPair(usedMiB: scopedMemUsedMiB, totalMiB: scopedMemTotalMiB),
                            icon: "memorychip",
                            accent: GTopTheme.memoryColor(scopedMemPercent),
                            progress: scopedMemPercent / 100.0
                        )
                    }
                }

                if scopedHosts.isEmpty {
                    emptyStateView
                } else if layoutMode == .cards {
                    hostCardsGrid
                } else {
                    gpuMatrixTable
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var subtitleText: String {
        if store.isDemoMode {
            return "演示模式运行中（未连接真实 SSH 主机） · 刷新周期 \(Int(store.settings.refreshIntervalSeconds))s"
        }
        let parsed = store.allHosts.count
        let monitored = store.monitoredHostStates.count
        let path = store.settings.sshConfigPath
        return "来自 \(path) · 共解析 \(parsed) 台主机，当前规则匹配 \(monitored) 台"
    }

    private var avgLatencyLabel: String {
        let latencies = onlineScopedHosts.compactMap(\.latencyMs)
        guard !latencies.isEmpty else { return "等待首次探测…" }
        let avg = latencies.reduce(0, +) / latencies.count
        return "平均采集耗时 \(avg) ms"
    }

    private func configErrorBanner(_ error: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("SSH 配置读取异常")
                    .font(.subheadline.weight(.semibold))
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("配置路径") { onOpenRuleManager() }
            Button("演示模式") { store.toggleDemoMode() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3)))
    }

    // MARK: - Host Cards Grid

    private var hostCardsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 420, maximum: 680), spacing: 14)],
            spacing: 14
        ) {
            ForEach(scopedHosts) { host in
                HostOverviewCard(
                    host: host,
                    idleThreshold: store.settings.idleThreshold,
                    onOpenHost: { onSelectDestination(.host(host.config.alias)) },
                    onRefresh: { Task { await store.refreshHost(host.config.alias) } },
                    onDisable: {
                        store.setHostSelected(host.config.alias, selected: false)
                        onNotify("已取消监控：\(host.config.alias)")
                    },
                    onCopySSH: {
                        let cmd = "ssh \(host.config.alias)"
                        SystemActions.copyToClipboard(cmd)
                        onNotify("已复制：\(cmd)")
                    }
                )
            }
        }
    }

    // MARK: - Dense GPU Matrix

    private var gpuMatrixTable: some View {
        let rows = scopedGPUs.filter { item in
            !onlyIdleMatrix || item.gpu.isIdle(threshold: store.settings.idleThreshold)
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全部在线 GPU 矩阵（\(rows.count) 张）")
                    .font(.headline)
                Spacer()
                Toggle("仅看空闲 GPU", isOn: $onlyIdleMatrix)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("主机 / GPU").frame(width: 190, alignment: .leading)
                    Text("型号").frame(width: 150, alignment: .leading)
                    Text("算力").frame(width: 105, alignment: .leading)
                    Text("显存").frame(width: 165, alignment: .leading)
                    Text("温度").frame(width: 55, alignment: .trailing)
                    Text("功耗").frame(width: 90, alignment: .trailing)
                    Text("风扇").frame(width: 50, alignment: .trailing)
                    Text("占用用户 / 进程").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))

                Divider()

                ForEach(rows, id: \.gpu.id) { item in
                    let isIdle = item.gpu.isIdle(threshold: store.settings.idleThreshold)
                    Button {
                        onSelectDestination(.host(item.host.config.alias))
                    } label: {
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(isIdle ? Color.green : GTopTheme.utilizationColor(item.gpu.gpuUtilization))
                                    .frame(width: 7, height: 7)
                                Text(item.host.config.alias)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text("#\(item.gpu.index)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 190, alignment: .leading)

                            Text(item.gpu.shortName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)

                            HStack(spacing: 6) {
                                MetricProgressBar(
                                    fraction: (item.gpu.gpuUtilization ?? 0) / 100.0,
                                    tint: GTopTheme.utilizationColor(item.gpu.gpuUtilization),
                                    height: 6
                                )
                                Text(Formatters.percent(item.gpu.gpuUtilization))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .frame(width: 105, alignment: .leading)

                            HStack(spacing: 6) {
                                MetricProgressBar(
                                    fraction: item.gpu.memoryPercent / 100.0,
                                    tint: GTopTheme.memoryColor(item.gpu.memoryPercent),
                                    height: 6
                                )
                                Text(Formatters.memoryPair(usedMiB: item.gpu.memoryUsedMiB, totalMiB: item.gpu.memoryTotalMiB))
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: 96, alignment: .trailing)
                            }
                            .frame(width: 165, alignment: .leading)

                            Text(Formatters.temperature(item.gpu.temperatureC))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(GTopTheme.temperatureColor(item.gpu.temperatureC))
                                .frame(width: 55, alignment: .trailing)

                            Text(Formatters.power(draw: item.gpu.powerDrawW, limit: item.gpu.powerLimitW))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)

                            Text(Formatters.percent(item.gpu.fanSpeedPercent))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)

                            Group {
                                if item.gpu.processes.isEmpty {
                                    Text(isIdle ? "空闲" : "—")
                                        .font(.caption)
                                        .foregroundStyle(isIdle ? .green : .secondary)
                                } else {
                                    let users = Array(Set(item.gpu.processes.map(\.user))).sorted().joined(separator: ", ")
                                    Text("\(users) (\(item.gpu.processes.count))")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

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

    // MARK: - Onboarding / Direct Host Selection State

    private var emptyStateView: some View {
        let parsedHosts = store.allHosts
        let filterTrimmed = quickFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredHosts: [SSHHostConfig] = {
            guard !filterTrimmed.isEmpty else { return parsedHosts }
            let engine = FilterRuleEngine()
            let mode: RuleMatchMode = (filterTrimmed.contains("*") || filterTrimmed.contains("?")) ? .glob : .contains
            let probeRule = HostFilterRule(
                name: "preview",
                isEnabled: true,
                action: .include,
                field: .any,
                mode: mode,
                pattern: filterTrimmed
            )
            return parsedHosts.filter { engine.matches(rule: probeRule, host: $0) }
        }()

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(parsedHosts.isEmpty ? "尚未发现 SSH 主机" : "已从 \(store.settings.sshConfigPath) 解析到 \(parsedHosts.count) 台主机")
                        .font(.headline)
                    Text("默认不会自动连接任何服务器——只有在下方勾选你选中的主机（或在规则管理器中开启自动规则）后才会发起 SSH 监控。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !parsedHosts.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("搜索或输入通配符筛选（如 gpu 或 *a100*,*4090*）…", text: $quickFilterText)
                            .textFieldStyle(.roundedBorder)

                        Button("勾选筛选结果 (\(filteredHosts.count))") {
                            store.setHostsSelected(filteredHosts.map(\.alias), selected: true)
                            onNotify("已选中并开始监控 \(filteredHosts.count) 台主机")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(filteredHosts.isEmpty)

                        if !filterTrimmed.isEmpty {
                            Button("保存为自动规则") {
                                let mode: RuleMatchMode = (filterTrimmed.contains("*") || filterTrimmed.contains("?")) ? .glob : .contains
                                store.addQuickIncludeRule(
                                    name: "包含：\(filterTrimmed)",
                                    pattern: filterTrimmed,
                                    group: quickGroupName,
                                    mode: mode
                                )
                                onNotify("已保存自动包含规则，命中 \(filteredHosts.count) 台主机")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Direct host checklist
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredHosts) { host in
                                let isSelected = store.hostStates[host.alias]?.isMonitored ?? false
                                HStack(spacing: 10) {
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { isSelected },
                                            set: { newVal in
                                                store.setHostSelected(host.alias, selected: newVal)
                                            }
                                        )
                                    )
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(host.alias)
                                            .font(.callout.weight(.semibold))
                                        Text(host.connectionSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if let jump = host.proxyJump {
                                        BadgePill(text: "跳板: \(jump)", color: .secondary, icon: "arrow.triangle.branch")
                                    }

                                    if let grp = host.commentGroup {
                                        BadgePill(text: grp, color: .blue)
                                    }

                                    Text(host.sourceFileName)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                                .onTapGesture {
                                    store.toggleHostSelection(host.alias)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    onOpenRuleManager()
                } label: {
                    Label("打开规则与分组管理", systemImage: "slider.horizontal.3")
                }

                Button {
                    store.reloadSSHConfig()
                } label: {
                    Label("重新读取 ~/.ssh/config", systemImage: "arrow.clockwise")
                }

                Spacer()

                Button {
                    store.toggleDemoMode()
                } label: {
                    Label(store.isDemoMode ? "退出演示模式" : "体验演示集群数据", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }
}

// MARK: - Host Overview Card

private struct HostOverviewCard: View {
    let host: HostMonitorState
    let idleThreshold: IdleThreshold
    let onOpenHost: () -> Void
    let onRefresh: () -> Void
    let onDisable: () -> Void
    let onCopySSH: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card Header
            HStack(alignment: .top, spacing: 8) {
                StatusDot(status: host.status, size: 9)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(host.config.alias)
                            .font(.headline)
                            .lineLimit(1)

                        if host.isSlurmCluster {
                            BadgePill(text: "Slurm", color: .purple, icon: "square.stack.3d.up")
                        }

                        BadgePill(text: host.effectiveGroup, color: .blue)

                        let idleCount = host.slurm?.freeGPUs ?? host.idleGPUs(threshold: idleThreshold).count
                        if host.status.isOnline && idleCount > 0 {
                            BadgePill(text: "\(idleCount) 空闲", color: .green, icon: "sparkles")
                        }
                    }

                    HStack(spacing: 8) {
                        Text(host.config.connectionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let jump = host.config.proxyJump {
                            Label(jump, systemImage: "arrow.triangle.branch")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if let ms = host.latencyMs, host.status.isOnline {
                        Text("\(ms)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Button(action: onCopySSH) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("复制 ssh \(host.config.alias)")

                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("立即刷新此主机")
                }
            }

            if let slurm = host.slurm, host.status.isOnline {
                // Slurm Cluster Overview Body
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Slurm 集群 · \(slurm.gpuNodes.count) 个 GPU 节点 · 共 \(slurm.totalGPUs) 卡")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            Label("已分配 \(slurm.allocatedGPUs)/\(slurm.totalGPUs)", systemImage: "cpu")
                            Label("运行 \(slurm.runningJobs.count) · 排队 \(slurm.pendingJobs.count)", systemImage: "list.bullet.rectangle")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    MiniSparkline(
                        samples: host.hostHistory,
                        tint: .purple
                    )
                    .frame(width: 96, height: 28)
                }

                // Partition pills
                if !slurm.partitions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(slurm.partitions.prefix(5)) { part in
                                BadgePill(
                                    text: "\(part.name): \(part.freeGPUs)/\(part.totalGPUs) 空",
                                    color: part.freeGPUs > 0 ? .green : .secondary
                                )
                            }
                        }
                    }
                }

                Divider()

                // Top GPU compute nodes compact preview
                VStack(spacing: 6) {
                    ForEach(slurm.gpuNodes.prefix(6)) { node in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(GTopTheme.slurmNodeColor(node.stateCategory))
                                .frame(width: 7, height: 7)
                            Text(node.name)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .frame(width: 100, alignment: .leading)
                            Text(node.gpuType)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 58, alignment: .leading)
                            MetricProgressBar(
                                fraction: node.gpuAllocationPercent / 100.0,
                                tint: node.hasFreeGPUs ? .blue : GTopTheme.slurmNodeColor(node.stateCategory),
                                height: 6
                            )
                            Text("\(node.allocatedGPUs)/\(node.totalGPUs)")
                                .font(.caption2.monospacedDigit())
                                .frame(width: 34, alignment: .trailing)
                            Text(node.hasFreeGPUs ? "\(node.freeGPUs) 空" : node.stateCategory.displayName)
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(node.hasFreeGPUs ? .green : .secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    if slurm.gpuNodes.count > 6 {
                        Text("还有 \(slurm.gpuNodes.count - 6) 个 GPU 计算节点…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                HStack(spacing: 6) {
                    if !slurm.myJobs.isEmpty {
                        BadgePill(text: "我的作业 \(slurm.myJobs.count)", color: .purple, icon: "person.fill")
                    }
                    Spacer()
                    Text("点击查看完整分区 / 节点 / 作业看板 →")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            } else if host.status.isOnline {
                // Summary Strip + Mini Sparkline
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(host.gpus.count) × \(host.gpus.first?.shortName ?? "GPU")")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            Label(Formatters.percent(host.averageGPUUtilization), systemImage: "cpu")
                            Label(Formatters.memoryPair(usedMiB: host.totalMemoryUsedMiB, totalMiB: host.totalMemoryTotalMiB), systemImage: "memorychip")
                            if let maxT = host.maxTemperatureC {
                                Label(Formatters.temperature(maxT), systemImage: "thermometer.medium")
                                    .foregroundStyle(GTopTheme.temperatureColor(maxT))
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    MiniSparkline(
                        samples: host.hostHistory,
                        tint: GTopTheme.utilizationColor(host.averageGPUUtilization)
                    )
                    .frame(width: 96, height: 28)
                }

                Divider()

                // Compact Per-GPU Rows
                VStack(spacing: 6) {
                    ForEach(host.gpus) { gpu in
                        let isIdle = gpu.isIdle(threshold: idleThreshold)
                        HStack(spacing: 8) {
                            Text("GPU \(gpu.index)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isIdle ? .green : .primary)
                                .frame(width: 40, alignment: .leading)

                            // GPU Util bar
                            HStack(spacing: 4) {
                                MetricProgressBar(
                                    fraction: (gpu.gpuUtilization ?? 0) / 100.0,
                                    tint: GTopTheme.utilizationColor(gpu.gpuUtilization),
                                    height: 6
                                )
                                Text(Formatters.percent(gpu.gpuUtilization))
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: 30, alignment: .trailing)
                            }
                            .frame(minWidth: 85)

                            // VRAM bar
                            HStack(spacing: 4) {
                                MetricProgressBar(
                                    fraction: gpu.memoryPercent / 100.0,
                                    tint: GTopTheme.memoryColor(gpu.memoryPercent),
                                    height: 6
                                )
                                Text(Formatters.memoryMiB(gpu.memoryUsedMiB))
                                    .font(.caption2.monospacedDigit())
                                    .frame(width: 54, alignment: .trailing)
                            }
                            .frame(minWidth: 105)

                            Text(Formatters.temperature(gpu.temperatureC))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(GTopTheme.temperatureColor(gpu.temperatureC))
                                .frame(width: 36, alignment: .trailing)

                            Text(gpu.powerDrawW.map { String(format: "%.0fW", $0) } ?? "—")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                // Active users / footer
                if !host.activeUsers.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(host.activeUsers.prefix(5), id: \.self) { user in
                            BadgePill(text: user, color: .secondary)
                        }
                        if host.activeUsers.count > 5 {
                            Text("+\(host.activeUsers.count - 5)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(host.allProcesses.count) 进程 · 查看详情 →")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            } else {
                // Non-online status card body
                HStack(spacing: 10) {
                    if case .connecting = host.status {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在通过 SSH 连接并采集 nvidia-smi…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if case .error(let msg) = host.status {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    } else if case .noGPU = host.status {
                        Image(systemName: "cpu")
                            .foregroundStyle(.orange)
                        Text("未检测到 NVIDIA GPU 或 nvidia-smi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(host.status.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("取消监控", action: onDisable)
                        .controlSize(.small)
                }
                .padding(.vertical, 12)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    host.status.errorDetail != nil
                        ? Color.red.opacity(0.28)
                        : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(perform: onOpenHost)
    }
}
