import Foundation

/// Provides realistic live-updating mock cluster data for Demo Mode so users can preview
/// real-time curves, processes, filtering rules, and idle GPU discovery without real servers.
public struct DemoDataProvider: Sendable {
    public init() {}

    public func demoHostConfigs() -> [SSHHostConfig] {
        [
            SSHHostConfig(
                alias: "slurm-hpc-login",
                hostName: "hpc.research.edu",
                user: "cliecy",
                port: 22,
                sourceFile: "~/.ssh/conf.d/hpc-slurm.conf",
                commentGroup: "Slurm 超算集群"
            ),
            SSHHostConfig(
                alias: "gpu-h100-01",
                hostName: "10.24.8.11",
                user: "mlops",
                port: 22,
                proxyJump: "bastion-prod",
                sourceFile: "~/.ssh/conf.d/prod-gpu.conf",
                commentGroup: "H100 训练集群"
            ),
            SSHHostConfig(
                alias: "gpu-a100-02",
                hostName: "10.24.8.22",
                user: "research",
                port: 22,
                proxyJump: "bastion-prod",
                sourceFile: "~/.ssh/conf.d/prod-gpu.conf",
                commentGroup: "A100 集群"
            ),
            SSHHostConfig(
                alias: "lab-4090-workstation",
                hostName: "192.168.10.45",
                user: "cliecy",
                port: 2222,
                sourceFile: "~/.ssh/conf.d/lab.conf",
                commentGroup: "实验室工作站"
            ),
            SSHHostConfig(
                alias: "gpu-a100-offline",
                hostName: "10.24.8.29",
                user: "research",
                port: 22,
                sourceFile: "~/.ssh/conf.d/prod-gpu.conf",
                commentGroup: "A100 集群"
            ),
            SSHHostConfig(
                alias: "github.com",
                hostName: "github.com",
                user: "git",
                port: 22,
                sourceFile: "~/.ssh/config"
            ),
            SSHHostConfig(
                alias: "bastion-prod",
                hostName: "203.0.113.10",
                user: "jump",
                port: 22,
                sourceFile: "~/.ssh/config"
            )
        ]
    }

    public func generateSnapshot(for alias: String, tick: Int) -> Result<HostPollSnapshot, Error> {
        let phase = Double(tick) * 0.35
        switch alias {
        case "slurm-hpc-login":
            let dynamicAlloc = (tick / 4) % 2 == 0 ? 4 : 6
            let nodes: [SlurmNodeMetric] = [
                SlurmNodeMetric(
                    name: "hpc-h100-01",
                    partitions: ["h100-prod", "gpu-all"],
                    rawState: "ALLOCATED",
                    stateCategory: .allocated,
                    gpuType: "H100",
                    totalGPUs: 8,
                    allocatedGPUs: 8,
                    gpuBreakdown: [SlurmGPUTypeCount(type: "H100", total: 8, allocated: 8)],
                    cpusAllocated: 112,
                    cpusTotal: 128,
                    cpuLoad: 64.2,
                    memoryAllocatedMiB: 900_000,
                    memoryTotalMiB: 1_024_000
                ),
                SlurmNodeMetric(
                    name: "hpc-h100-02",
                    partitions: ["h100-prod", "gpu-all"],
                    rawState: "MIXED",
                    stateCategory: .mixed,
                    gpuType: "H100",
                    totalGPUs: 8,
                    allocatedGPUs: dynamicAlloc,
                    gpuBreakdown: [SlurmGPUTypeCount(type: "H100", total: 8, allocated: dynamicAlloc)],
                    cpusAllocated: 48,
                    cpusTotal: 128,
                    cpuLoad: 28.5,
                    memoryAllocatedMiB: 420_000,
                    memoryTotalMiB: 1_024_000
                ),
                SlurmNodeMetric(
                    name: "hpc-a100-01",
                    partitions: ["a100-lab", "gpu-all"],
                    rawState: "MIXED",
                    stateCategory: .mixed,
                    gpuType: "A100",
                    totalGPUs: 8,
                    allocatedGPUs: 2,
                    gpuBreakdown: [SlurmGPUTypeCount(type: "A100", total: 8, allocated: 2)],
                    cpusAllocated: 16,
                    cpusTotal: 128,
                    cpuLoad: 11.8,
                    memoryAllocatedMiB: 128_000,
                    memoryTotalMiB: 512_000
                ),
                SlurmNodeMetric(
                    name: "hpc-a100-02",
                    partitions: ["a100-lab", "gpu-all"],
                    rawState: "IDLE",
                    stateCategory: .idle,
                    gpuType: "A100",
                    totalGPUs: 8,
                    allocatedGPUs: 0,
                    gpuBreakdown: [SlurmGPUTypeCount(type: "A100", total: 8, allocated: 0)],
                    cpusAllocated: 0,
                    cpusTotal: 128,
                    cpuLoad: 0.12,
                    memoryAllocatedMiB: 0,
                    memoryTotalMiB: 512_000
                ),
                SlurmNodeMetric(
                    name: "hpc-a100-03",
                    partitions: ["a100-lab"],
                    rawState: "IDLE+DRAIN",
                    stateCategory: .draining,
                    reason: "NVLink cable maintenance [admin@2026-11-22]",
                    gpuType: "A100",
                    totalGPUs: 8,
                    allocatedGPUs: 0,
                    gpuBreakdown: [SlurmGPUTypeCount(type: "A100", total: 8, allocated: 0)],
                    cpusAllocated: 0,
                    cpusTotal: 128,
                    cpuLoad: 0.05,
                    memoryAllocatedMiB: 0,
                    memoryTotalMiB: 512_000
                )
            ]

            let partitions: [SlurmPartitionSummary] = [
                SlurmPartitionSummary(
                    name: "gpu-all",
                    isDefault: true,
                    availability: "up",
                    timeLimit: "7-00:00:00",
                    totalNodes: 4,
                    availableNodes: 4,
                    totalGPUs: 32,
                    allocatedGPUs: 10 + dynamicAlloc,
                    freeGPUs: 22 - dynamicAlloc,
                    gpuTypes: ["A100", "H100"]
                ),
                SlurmPartitionSummary(
                    name: "h100-prod",
                    isDefault: false,
                    availability: "up",
                    timeLimit: "3-00:00:00",
                    totalNodes: 2,
                    availableNodes: 2,
                    totalGPUs: 16,
                    allocatedGPUs: 8 + dynamicAlloc,
                    freeGPUs: 8 - dynamicAlloc,
                    gpuTypes: ["H100"]
                ),
                SlurmPartitionSummary(
                    name: "a100-lab",
                    isDefault: false,
                    availability: "up",
                    timeLimit: "14-00:00:00",
                    totalNodes: 3,
                    availableNodes: 2,
                    totalGPUs: 24,
                    allocatedGPUs: 2,
                    freeGPUs: 14,
                    gpuTypes: ["A100"]
                )
            ]

            let jobs: [SlurmJobMetric] = [
                SlurmJobMetric(
                    jobID: "842105",
                    user: "cliecy",
                    name: "rlhf-qwen-32b",
                    partition: "h100-prod",
                    rawState: "RUNNING",
                    state: .running,
                    elapsedTime: "04:22:18",
                    timeLimit: "2-00:00:00",
                    nodeListRaw: "hpc-h100-02",
                    expandedNodes: ["hpc-h100-02"],
                    reason: "",
                    gpuCount: 4,
                    gpuType: "H100",
                    numNodes: 1,
                    numCPUs: 48
                ),
                SlurmJobMetric(
                    jobID: "842091",
                    user: "alice",
                    name: "pretrain-v3-stage2",
                    partition: "h100-prod",
                    rawState: "RUNNING",
                    state: .running,
                    elapsedTime: "1-14:09:42",
                    timeLimit: "3-00:00:00",
                    nodeListRaw: "hpc-h100-01",
                    expandedNodes: ["hpc-h100-01"],
                    reason: "",
                    gpuCount: 8,
                    gpuType: "H100",
                    numNodes: 1,
                    numCPUs: 112
                ),
                SlurmJobMetric(
                    jobID: "842119",
                    user: "bob",
                    name: "vllm-eval-suite",
                    partition: "a100-lab",
                    rawState: "RUNNING",
                    state: .running,
                    elapsedTime: "01:12:05",
                    timeLimit: "12:00:00",
                    nodeListRaw: "hpc-a100-01",
                    expandedNodes: ["hpc-a100-01"],
                    reason: "",
                    gpuCount: 2,
                    gpuType: "A100",
                    numNodes: 1,
                    numCPUs: 16
                ),
                SlurmJobMetric(
                    jobID: "842130",
                    user: "cliecy",
                    name: "grpo-ablation-16gpu",
                    partition: "h100-prod",
                    rawState: "PENDING",
                    state: .pending,
                    elapsedTime: "0:00",
                    timeLimit: "2-00:00:00",
                    nodeListRaw: "",
                    expandedNodes: [],
                    reason: "(Resources)",
                    gpuCount: 16,
                    gpuType: "H100",
                    numNodes: 2,
                    numCPUs: 192
                ),
                SlurmJobMetric(
                    jobID: "842134",
                    user: "charlie",
                    name: "diffusion-sft",
                    partition: "h100-prod",
                    rawState: "PENDING",
                    state: .pending,
                    elapsedTime: "0:00",
                    timeLimit: "1-00:00:00",
                    nodeListRaw: "",
                    expandedNodes: [],
                    reason: "(Priority)",
                    gpuCount: 8,
                    gpuType: "H100",
                    numNodes: 1,
                    numCPUs: 64
                )
            ]

            let slurmSnapshot = SlurmClusterSnapshot(
                currentUser: "cliecy",
                nodes: nodes,
                partitions: partitions,
                jobs: jobs
            )
            return .success(HostPollSnapshot(
                remoteHostname: "login01.hpc.research.edu",
                remoteUsername: "cliecy",
                gpus: [],
                slurm: slurmSnapshot,
                latencyMs: 31 + (tick % 6)
            ))

        case "gpu-h100-01":
            let gpus: [GPUMetric] = (0..<8).map { idx in
                let isBusy = idx < 5
                let wave = sin(phase + Double(idx) * 0.7) * 6.0
                let util = isBusy ? min(100, max(72, 91 + wave)) : (idx == 5 ? max(0, 4 + wave * 0.4) : 0)
                let memUsed: Double = isBusy ? (68400 + Double(idx) * 1450) : (idx == 5 ? 1280 : 12)
                let temp = isBusy ? (67 + Double(idx % 3) * 3 + wave * 0.3) : 34
                let power = isBusy ? (580 + wave * 8) : 68
                let procs: [GPUProcess] = isBusy ? [
                    GPUProcess(
                        gpuUUID: "GPU-H100-01-\(idx)",
                        gpuIndex: idx,
                        pid: 41200 + idx,
                        type: .compute,
                        user: idx < 4 ? "alice" : "david",
                        processName: "/opt/conda/bin/python3",
                        commandLine: idx < 4
                            ? "torchrun --nproc_per_node=4 train_llm.py --model qwen-72b --bf16"
                            : "python3 eval_benchmark.py --suite mmlu-pro --batch 32",
                        usedMemoryMiB: memUsed - 640,
                        elapsedTime: idx < 4 ? "1-04:18:22" : "02:41:09"
                    )
                ] : []
                return GPUMetric(
                    index: idx,
                    uuid: "GPU-H100-01-\(idx)",
                    name: "NVIDIA H100 80GB HBM3",
                    driverVersion: "550.90.07",
                    gpuUtilization: util,
                    memoryUtilization: isBusy ? min(100, util * 0.88) : 1,
                    memoryUsedMiB: memUsed,
                    memoryTotalMiB: 81559,
                    temperatureC: temp,
                    powerDrawW: power,
                    powerLimitW: 700,
                    fanSpeedPercent: nil, // Passive datacenter SXM5 cooling
                    pstate: isBusy ? "P0" : "P8",
                    processes: procs
                )
            }
            return .success(HostPollSnapshot(
                remoteHostname: "h100-node-01.internal",
                gpus: gpus,
                latencyMs: 24 + (tick % 7)
            ))

        case "gpu-a100-02":
            let gpus: [GPUMetric] = (0..<4).map { idx in
                let isBusy = idx == 0 || idx == 2
                let wave = cos(phase + Double(idx)) * 10.0
                let util = isBusy ? min(100, max(35, 68 + wave)) : 1
                let memUsed: Double = isBusy ? (idx == 0 ? 52100 : 38900) : 4
                let procs: [GPUProcess] = isBusy ? [
                    GPUProcess(
                        gpuUUID: "GPU-A100-02-\(idx)",
                        gpuIndex: idx,
                        pid: 18910 + idx * 17,
                        type: .compute,
                        user: idx == 0 ? "bob" : "charlie",
                        processName: "/usr/bin/python3",
                        commandLine: idx == 0
                            ? "vllm serve meta-llama/Llama-3.1-70B-Instruct --port 8000"
                            : "python3 finetune_lora.py --dataset sft_v4.jsonl",
                        usedMemoryMiB: memUsed - 300,
                        elapsedTime: idx == 0 ? "5-11:03:45" : "00:52:14"
                    )
                ] : []
                return GPUMetric(
                    index: idx,
                    uuid: "GPU-A100-02-\(idx)",
                    name: "NVIDIA A100-SXM4-80GB",
                    driverVersion: "550.54.15",
                    gpuUtilization: util,
                    memoryUtilization: isBusy ? min(100, util * 0.72) : 0,
                    memoryUsedMiB: memUsed,
                    memoryTotalMiB: 81920,
                    temperatureC: isBusy ? 58 + wave * 0.25 : 31,
                    powerDrawW: isBusy ? 275 + wave * 4 : 52,
                    powerLimitW: 400,
                    fanSpeedPercent: nil,
                    pstate: isBusy ? "P0" : "P8",
                    processes: procs
                )
            }
            return .success(HostPollSnapshot(
                remoteHostname: "a100-node-02.internal",
                gpus: gpus,
                latencyMs: 36 + (tick % 9)
            ))

        case "lab-4090-workstation":
            let gpus: [GPUMetric] = (0..<2).map { idx in
                let isBusy = idx == 0
                let wave = sin(phase * 1.4 + Double(idx)) * 12.0
                let util = isBusy ? min(100, max(45, 76 + wave)) : 2
                let memUsed: Double = isBusy ? 18420 : 312
                let procs: [GPUProcess] = isBusy ? [
                    GPUProcess(
                        gpuUUID: "GPU-4090-LAB-\(idx)",
                        gpuIndex: idx,
                        pid: 9321,
                        type: .compute,
                        user: "cliecy",
                        processName: "/home/cliecy/.venv/bin/python",
                        commandLine: "python train_diffusion.py --steps 50000 --fp16",
                        usedMemoryMiB: 17980,
                        elapsedTime: "03:19:08"
                    )
                ] : [
                    GPUProcess(
                        gpuUUID: "GPU-4090-LAB-\(idx)",
                        gpuIndex: idx,
                        pid: 1420,
                        type: .graphics,
                        user: "gdm",
                        processName: "/usr/lib/xorg/Xorg",
                        commandLine: "/usr/lib/xorg/Xorg vt2 -displayfd 3",
                        usedMemoryMiB: 280,
                        elapsedTime: "12-08:40:11"
                    )
                ]
                return GPUMetric(
                    index: idx,
                    uuid: "GPU-4090-LAB-\(idx)",
                    name: "NVIDIA GeForce RTX 4090",
                    driverVersion: "560.35.03",
                    gpuUtilization: util,
                    memoryUtilization: isBusy ? 64 : 3,
                    memoryUsedMiB: memUsed,
                    memoryTotalMiB: 24564,
                    temperatureC: isBusy ? 71 + wave * 0.2 : 36,
                    powerDrawW: isBusy ? 365 + wave * 5 : 22,
                    powerLimitW: 450,
                    fanSpeedPercent: isBusy ? 62 + wave * 0.5 : 30,
                    pstate: isBusy ? "P2" : "P8",
                    processes: procs
                )
            }
            return .success(HostPollSnapshot(
                remoteHostname: "lab-ws-4090",
                gpus: gpus,
                latencyMs: 8 + (tick % 4)
            ))

        case "gpu-a100-offline":
            return .failure(SSHClientError.connectionFailed("ssh: connect to host 10.24.8.29 port 22: Operation timed out"))

        default:
            return .failure(NvidiaSMIParseError.noNvidiaSMI)
        }
    }

    public func generateDemoSlurmNodeLiveSnapshot(
        nodeName: String,
        jobID: String?,
        tick: Int
    ) -> SlurmLiveNodeSnapshot {
        let phase = Double(tick) * 0.45
        let isH100 = nodeName.localizedCaseInsensitiveContains("h100")
        let isIdleNode = nodeName.hasSuffix("02") && !isH100
        let count = jobID != nil ? 4 : 8
        let gpus: [GPUMetric] = (0..<count).map { idx in
            let busy = !isIdleNode && (idx < 4 || nodeName.hasSuffix("01"))
            let wave = sin(phase + Double(idx) * 0.8) * 7.0
            let util = busy ? min(100, max(65, 88 + wave)) : 0
            let memUsed: Double = busy ? (64200 + Double(idx) * 1200) : 14
            let procs: [GPUProcess] = busy ? [
                GPUProcess(
                    gpuUUID: "SLURM-\(nodeName)-\(idx)",
                    gpuIndex: idx,
                    pid: 71000 + idx,
                    type: .compute,
                    user: jobID == "842105" || nodeName == "hpc-h100-02" ? "cliecy" : "alice",
                    processName: "/opt/conda/bin/python3",
                    commandLine: jobID == "842105" || nodeName == "hpc-h100-02"
                        ? "torchrun --nproc_per_node=4 train_rlhf.py --model qwen-32b"
                        : "deepspeed --num_gpus=8 pretrain_v3.py --stage 2",
                    usedMemoryMiB: memUsed - 400,
                    elapsedTime: "04:22:18"
                )
            ] : []

            return GPUMetric(
                index: idx,
                uuid: "SLURM-\(nodeName)-\(idx)",
                name: isH100 ? "NVIDIA H100 80GB HBM3" : "NVIDIA A100-SXM4-80GB",
                driverVersion: "550.90.07",
                gpuUtilization: util,
                memoryUtilization: busy ? min(100, util * 0.85) : 0,
                memoryUsedMiB: memUsed,
                memoryTotalMiB: 81559,
                temperatureC: busy ? 66 + wave * 0.35 : 32,
                powerDrawW: busy ? (isH100 ? 560 : 310) + wave * 6 : 58,
                powerLimitW: isH100 ? 700 : 400,
                fanSpeedPercent: nil,
                pstate: busy ? "P0" : "P8",
                processes: procs
            )
        }
        return SlurmLiveNodeSnapshot(
            nodeName: nodeName,
            jobID: jobID,
            method: .demo,
            gpus: gpus,
            latencyMs: 42 + (tick % 11)
        )
    }
}
