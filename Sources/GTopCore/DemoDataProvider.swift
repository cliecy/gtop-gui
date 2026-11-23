import Foundation

/// Provides realistic live-updating mock cluster data for Demo Mode so users can preview
/// real-time curves, processes, filtering rules, and idle GPU discovery without real servers.
public struct DemoDataProvider: Sendable {
    public init() {}

    public func demoHostConfigs() -> [SSHHostConfig] {
        [
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
}
