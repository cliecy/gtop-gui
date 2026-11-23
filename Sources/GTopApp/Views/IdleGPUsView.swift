import GTopCore
import SwiftUI

enum IdleGroupMode: String, CaseIterable, Identifiable {
    case byHost = "按服务器"
    case byModel = "按 GPU 型号"

    var id: String { rawValue }
}

struct IdleGPUsView: View {
    @Bindable var store: ClusterMonitorStore
    let searchText: String
    let onSelectHost: (String) -> Void
    let onNotify: (String) -> Void

    @State private var groupMode: IdleGroupMode = .byHost

    private var filteredIdleItems: [(host: HostMonitorState, gpu: GPUMetric)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.idleGPUs.filter { item in
            guard !q.isEmpty else { return true }
            return item.host.config.alias.localizedCaseInsensitiveContains(q) ||
                item.gpu.name.localizedCaseInsensitiveContains(q) ||
                item.host.effectiveGroup.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("空闲 GPU 发现")
                            .font(.title2.weight(.bold))
                        Text("当前集群共有 \(filteredIdleItems.count) / \(store.totalGPUCount) 张 GPU 符合空闲条件")
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
                    .frame(width: 200)
                }

                // Inline Threshold Bar
                thresholdControls

                if filteredIdleItems.isEmpty {
                    ContentUnavailableView(
                        "暂无符合条件的空闲 GPU",
                        systemImage: "sparkles",
                        description: Text("可以适当放宽上方的算力或显存阈值，或检查更多主机是否已启用监控。")
                    )
                    .padding(.vertical, 48)
                } else if groupMode == .byHost {
                    groupedByHostView
                } else {
                    groupedByModelView
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var thresholdControls: some View {
        HStack(spacing: 20) {
            HStack(spacing: 8) {
                Text("最大算力：")
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
                .frame(width: 110)
                Text("≤ \(Int(store.settings.idleThreshold.maxGPUUtilization))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("最大显存：")
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
                .frame(width: 110)
                Text("≤ \(Int(store.settings.idleThreshold.maxMemoryPercent))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
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
        let grouped = Dictionary(grouping: filteredIdleItems, by: { $0.host.config.alias })
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
        let grouped = Dictionary(grouping: filteredIdleItems, by: { $0.gpu.shortName })
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
