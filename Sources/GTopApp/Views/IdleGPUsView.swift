import GTopCore
import SwiftUI

enum IdleGroupMode: String, CaseIterable, Identifiable {
    case byHost = "按服务器 / 集群"
    case byModel = "按 GPU 型号"

    var id: String { rawValue }
}

struct IdleGPUsView: View {
    @Bindable var store: ClusterMonitorStore
    let searchText: String
    let onSelectHost: (String) -> Void
    let onNotify: (String) -> Void

    @State private var groupMode: IdleGroupMode = .byHost
    @State private var liveProbeTarget: SlurmLiveProbeTarget? = nil

    private var filteredDirectIdle: [(host: HostMonitorState, gpu: GPUMetric)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.idleGPUs.filter { item in
            guard !q.isEmpty else { return true }
            return item.host.config.alias.localizedCaseInsensitiveContains(q) ||
                item.gpu.name.localizedCaseInsensitiveContains(q) ||
                item.host.effectiveGroup.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredSlurmFreeNodes: [(host: HostMonitorState, node: SlurmNodeMetric)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.slurmFreeNodes.filter { item in
            guard !q.isEmpty else { return true }
            return item.host.config.alias.localizedCaseInsensitiveContains(q) ||
                item.node.name.localizedCaseInsensitiveContains(q) ||
                item.node.gpuType.localizedCaseInsensitiveContains(q) ||
                item.node.partitions.contains(where: { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    private var totalFilteredFreeCount: Int {
        filteredDirectIdle.count + filteredSlurmFreeNodes.reduce(0) { $0 + $1.node.freeGPUs }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("空闲 GPU 发现")
                            .font(.title2.weight(.bold))
                        Text("当前共有 \(totalFilteredFreeCount) / \(store.totalGPUCount) 张空闲 GPU（直连 \(filteredDirectIdle.count) 张 · Slurm 可调度 \(filteredSlurmFreeNodes.reduce(0) { $0 + $1.node.freeGPUs }) 张）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("分组方式", selection: $groupMode) {
                        ForEach(IdleGroupMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }

                // Inline Threshold Bar for Direct GPU servers
                if !store.allOnlineGPUs.isEmpty {
                    thresholdControls
                }

                if filteredDirectIdle.isEmpty && filteredSlurmFreeNodes.isEmpty {
                    ContentUnavailableView(
                        "暂无符合条件的空闲 GPU",
                        systemImage: "sparkles",
                        description: Text("可以适当放宽直连服务器的算力/显存阈值，或检查 Slurm 集群与更多监控主机。")
                    )
                    .padding(.vertical, 48)
                } else {
                    if !filteredSlurmFreeNodes.isEmpty {
                        slurmFreeNodesSection
                    }

                    if !filteredDirectIdle.isEmpty {
                        if !filteredSlurmFreeNodes.isEmpty {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Label("直连服务器空闲 GPU（\(filteredDirectIdle.count) 张）", systemImage: "server.rack")
                                .font(.headline)

                            if groupMode == .byHost {
                                groupedByHostView
                            } else {
                                groupedByModelView
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $liveProbeTarget) { target in
            SlurmNodeLiveGPUView(store: store, target: target, onNotify: onNotify)
        }
    }

    // MARK: - Slurm Free Compute Nodes Section

    private var slurmFreeNodesSection: some View {
        let totalFree = filteredSlurmFreeNodes.reduce(0) { $0 + $1.node.freeGPUs }
        return VStack(alignment: .leading, spacing: 12) {
            Label("Slurm 集群空闲计算节点（共 \(totalFree) 张可调度空闲 GPU）", systemImage: "square.stack.3d.up")
                .font(.headline)

            if groupMode == .byHost {
                let grouped = Dictionary(grouping: filteredSlurmFreeNodes, by: { $0.host.config.alias })
                let sortedAliases = grouped.keys.sorted { lhs, rhs in
                    let lSum = (grouped[lhs] ?? []).reduce(0) { $0 + $1.node.freeGPUs }
                    let rSum = (grouped[rhs] ?? []).reduce(0) { $0 + $1.node.freeGPUs }
                    return lSum > rSum
                }

                ForEach(sortedAliases, id: \.self) { alias in
                    if let entries = grouped[alias], let host = entries.first?.host {
                        let freeSum = entries.reduce(0) { $0 + $1.node.freeGPUs }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                StatusDot(status: host.status, size: 9)
                                Text(host.config.alias)
                                    .font(.headline)
                                BadgePill(text: "Slurm", color: .purple)
                                BadgePill(text: "\(freeSum) 张空闲 GPU", color: .green, icon: "sparkles")
                                Spacer()
                                Button("查看集群看板") {
                                    onSelectHost(host.config.alias)
                                }
                                .controlSize(.small)
                            }

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 290), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(entries, id: \.node.id) { item in
                                    slurmFreeNodeCard(host: item.host, node: item.node, showClusterAlias: false)
                                }
                            }
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.purple.opacity(0.22)))
                    }
                }
            } else {
                let grouped = Dictionary(grouping: filteredSlurmFreeNodes, by: { $0.node.gpuType })
                let sortedTypes = grouped.keys.sorted { lhs, rhs in
                    let lSum = (grouped[lhs] ?? []).reduce(0) { $0 + $1.node.freeGPUs }
                    let rSum = (grouped[rhs] ?? []).reduce(0) { $0 + $1.node.freeGPUs }
                    return lSum > rSum
                }

                ForEach(sortedTypes, id: \.self) { gpuType in
                    let entries = grouped[gpuType] ?? []
                    let freeSum = entries.reduce(0) { $0 + $1.node.freeGPUs }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "cpu.fill").foregroundStyle(.purple)
                            Text(gpuType).font(.headline)
                            BadgePill(text: "\(freeSum) 张空闲", color: .green)
                            Spacer()
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 290), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(entries, id: \.node.id) { item in
                                slurmFreeNodeCard(host: item.host, node: item.node, showClusterAlias: true)
                            }
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                }
            }
        }
    }

    private func slurmFreeNodeCard(
        host: HostMonitorState,
        node: SlurmNodeMetric,
        showClusterAlias: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(showClusterAlias ? "\(host.config.alias) · \(node.name)" : node.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(node.gpuType) · 分区 \(node.partitions.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                BadgePill(text: "\(node.freeGPUs) / \(node.totalGPUs) 空", color: .green)
            }

            HStack(spacing: 10) {
                Text("CPU 剩余 \(max(0, node.cpusTotal - node.cpusAllocated))/\(node.cpusTotal)")
                Text("内存 \(Formatters.memoryPair(usedMiB: Double(node.memoryAllocatedMiB), totalMiB: Double(node.memoryTotalMiB)))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button {
                    let cmd = node.suggestedSrunCommand()
                    SystemActions.copyToClipboard(cmd)
                    onNotify("已复制：\(cmd)")
                } label: {
                    Label("复制 srun", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    let myJob = host.slurm?.runningJobs(onNode: node.name)
                        .first(where: { $0.isOwnedBy(host.slurm?.currentUser) })
                    liveProbeTarget = SlurmLiveProbeTarget(
                        loginAlias: host.config.alias,
                        nodeName: node.name,
                        jobID: myJob?.jobID,
                        subtitle: node.gpuType
                    )
                } label: {
                    Label("实时 nvidia-smi", systemImage: "waveform.path.ecg")
                        .font(.caption2)
                }
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(11)
        .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.22)))
    }

    // MARK: - Direct GPU Thresholds & Sections

    private var thresholdControls: some View {
        HStack(spacing: 20) {
            Text("直连 GPU 空闲条件：")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("最大算力")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { store.settings.idleThreshold.maxGPUUtilization },
                        set: { val in store.updateSettings { $0.idleThreshold.maxGPUUtilization = val } }
                    ),
                    in: 0...50,
                    step: 5
                )
                .frame(width: 100)
                Text("≤ \(Int(store.settings.idleThreshold.maxGPUUtilization))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("最大显存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { store.settings.idleThreshold.maxMemoryPercent },
                        set: { val in store.updateSettings { $0.idleThreshold.maxMemoryPercent = val } }
                    ),
                    in: 0...50,
                    step: 5
                )
                .frame(width: 100)
                Text("≤ \(Int(store.settings.idleThreshold.maxMemoryPercent))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }

            Toggle(
                "要求零进程",
                isOn: Binding(
                    get: { store.settings.idleThreshold.requireNoProcesses },
                    set: { val in store.updateSettings { $0.idleThreshold.requireNoProcesses = val } }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var groupedByHostView: some View {
        let grouped = Dictionary(grouping: filteredDirectIdle, by: { $0.host.config.alias })
        let sortedAliases = grouped.keys.sorted { lhs, rhs in
            (grouped[lhs]?.count ?? 0) > (grouped[rhs]?.count ?? 0)
        }

        return VStack(spacing: 12) {
            ForEach(sortedAliases, id: \.self) { alias in
                if let entries = grouped[alias], let host = entries.first?.host {
                    let gpus = entries.map(\.gpu).sorted { $0.index < $1.index }
                    let indicesCSV = gpus.map { String($0.index) }.joined(separator: ",")
                    let cudaEnv = "CUDA_VISIBLE_DEVICES=\(indicesCSV)"

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StatusDot(status: host.status, size: 9)
                            Text(host.config.alias)
                                .font(.headline)
                            BadgePill(text: host.effectiveGroup, color: .blue)
                            BadgePill(text: "\(gpus.count) / \(host.gpus.count) 张空闲", color: .green, icon: "sparkles")

                            Spacer()

                            Button {
                                SystemActions.copyToClipboard(cudaEnv)
                                onNotify("已复制：\(cudaEnv)")
                            } label: {
                                Label("复制 \(cudaEnv)", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                SystemActions.openSSHInTerminal(alias: host.config.alias)
                            } label: {
                                Label("终端连接", systemImage: "terminal")
                                    .font(.caption)
                            }
                            .controlSize(.small)

                            Button("查看详情") {
                                onSelectHost(host.config.alias)
                            }
                            .controlSize(.small)
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(gpus) { gpu in
                                idleGPUChip(gpu: gpu, hostAlias: nil)
                            }
                        }
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.green.opacity(0.22)))
                }
            }
        }
    }

    private var groupedByModelView: some View {
        let grouped = Dictionary(grouping: filteredDirectIdle, by: { $0.gpu.shortName })
        let sortedModels = grouped.keys.sorted { (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0) }

        return VStack(spacing: 12) {
            ForEach(sortedModels, id: \.self) { model in
                let entries = grouped[model] ?? []
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "cpu.fill")
                            .foregroundStyle(.green)
                        Text(model)
                            .font(.headline)
                        BadgePill(text: "\(entries.count) 张空闲", color: .green)
                        Spacer()
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(entries, id: \.gpu.id) { item in
                            Button {
                                onSelectHost(item.host.config.alias)
                            } label: {
                                idleGPUChip(gpu: item.gpu, hostAlias: item.host.config.alias)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }
        }
    }

    private func idleGPUChip(gpu: GPUMetric, hostAlias: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let hostAlias {
                    Text("\(hostAlias) · GPU \(gpu.index)")
                        .font(.callout.weight(.semibold))
                } else {
                    Text("GPU \(gpu.index) · \(gpu.shortName)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                Text(Formatters.temperature(gpu.temperatureC))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(GTopTheme.temperatureColor(gpu.temperatureC))
            }

            HStack(spacing: 10) {
                Text("算力 \(Formatters.percent(gpu.gpuUtilization))")
                Text("显存 \(Formatters.memoryPair(usedMiB: gpu.memoryUsedMiB, totalMiB: gpu.memoryTotalMiB))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.green.opacity(0.2)))
    }
}
