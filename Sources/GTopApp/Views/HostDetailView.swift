import GTopCore
import SwiftUI

struct HostDetailView: View {
    @Bindable var store: ClusterMonitorStore
    let alias: String
    let onNotify: (String) -> Void

    @State private var selectedGPUID: String? = nil
    @State private var processSearch: String = ""
    @State private var isEditingGroup: Bool = false
    @State private var groupDraft: String = ""

    private var host: HostMonitorState? {
        store.hostStates[alias]
    }

    var body: some View {
        if let host {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hostHeader(host)

                    if !host.isMonitored {
                        unmonitoredBanner(host)
                    } else if !host.status.isOnline {
                        statusDiagnosticCard(host)
                    }

                    if host.status.isOnline {
                        if let slurm = host.slurm {
                            SlurmHostDetailView(
                                store: store,
                                host: host,
                                slurm: slurm,
                                onNotify: onNotify
                            )
                        }
                        if !host.gpus.isEmpty {
                            if host.slurm != nil {
                                Divider()
                                Text("本机直连 GPU")
                                    .font(.title3.weight(.bold))
                            }
                            gpuCardsSection(host)
                            GPUDetailChartsPanel(host: host, selectedGPUID: selectedGPUID)
                            processTableSection(host)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: alias) { _, _ in
                selectedGPUID = nil
                processSearch = ""
            }
        } else {
            ContentUnavailableView(
                "未找到主机",
                systemImage: "server.rack",
                description: Text("主机 \(alias) 已从 SSH 配置中移除。")
            )
        }
    }

    // MARK: - Header

    private func hostHeader(_ host: HostMonitorState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(status: host.status, size: 11)
                    Text(host.config.alias)
                        .font(.title2.weight(.bold))

                    BadgePill(
                        text: host.status.label,
                        color: GTopTheme.statusColor(host.status)
                    )

                    if host.isSlurmCluster {
                        BadgePill(text: "Slurm 集群", color: .purple, icon: "square.stack.3d.up")
                    }

                    if isEditingGroup {
                        HStack(spacing: 4) {
                            TextField("分组名", text: $groupDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .onSubmit {
                                    store.setCustomGroup(for: host.config.alias, group: groupDraft)
                                    isEditingGroup = false
                                }
                            Button("保存") {
                                store.setCustomGroup(for: host.config.alias, group: groupDraft)
                                isEditingGroup = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("取消") { isEditingGroup = false }
                                .controlSize(.small)
                        }
                    } else {
                        Button {
                            groupDraft = store.settings.customGroups[host.config.alias] ?? host.effectiveGroup
                            isEditingGroup = true
                        } label: {
                            BadgePill(text: host.effectiveGroup, color: .blue, icon: "folder")
                        }
                        .buttonStyle(.plain)
                        .help("点击修改主机所属分组")
                    }
                }

                HStack(spacing: 12) {
                    Label(host.config.connectionSummary, systemImage: "network")
                    if let jump = host.config.proxyJump {
                        Label("跳板: \(jump)", systemImage: "arrow.triangle.branch")
                    }
                    if let driver = host.driverVersion {
                        Label("Driver \(driver)", systemImage: "wrench.and.screwdriver")
                    }
                    if let remoteName = host.remoteHostname, !remoteName.isEmpty {
                        Label(remoteName, systemImage: "desktopcomputer")
                    }
                    if let ms = host.latencyMs {
                        Label("\(ms) ms", systemImage: "timer")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    let cmd = "ssh \(host.config.alias)"
                    SystemActions.copyToClipboard(cmd)
                    onNotify("已复制：\(cmd)")
                } label: {
                    Label("复制 SSH", systemImage: "doc.on.doc")
                }

                Button {
                    SystemActions.openSSHInTerminal(alias: host.config.alias)
                } label: {
                    Label("终端连接", systemImage: "terminal")
                }

                Button {
                    Task { await store.refreshHost(host.config.alias) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!host.isMonitored)
            }
            .controlSize(.regular)
        }
    }

    private func unmonitoredBanner(_ host: HostMonitorState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("当前未监控此主机")
                    .font(.headline)
                Text("原因：\(host.matchReason) · 来源：\(host.config.sourceFile)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("强制启用监控") {
                store.setManualOverride(for: host.config.alias, override: .forceEnable)
                onNotify("已启用监控 \(host.config.alias)")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusDiagnosticCard(_ host: HostMonitorState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if case .connecting = host.status {
                    ProgressView().controlSize(.small)
                    Text("正在建立 SSH 连接并运行 nvidia-smi…")
                        .font(.headline)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(host.status == .noGPU ? .orange : .red)
                        .font(.title3)
                    Text(host.status == .noGPU ? "未检测到 NVIDIA GPU" : "采集失败")
                        .font(.headline)
                }
                Spacer()
                Button("重试连接") {
                    Task { await store.refreshHost(host.config.alias) }
                }
                Button("停用此主机") {
                    store.setManualOverride(for: host.config.alias, override: .forceDisable)
                }
            }

            if let err = host.status.errorDetail {
                Text(err)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("排查提示：在终端运行 `ssh -o BatchMode=yes \(host.config.alias) nvidia-smi` 可验证免密认证与驱动是否正常。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: - Per-GPU Cards

    private func gpuCardsSection(_ host: HostMonitorState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("GPU 设备（\(host.gpus.count) 张）", systemImage: "cpu")
                    .font(.headline)

                Spacer()

                if selectedGPUID != nil {
                    Button("显示全部 GPU 曲线") {
                        selectedGPUID = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                } else {
                    Text("点击单张 GPU 卡片可聚焦趋势图与进程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 255, maximum: 360), spacing: 12)],
                spacing: 12
            ) {
                ForEach(host.gpus) { gpu in
                    let isSelected = selectedGPUID == gpu.id
                    let isIdle = gpu.isIdle(threshold: store.settings.idleThreshold)
                    GPUCard(gpu: gpu, isSelected: isSelected, isIdle: isIdle)
                        .onTapGesture {
                            if selectedGPUID == gpu.id {
                                selectedGPUID = nil
                            } else {
                                selectedGPUID = gpu.id
                            }
                        }
                }
            }
        }
    }

    // MARK: - Process Table

    private func processTableSection(_ host: HostMonitorState) -> some View {
        let filteredProcesses = host.allProcesses.filter { proc in
            if let selectedGPUID,
               let gpu = host.gpus.first(where: { $0.id == selectedGPUID }),
               proc.gpuUUID != gpu.uuid
            {
                return false
            }
            let q = processSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            return proc.user.localizedCaseInsensitiveContains(q) ||
                proc.commandLine.localizedCaseInsensitiveContains(q) ||
                String(proc.pid).contains(q)
        }
        .sorted { ($0.usedMemoryMiB ?? 0) > ($1.usedMemoryMiB ?? 0) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("GPU 进程明细（\(filteredProcesses.count)）", systemImage: "terminal")
                    .font(.headline)

                Spacer()

                TextField("筛选 PID / 用户 / 命令…", text: $processSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            if filteredProcesses.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text(host.allProcesses.isEmpty ? "当前无 GPU 进程运行" : "没有匹配筛选条件的进程")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("GPU").frame(width: 48, alignment: .leading)
                        Text("PID").frame(width: 66, alignment: .trailing)
                        Text("类型").frame(width: 42, alignment: .center)
                        Text("用户").frame(width: 90, alignment: .leading)
                        Text("显存").frame(width: 82, alignment: .trailing)
                        Text("运行时长").frame(width: 82, alignment: .trailing)
                        Text("命令行").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04))

                    Divider()

                    ForEach(filteredProcesses) { proc in
                        HStack(spacing: 10) {
                            BadgePill(
                                text: "#\(proc.gpuIndex)",
                                color: GTopTheme.gpuColor(index: proc.gpuIndex)
                            )
                            .frame(width: 48, alignment: .leading)

                            Text("\(proc.pid)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 66, alignment: .trailing)

                            BadgePill(
                                text: proc.type.shortLabel,
                                color: proc.type == .compute ? .blue : .purple
                            )
                            .frame(width: 42, alignment: .center)

                            Text(proc.user)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(width: 90, alignment: .leading)

                            Text(Formatters.memoryMiB(proc.usedMemoryMiB))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.indigo)
                                .frame(width: 82, alignment: .trailing)

                            Text(proc.elapsedTime ?? "—")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .trailing)

                            HStack(spacing: 6) {
                                Text(proc.displayName)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(proc.displayName)
                                Spacer(minLength: 4)
                                Button {
                                    SystemActions.copyToClipboard(proc.displayName)
                                    onNotify("已复制进程命令 (PID \(proc.pid))")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("复制完整命令行")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)

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
}

private struct GPUCard: View {
    let gpu: GPUMetric
    let isSelected: Bool
    let isIdle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(GTopTheme.gpuColor(index: gpu.index))
                        .frame(width: 8, height: 8)
                    Text("GPU \(gpu.index)")
                        .font(.subheadline.weight(.bold))
                    Text(gpu.shortName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isIdle {
                    BadgePill(text: "空闲", color: .green)
                }
                if let pstate = gpu.pstate {
                    BadgePill(text: pstate, color: .secondary)
                }
            }

            // GPU Utilization
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("算力利用率")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Formatters.percent(gpu.gpuUtilization))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(GTopTheme.utilizationColor(gpu.gpuUtilization))
                }
                MetricProgressBar(
                    fraction: (gpu.gpuUtilization ?? 0) / 100.0,
                    tint: GTopTheme.utilizationColor(gpu.gpuUtilization),
                    height: 6
                )
            }

            // Memory Utilization
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("显存占用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Formatters.memoryPair(usedMiB: gpu.memoryUsedMiB, totalMiB: gpu.memoryTotalMiB)) (\(Formatters.percent(gpu.memoryPercent)))")
                        .font(.caption2.weight(.medium).monospacedDigit())
                }
                MetricProgressBar(
                    fraction: gpu.memoryPercent / 100.0,
                    tint: GTopTheme.memoryColor(gpu.memoryPercent),
                    height: 6
                )
            }

            Divider()

            // Temp / Power / Fan / Processes
            HStack(spacing: 0) {
                statCell(
                    icon: "thermometer.medium",
                    value: Formatters.temperature(gpu.temperatureC),
                    color: GTopTheme.temperatureColor(gpu.temperatureC)
                )
                Spacer()
                statCell(
                    icon: "bolt.fill",
                    value: Formatters.power(draw: gpu.powerDrawW, limit: gpu.powerLimitW),
                    color: .secondary
                )
                Spacer()
                statCell(
                    icon: "fanblades",
                    value: Formatters.percent(gpu.fanSpeedPercent),
                    color: .secondary
                )
                Spacer()
                statCell(
                    icon: "app.badge",
                    value: "\(gpu.processes.count) 进程",
                    color: gpu.processes.isEmpty ? .green : .secondary
                )
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.09),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statCell(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
