import GTopCore
import SwiftUI

/// On-demand live `nvidia-smi` drill-down modal for a Slurm compute node or running Slurm job.
/// Polls every 3s ONLY while open, then stops automatically on dismiss so compute nodes incur zero idle load.
struct SlurmNodeLiveGPUView: View {
    let store: ClusterMonitorStore
    let target: SlurmLiveProbeTarget
    let onNotify: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var isPaused = false
    @State private var errorMessage: String?
    @State private var probeMethod: SlurmLiveProbeMethod?
    @State private var selectedGPUID: String?
    @State private var liveHostState: HostMonitorState

    init(
        store: ClusterMonitorStore,
        target: SlurmLiveProbeTarget,
        onNotify: @escaping (String) -> Void
    ) {
        self.store = store
        self.target = target
        self.onNotify = onNotify
        _liveHostState = State(initialValue: HostMonitorState(
            config: SSHHostConfig(alias: target.nodeName, hostName: target.loginAlias),
            status: .connecting,
            isMonitored: true
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Modal header
            HStack(alignment: .center, spacing: 10) {
                StatusDot(status: liveHostState.status, size: 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.nodeName)
                            .font(.title3.weight(.bold))
                        BadgePill(text: "Slurm 计算节点实时探测", color: .purple)
                        if let jobID = target.jobID {
                            BadgePill(text: "Job #\(jobID)", color: .blue)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("登录节点：\(target.loginAlias)")
                        if let method = probeMethod {
                            Text("· \(method.rawValue)")
                        }
                        if let ms = liveHostState.latencyMs {
                            Text("· \(ms) ms")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        isPaused.toggle()
                        if !isPaused {
                            Task { await pollOnce() }
                        }
                    } label: {
                        Label(isPaused ? "继续" : "暂停", systemImage: isPaused ? "play.fill" : "pause.fill")
                    }

                    Button {
                        Task { await pollOnce() }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }

                    Button("关闭") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading && liveHostState.gpus.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.regular)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("正在通过 \(target.loginAlias) 探测 \(target.nodeName) 的实时 nvidia-smi…")
                                    .font(.headline)
                                Text(target.jobID != nil
                                    ? "优先尝试 srun --jobid=\(target.jobID!) --overlap，失败时回退计算节点 SSH"
                                    : "通过登录节点向计算节点 \(target.nodeName) 发起按需 nvidia-smi 采集")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if let errorMessage, liveHostState.gpus.isEmpty {
                        errorPanel(errorMessage)
                    } else {
                        if let errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("最近一次刷新失败：\(errorMessage)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }

                        gpuCardsGrid
                        GPUDetailChartsPanel(host: liveHostState, selectedGPUID: selectedGPUID)
                        processTable
                    }
                }
                .padding(18)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 920, minHeight: 620)
        .task {
            await pollLoop()
        }
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("无法获取计算节点 \(target.nodeName) 的实时 nvidia-smi")
                    .font(.headline)
                Spacer()
                Button("重试") {
                    Task { await pollOnce() }
                }
                .buttonStyle(.borderedProminent)
            }

            Text(message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text("常见原因与替代命令：")
                    .font(.caption.weight(.semibold))
                Text("• 许多 Slurm 集群禁止用户直接 SSH 到没有自己作业的计算节点（`pam_slurm_adopt`）。")
                Text("• 如果你正在该节点运行作业，请直接点击该作业行的「实时 nvidia-smi」，GTop 会通过 `srun --overlap` 进入作业环境采集。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                let manualCmd = target.jobID.map {
                    "ssh \(target.loginAlias) \"srun --jobid=\($0) --overlap -w \(target.nodeName) nvidia-smi\""
                } ?? "ssh -J \(target.loginAlias) \(target.nodeName) nvidia-smi"
                Button {
                    SystemActions.copyToClipboard(manualCmd)
                    onNotify("已复制排查命令")
                } label: {
                    Label("复制手动排查命令", systemImage: "doc.on.doc")
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var gpuCardsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("实时 GPU 指标（\(liveHostState.gpus.count) 张）", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                if selectedGPUID != nil {
                    Button("显示全部 GPU") { selectedGPUID = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 10)],
                spacing: 10
            ) {
                ForEach(liveHostState.gpus) { gpu in
                    let isSelected = selectedGPUID == gpu.id
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(GTopTheme.gpuColor(index: gpu.index))
                                .frame(width: 8, height: 8)
                            Text("GPU \(gpu.index)")
                                .font(.subheadline.weight(.bold))
                            Text(gpu.shortName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let pstate = gpu.pstate {
                                BadgePill(text: pstate, color: .secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("算力").font(.caption2).foregroundStyle(.secondary)
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

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("显存").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(Formatters.memoryPair(usedMiB: gpu.memoryUsedMiB, totalMiB: gpu.memoryTotalMiB))
                                    .font(.caption2.monospacedDigit())
                            }
                            MetricProgressBar(
                                fraction: gpu.memoryPercent / 100.0,
                                tint: GTopTheme.memoryColor(gpu.memoryPercent),
                                height: 6
                            )
                        }

                        HStack {
                            Label(Formatters.temperature(gpu.temperatureC), systemImage: "thermometer.medium")
                                .foregroundStyle(GTopTheme.temperatureColor(gpu.temperatureC))
                            Spacer()
                            Label(Formatters.power(draw: gpu.powerDrawW, limit: gpu.powerLimitW), systemImage: "bolt.fill")
                            Spacer()
                            Text("\(gpu.processes.count) 进程")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(11)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: isSelected ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 11))
                    .onTapGesture {
                        selectedGPUID = (selectedGPUID == gpu.id) ? nil : gpu.id
                    }
                }
            }
        }
    }

    private var processTable: some View {
        let procs = liveHostState.allProcesses.filter { proc in
            guard let selectedGPUID,
                  let gpu = liveHostState.gpus.first(where: { $0.id == selectedGPUID })
            else { return true }
            return proc.gpuUUID == gpu.uuid
        }
        .sorted { ($0.usedMemoryMiB ?? 0) > ($1.usedMemoryMiB ?? 0) }

        return VStack(alignment: .leading, spacing: 8) {
            Label("GPU 进程（\(procs.count)）", systemImage: "terminal")
                .font(.headline)

            if procs.isEmpty {
                Text("当前无活跃 GPU 进程")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("GPU").frame(width: 46, alignment: .leading)
                        Text("PID").frame(width: 64, alignment: .trailing)
                        Text("用户").frame(width: 85, alignment: .leading)
                        Text("显存").frame(width: 80, alignment: .trailing)
                        Text("命令行").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04))

                    Divider()

                    ForEach(procs) { proc in
                        HStack(spacing: 10) {
                            BadgePill(text: "#\(proc.gpuIndex)", color: GTopTheme.gpuColor(index: proc.gpuIndex))
                                .frame(width: 46, alignment: .leading)
                            Text("\(proc.pid)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 64, alignment: .trailing)
                            Text(proc.user)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .frame(width: 85, alignment: .leading)
                            Text(Formatters.memoryMiB(proc.usedMemoryMiB))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.indigo)
                                .frame(width: 80, alignment: .trailing)
                            HStack {
                                Text(proc.displayName)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button {
                                    SystemActions.copyToClipboard(proc.displayName)
                                    onNotify("已复制进程命令")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.08)))
            }
        }
    }

    private func pollLoop() async {
        await pollOnce()
        while !Task.isCancelled {
            let interval = max(2.0, store.settings.refreshIntervalSeconds)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { break }
            if !isPaused {
                await pollOnce()
            }
        }
    }

    @MainActor
    private func pollOnce() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let snap = try await store.probeSlurmNodeLiveGPU(
                loginAlias: target.loginAlias,
                nodeName: target.nodeName,
                jobID: target.jobID
            )
            errorMessage = nil
            probeMethod = snap.method
            liveHostState.status = .online
            liveHostState.gpus = snap.gpus
            liveHostState.latencyMs = snap.latencyMs
            liveHostState.lastUpdated = snap.timestamp

            for gpu in snap.gpus {
                let pt = GPUSamplePoint(
                    timestamp: snap.timestamp,
                    gpuUtilization: gpu.gpuUtilization ?? 0,
                    memoryPercent: gpu.memoryPercent,
                    temperatureC: gpu.temperatureC ?? 0,
                    powerDrawW: gpu.powerDrawW ?? 0,
                    fanSpeedPercent: gpu.fanSpeedPercent
                )
                var series = liveHostState.historyByGPU[gpu.id] ?? []
                series.append(pt)
                if series.count > 120 { series.removeFirst(series.count - 120) }
                liveHostState.historyByGPU[gpu.id] = series
            }
        } catch {
            errorMessage = error.localizedDescription
            if liveHostState.gpus.isEmpty {
                liveHostState.status = .error(error.localizedDescription)
            }
        }
    }
}
