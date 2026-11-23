import Foundation

// MARK: - Slurm Cluster Data Models

public enum SlurmNodeStateCategory: String, Codable, Hashable, Sendable {
    case idle
    case mixed
    case allocated
    case draining
    case down
    case other

    public var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .mixed: return "部分占用"
        case .allocated: return "已满载"
        case .draining: return "排空中"
        case .down: return "离线/维护"
        case .other: return "其他"
        }
    }

    public var isSchedulable: Bool {
        switch self {
        case .idle, .mixed, .allocated:
            return true
        case .draining, .down, .other:
            return false
        }
    }
}

public struct SlurmGPUTypeCount: Identifiable, Hashable, Codable, Sendable {
    public var id: String { type }
    public let type: String
    public let total: Int
    public let allocated: Int

    public var free: Int { max(0, total - allocated) }

    public init(type: String, total: Int, allocated: Int) {
        self.type = type
        self.total = total
        self.allocated = allocated
    }
}

public struct SlurmNodeMetric: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let partitions: [String]
    public let rawState: String
    public let stateCategory: SlurmNodeStateCategory
    public let reason: String?
    public let gpuType: String
    public let totalGPUs: Int
    public let allocatedGPUs: Int
    public let gpuBreakdown: [SlurmGPUTypeCount]
    public let cpusAllocated: Int
    public let cpusTotal: Int
    public let cpuLoad: Double?
    public let memoryAllocatedMiB: Int
    public let memoryTotalMiB: Int

    public init(
        name: String,
        partitions: [String],
        rawState: String,
        stateCategory: SlurmNodeStateCategory,
        reason: String? = nil,
        gpuType: String,
        totalGPUs: Int,
        allocatedGPUs: Int,
        gpuBreakdown: [SlurmGPUTypeCount] = [],
        cpusAllocated: Int = 0,
        cpusTotal: Int = 0,
        cpuLoad: Double? = nil,
        memoryAllocatedMiB: Int = 0,
        memoryTotalMiB: Int = 0
    ) {
        self.name = name
        self.partitions = partitions
        self.rawState = rawState
        self.stateCategory = stateCategory
        self.reason = reason
        self.gpuType = gpuType
        self.totalGPUs = totalGPUs
        self.allocatedGPUs = allocatedGPUs
        self.gpuBreakdown = gpuBreakdown
        self.cpusAllocated = cpusAllocated
        self.cpusTotal = cpusTotal
        self.cpuLoad = cpuLoad
        self.memoryAllocatedMiB = memoryAllocatedMiB
        self.memoryTotalMiB = memoryTotalMiB
    }

    public var freeGPUs: Int {
        guard stateCategory.isSchedulable else { return 0 }
        return max(0, totalGPUs - allocatedGPUs)
    }

    public var hasFreeGPUs: Bool {
        freeGPUs > 0
    }

    public var gpuAllocationPercent: Double {
        guard totalGPUs > 0 else { return 0 }
        return min(100.0, (Double(allocatedGPUs) / Double(totalGPUs)) * 100.0)
    }

    public var cpuAllocationPercent: Double {
        guard cpusTotal > 0 else { return 0 }
        return min(100.0, (Double(cpusAllocated) / Double(cpusTotal)) * 100.0)
    }

    public var memoryAllocationPercent: Double {
        guard memoryTotalMiB > 0 else { return 0 }
        return min(100.0, (Double(memoryAllocatedMiB) / Double(memoryTotalMiB)) * 100.0)
    }

    public func suggestedSrunCommand(preferredPartition: String? = nil, gpuCount: Int = 1) -> String {
        let part = preferredPartition ?? partitions.first
        let partFlag = part.map { "-p \($0) " } ?? ""
        let reqGPUs = max(1, min(gpuCount, max(1, freeGPUs)))
        return "srun \(partFlag)-w \(name) --gres=gpu:\(reqGPUs) --pty bash"
    }
}

public struct SlurmPartitionSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let isDefault: Bool
    public let availability: String
    public let timeLimit: String?
    public let totalNodes: Int
    public let availableNodes: Int
    public let totalGPUs: Int
    public let allocatedGPUs: Int
    public let freeGPUs: Int
    public let gpuTypes: [String]

    public init(
        name: String,
        isDefault: Bool = false,
        availability: String = "up",
        timeLimit: String? = nil,
        totalNodes: Int,
        availableNodes: Int,
        totalGPUs: Int,
        allocatedGPUs: Int,
        freeGPUs: Int,
        gpuTypes: [String]
    ) {
        self.name = name
        self.isDefault = isDefault
        self.availability = availability
        self.timeLimit = timeLimit
        self.totalNodes = totalNodes
        self.availableNodes = availableNodes
        self.totalGPUs = totalGPUs
        self.allocatedGPUs = allocatedGPUs
        self.freeGPUs = freeGPUs
        self.gpuTypes = gpuTypes
    }

    public var allocationPercent: Double {
        guard totalGPUs > 0 else { return 0 }
        return min(100.0, (Double(allocatedGPUs) / Double(totalGPUs)) * 100.0)
    }
}

public enum SlurmJobState: Hashable, Codable, Sendable {
    case running
    case pending
    case completing
    case other(String)

    public var shortLabel: String {
        switch self {
        case .running: return "运行中"
        case .pending: return "排队中"
        case .completing: return "收尾中"
        case .other(let raw): return raw
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

public struct SlurmJobMetric: Identifiable, Hashable, Codable, Sendable {
    public var id: String { jobID }
    public let jobID: String
    public let user: String
    public let name: String
    public let partition: String
    public let rawState: String
    public let state: SlurmJobState
    public let elapsedTime: String
    public let timeLimit: String
    public let nodeListRaw: String
    public let expandedNodes: [String]
    public let reason: String
    public let gpuCount: Int
    public let gpuType: String?
    public let numNodes: Int
    public let numCPUs: Int

    public init(
        jobID: String,
        user: String,
        name: String,
        partition: String,
        rawState: String,
        state: SlurmJobState,
        elapsedTime: String,
        timeLimit: String,
        nodeListRaw: String,
        expandedNodes: [String],
        reason: String,
        gpuCount: Int,
        gpuType: String? = nil,
        numNodes: Int = 1,
        numCPUs: Int = 0
    ) {
        self.jobID = jobID
        self.user = user
        self.name = name
        self.partition = partition
        self.rawState = rawState
        self.state = state
        self.elapsedTime = elapsedTime
        self.timeLimit = timeLimit
        self.nodeListRaw = nodeListRaw
        self.expandedNodes = expandedNodes
        self.reason = reason
        self.gpuCount = gpuCount
        self.gpuType = gpuType
        self.numNodes = numNodes
        self.numCPUs = numCPUs
    }

    public func isOwnedBy(_ currentUser: String?) -> Bool {
        guard let currentUser, !currentUser.isEmpty else { return false }
        return user.caseInsensitiveCompare(currentUser) == .orderedSame
    }

    public var primaryNode: String? {
        expandedNodes.first
    }
}

public struct SlurmUserUsage: Identifiable, Hashable, Sendable {
    public var id: String { user }
    public let user: String
    public let runningGPUs: Int
    public let pendingGPUs: Int
    public let runningJobs: Int
    public let pendingJobs: Int

    public init(
        user: String,
        runningGPUs: Int,
        pendingGPUs: Int,
        runningJobs: Int,
        pendingJobs: Int
    ) {
        self.user = user
        self.runningGPUs = runningGPUs
        self.pendingGPUs = pendingGPUs
        self.runningJobs = runningJobs
        self.pendingJobs = pendingJobs
    }
}

public struct SlurmClusterSnapshot: Hashable, Codable, Sendable {
    public let currentUser: String?
    public let nodes: [SlurmNodeMetric]
    public let partitions: [SlurmPartitionSummary]
    public let jobs: [SlurmJobMetric]

    public init(
        currentUser: String?,
        nodes: [SlurmNodeMetric],
        partitions: [SlurmPartitionSummary],
        jobs: [SlurmJobMetric]
    ) {
        self.currentUser = currentUser
        self.nodes = nodes
        self.partitions = partitions
        self.jobs = jobs
    }

    public var gpuNodes: [SlurmNodeMetric] {
        nodes.filter { $0.totalGPUs > 0 }
    }

    public var totalGPUs: Int {
        gpuNodes.reduce(0) { $0 + $1.totalGPUs }
    }

    public var allocatedGPUs: Int {
        gpuNodes.reduce(0) { $0 + $1.allocatedGPUs }
    }

    public var freeGPUs: Int {
        gpuNodes.reduce(0) { $0 + $1.freeGPUs }
    }

    public var allocationPercent: Double {
        guard totalGPUs > 0 else { return 0 }
        return min(100.0, (Double(allocatedGPUs) / Double(totalGPUs)) * 100.0)
    }

    public var freeGPUNodes: [SlurmNodeMetric] {
        gpuNodes.filter(\.hasFreeGPUs)
    }

    public var runningJobs: [SlurmJobMetric] {
        jobs.filter { $0.state.isRunning }
    }

    public var pendingJobs: [SlurmJobMetric] {
        jobs.filter { $0.state.isPending }
    }

    public var myJobs: [SlurmJobMetric] {
        jobs.filter { $0.isOwnedBy(currentUser) }
    }

    public var myRunningJobs: [SlurmJobMetric] {
        runningJobs.filter { $0.isOwnedBy(currentUser) }
    }

    public var userSummaries: [SlurmUserUsage] {
        let grouped = Dictionary(grouping: jobs, by: \.user)
        return grouped.map { user, items in
            let running = items.filter { $0.state.isRunning }
            let pending = items.filter { $0.state.isPending }
            return SlurmUserUsage(
                user: user,
                runningGPUs: running.reduce(0) { $0 + $1.gpuCount },
                pendingGPUs: pending.reduce(0) { $0 + $1.gpuCount },
                runningJobs: running.count,
                pendingJobs: pending.count
            )
        }
        .sorted {
            if $0.runningGPUs != $1.runningGPUs { return $0.runningGPUs > $1.runningGPUs }
            if $0.pendingGPUs != $1.pendingGPUs { return $0.pendingGPUs > $1.pendingGPUs }
            return $0.user < $1.user
        }
    }

    public func runningJobs(onNode nodeName: String) -> [SlurmJobMetric] {
        runningJobs.filter { $0.expandedNodes.contains(nodeName) }
    }
}

public enum SlurmLiveProbeMethod: String, Sendable {
    case srunOverlap = "srun --overlap 作业内探测"
    case directNodeSSH = "登录节点 SSH 直连计算节点"
    case demo = "演示数据"
}

public struct SlurmLiveNodeSnapshot: Sendable {
    public let nodeName: String
    public let jobID: String?
    public let method: SlurmLiveProbeMethod
    public let gpus: [GPUMetric]
    public let latencyMs: Int
    public let timestamp: Date

    public init(
        nodeName: String,
        jobID: String?,
        method: SlurmLiveProbeMethod,
        gpus: [GPUMetric],
        latencyMs: Int,
        timestamp: Date = Date()
    ) {
        self.nodeName = nodeName
        self.jobID = jobID
        self.method = method
        self.gpus = gpus
        self.latencyMs = latencyMs
        self.timestamp = timestamp
    }
}
