import Testing
@testable import GTopCore

struct SlurmParserTests {
    private let parser = NvidiaSMIParser()

    @Test("Parses Slurm login node without local nvidia-smi, including partitions, scontrol nodes, GRES/TRES, and V2 jobs")
    func fullSlurmClusterParsing() throws {
        let output = """
        __GTOP_META__
        login01.hpc.edu
        __GTOP_USER__
        cliecy
        __GTOP_SLURM_PRESENT__
        __GTOP_SLURM_PARTITIONS__
        gpu*|up|7-00:00:00
        a100|up|3-00:00:00
        __GTOP_SLURM_NODES__
        NodeName=gpu-01 Arch=x86_64 CoresPerSocket=64 CPUAlloc=64 CPUTot=128 CPULoad=31.50 Gres=gpu:nvidia_h100:8(S:0-1) CfgTRES=cpu=128,mem=1024G,gres/gpu=8,gres/gpu:nvidia_h100=8 AllocTRES=cpu=64,mem=512G,gres/gpu=4,gres/gpu:nvidia_h100=4 RealMemory=1024000 AllocMem=512000 State=MIXED Partitions=gpu
        NodeName=gpu-02 CPUAlloc=0 CPUTot=128 CPULoad=0.05 Gres=gpu:a100:8 CfgTRES=cpu=128,mem=512G,gres/gpu=8,gres/gpu:a100=8 AllocTRES= RealMemory=512000 AllocMem=0 State=IDLE Partitions=gpu,a100
        NodeName=gpu-03 CPUAlloc=0 CPUTot=128 CPULoad=0.01 Gres=gpu:a100:8 CfgTRES=cpu=128,mem=512G,gres/gpu=8,gres/gpu:a100=8 AllocTRES= RealMemory=512000 AllocMem=0 State=IDLE+DRAIN Reason=ECC GPU error [root@2026-11-22] Partitions=a100
        __GTOP_SLURM_JOBS_V2__
        10023|cliecy|gpu|RUNNING|02:15:30|2-00:00:00|gpu-01|None|cpu=64,mem=512G,gres/gpu=4,gres/gpu:nvidia_h100=4|gres/gpu:nvidia_h100:4|N/A|1|64|train|pipe|name
        10024|alice|a100|PENDING|0:00|1-00:00:00||(Resources)|N/A|gres/gpu:a100:8|N/A|2|128|big-run
        __GTOP_END__
        """

        let result = try parser.parse(output: output)
        #expect(result.remoteHostname == "login01.hpc.edu")
        #expect(result.remoteUsername == "cliecy")
        #expect(result.gpus.isEmpty)

        let slurm = try #require(result.slurm)
        #expect(slurm.currentUser == "cliecy")
        #expect(slurm.nodes.count == 3)
        #expect(slurm.totalGPUs == 24)
        #expect(slurm.allocatedGPUs == 4)
        // gpu-01 has 4 free, gpu-02 has 8 free, gpu-03 is DRAIN so 0 schedulable free GPUs => 12 total free
        #expect(slurm.freeGPUs == 12)

        let node1 = try #require(slurm.nodes.first(where: { $0.name == "gpu-01" }))
        #expect(node1.gpuType == "H100")
        #expect(node1.allocatedGPUs == 4)
        #expect(node1.freeGPUs == 4)
        #expect(node1.stateCategory == .mixed)
        #expect(node1.suggestedSrunCommand() == "srun -p gpu -w gpu-01 --gres=gpu:1 --pty bash")

        let node3 = try #require(slurm.nodes.first(where: { $0.name == "gpu-03" }))
        #expect(node3.stateCategory == .draining)
        #expect(node3.freeGPUs == 0)
        #expect(node3.reason == "ECC GPU error [root@2026-11-22]")

        #expect(slurm.jobs.count == 2)
        let myJob = slurm.jobs[0]
        #expect(myJob.jobID == "10023")
        #expect(myJob.isOwnedBy("cliecy"))
        #expect(myJob.gpuCount == 4)
        #expect(myJob.gpuType == "H100")
        #expect(myJob.name == "train|pipe|name") // Pipe inside job name preserved!

        let pendingJob = slurm.jobs[1]
        #expect(pendingJob.state == .pending)
        #expect(pendingJob.gpuCount == 16) // 8 per node * 2 nodes
        #expect(pendingJob.reason == "(Resources)")

        let gpuPart = try #require(slurm.partitions.first(where: { $0.name == "gpu" }))
        #expect(gpuPart.isDefault)
        #expect(gpuPart.totalGPUs == 16)
        #expect(gpuPart.freeGPUs == 12)
    }

    @Test("Expands compressed Slurm node ranges accurately with zero-padding")
    func slurmNodeListExpansion() {
        #expect(
            SlurmParser.expandNodeList("gpu-[01-03,05],h100-09")
                == ["gpu-01", "gpu-02", "gpu-03", "gpu-05", "h100-09"]
        )
        #expect(
            SlurmParser.expandNodeList("node[1-2]-gpu[01-02]")
                == ["node1-gpu01", "node1-gpu02", "node2-gpu01", "node2-gpu02"]
        )
        #expect(SlurmParser.expandNodeList("(Resources)").isEmpty)
        #expect(SlurmParser.expandNodeList("").isEmpty)
    }

    @Test("Falls back cleanly to sinfo + squeue V1 when scontrol and V2 are unavailable")
    func sinfoAndV1Fallback() throws {
        let output = """
        __GTOP_META__
        old-slurm-login
        __GTOP_USER__
        researcher
        __GTOP_SLURM_PRESENT__
        __GTOP_SLURM_PARTITIONS__
        gpu*|up|infinite
        __GTOP_SLURM_NODES__
        __GTOP_SLURM_SINFO__
        node01|gpu*|mix|gpu:v100:4|16/16/0/32|256000|8.4
        node02|gpu*|idle|gpu:v100:4|0/32/0/32|256000|0.1
        __GTOP_SLURM_JOBS_V2__
        __GTOP_SLURM_JOBS_V1__
        501|researcher|gpu|RUNNING|00:45:10|1-00:00:00|node01|None|gres/gpu:v100:2|1|16|eval-job
        __GTOP_END__
        """

        let result = try parser.parse(output: output)
        let slurm = try #require(result.slurm)
        #expect(slurm.nodes.count == 2)
        #expect(slurm.totalGPUs == 8)
        #expect(slurm.allocatedGPUs == 2)
        #expect(slurm.freeGPUs == 6)
        #expect(slurm.myJobs.count == 1)
    }
}
