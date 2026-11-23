import Testing
@testable import GTopCore

struct NvidiaSMIParserTests {
    private let parser = NvidiaSMIParser()

    @Test("Parses multi-GPU output, N/A fields, compute/graphics processes, and ps metadata")
    func fullOutputParsingWithNAFieldsAndProcesses() throws {
        let raw = """
        __GTOP_META__
        gpu-box-01
        __GTOP_GPUS__
        0, GPU-aaaa-0000, NVIDIA H100 80GB HBM3, 550.90.07, 92, 81, 65536, 81559, 68, 540.25, 700.00, [N/A], P0
        1, GPU-bbbb-1111, NVIDIA GeForce RTX 4090, 550.90.07, 3, 1, 256, 24564, 34, 21.5, 450.00, 30, P8
        __GTOP_PROCS__
        GPU-aaaa-0000, 12345, /opt/conda/bin/python3, 64800
        GPU-aaaa-0000, 99999, /weird,path/worker, [N/A]
        __GTOP_GPROCS__
        GPU-bbbb-1111, 1400, /usr/lib/xorg/Xorg, 180
        __GTOP_PS__
        12345 alice 2-03:14:05 python3 train.py --lr 1e-4
         1400 root  15:20 /usr/lib/xorg/Xorg :0
        __GTOP_END__
        """

        let result = try parser.parse(output: raw)
        #expect(result.remoteHostname == "gpu-box-01")
        #expect(result.gpus.count == 2)

        let gpu0 = result.gpus[0]
        #expect(gpu0.index == 0)
        #expect(gpu0.shortName == "H100 80GB HBM3")
        #expect(gpu0.gpuUtilization == 92)
        #expect(gpu0.memoryUsedMiB == 65536)
        #expect(gpu0.fanSpeedPercent == nil)
        #expect(gpu0.pstate == "P0")
        #expect(gpu0.processes.count == 2)

        let p0 = gpu0.processes[0]
        #expect(p0.pid == 12345)
        #expect(p0.user == "alice")
        #expect(p0.elapsedTime == "2-03:14:05")
        #expect(p0.commandLine == "python3 train.py --lr 1e-4")
        #expect(p0.usedMemoryMiB == 64800)

        let p1 = gpu0.processes[1]
        #expect(p1.pid == 99999)
        #expect(p1.processName == "/weird, path/worker")
        #expect(p1.usedMemoryMiB == nil)
        #expect(p1.user == "unknown")

        let gpu1 = result.gpus[1]
        #expect(gpu1.shortName == "RTX 4090")
        #expect(gpu1.fanSpeedPercent == 30)
        #expect(gpu1.processes.count == 1)
        #expect(gpu1.processes[0].type == .graphics)
        #expect(gpu1.isIdle(threshold: IdleThreshold(maxGPUUtilization: 10, maxMemoryPercent: 10, maxMemoryMiB: 1024, requireNoProcesses: false)))
        #expect(!gpu1.isIdle(threshold: IdleThreshold(maxGPUUtilization: 10, maxMemoryPercent: 10, maxMemoryMiB: 1024, requireNoProcesses: true)))
    }

    @Test("Detects missing nvidia-smi cleanly")
    func noNvidiaSMIThrowsExpectedError() {
        let raw = "__GTOP_ERR__:NO_NVIDIA_SMI\n"
        #expect(throws: NvidiaSMIParseError.noNvidiaSMI) {
            try parser.parse(output: raw)
        }
    }

    @Test("Detects NVIDIA driver communication failure")
    func driverFailureThrowsSMIFailed() {
        let raw = """
        __GTOP_META__
        broken-host
        __GTOP_GPUS__
        NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.
        __GTOP_SMI_RC__:9
        __GTOP_END__
        """
        do {
            _ = try parser.parse(output: raw)
            Issue.record("Expected smiCommandFailed error")
        } catch let error as NvidiaSMIParseError {
            guard case .smiCommandFailed(let msg) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(msg.contains("NVIDIA-SMI has failed"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
