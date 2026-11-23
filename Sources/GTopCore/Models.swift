import Foundation

// MARK: - SSH Host Configuration

public struct SSHHostConfig: Identifiable, Hashable, Codable, Sendable {
    public var id: String { alias }
    public let alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var proxyJump: String?
    public var identityFile: String?
    public var sourceFile: String
    public var commentGroup: String?

    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        proxyJump: String? = nil,
        identityFile: String? = nil,
        sourceFile: String = "~/.ssh/config",
        commentGroup: String? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.proxyJump = proxyJump
        self.identityFile = identityFile
        self.sourceFile = sourceFile
        self.commentGroup = commentGroup
    }

    public var sourceFileName: String {
        URL(fileURLWithPath: sourceFile).lastPathComponent
    }

    public var connectionSummary: String {
        let host = hostName ?? alias
        let userPrefix = user.map { "\($0)@" } ?? ""
        let portSuffix = (port != nil && port != 22) ? ":\(port!)" : ""
        return "\(userPrefix)\(host)\(portSuffix)"
    }
}

// MARK: - GPU Metrics & Processes

public enum GPUProcessType: String, Codable, Hashable, Sendable {
    case compute = "Compute"
    case graphics = "Graphics"

    public var shortLabel: String {
        switch self {
        case .compute: return "C"
        case .graphics: return "G"
        }
    }
}

public struct GPUProcess: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(gpuUUID)-\(pid)-\(type.rawValue)" }
    public let gpuUUID: String
    public let gpuIndex: Int
    public let pid: Int
    public let type: GPUProcessType
    public let user: String
    public let processName: String
    public let commandLine: String
    public let usedMemoryMiB: Double?
    public let elapsedTime: String?

    public init(
        gpuUUID: String,
        gpuIndex: Int,
        pid: Int,
        type: GPUProcessType,
        user: String,
        processName: String,
        commandLine: String,
        usedMemoryMiB: Double?,
        elapsedTime: String? = nil
    ) {
        self.gpuUUID = gpuUUID
        self.gpuIndex = gpuIndex
        self.pid = pid
        self.type = type
        self.user = user
        self.processName = processName
        self.commandLine = commandLine
        self.usedMemoryMiB = usedMemoryMiB
        self.elapsedTime = elapsedTime
    }

    public var displayName: String {
        let trimmed = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return URL(fileURLWithPath: processName).lastPathComponent
    }

    public var shortExecutable: String {
        let base = URL(fileURLWithPath: processName).lastPathComponent
        return base.isEmpty ? processName : base
    }
}

public struct GPUMetric: Identifiable, Hashable, Codable, Sendable {
    public var id: String { uuid.isEmpty ? "gpu-\(index)" : uuid }
    public let index: Int
    public let uuid: String
    public let name: String
    public let driverVersion: String
    public let gpuUtilization: Double?
    public let memoryUtilization: Double?
    public let memoryUsedMiB: Double?
    public let memoryTotalMiB: Double?
    public let temperatureC: Double?
    public let powerDrawW: Double?
    public let powerLimitW: Double?
    public let fanSpeedPercent: Double?
    public let pstate: String?
    public var processes: [GPUProcess]

    public init(
        index: Int,
        uuid: String,
        name: String,
        driverVersion: String,
        gpuUtilization: Double?,
        memoryUtilization: Double?,
        memoryUsedMiB: Double?,
        memoryTotalMiB: Double?,
        temperatureC: Double?,
        powerDrawW: Double?,
        powerLimitW: Double?,
        fanSpeedPercent: Double?,
        pstate: String?,
        processes: [GPUProcess] = []
    ) {
        self.index = index
        self.uuid = uuid
        self.name = name
        self.driverVersion = driverVersion
        self.gpuUtilization = gpuUtilization
        self.memoryUtilization = memoryUtilization
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
        self.temperatureC = temperatureC
        self.powerDrawW = powerDrawW
        self.powerLimitW = powerLimitW
        self.fanSpeedPercent = fanSpeedPercent
        self.pstate = pstate
        self.processes = processes
    }

    public var memoryPercent: Double {
        guard let used = memoryUsedMiB, let total = memoryTotalMiB, total > 0 else {
            return 0
        }
        return min(max((used / total) * 100.0, 0), 100)
    }

    public var powerPercent: Double? {
        guard let draw = powerDrawW, let limit = powerLimitW, limit > 0 else {
            return nil
        }
        return min(max((draw / limit) * 100.0, 0), 100)
    }

    public var shortName: String {
        var cleaned = name
        for prefix in ["NVIDIA GeForce ", "NVIDIA ", "Tesla "] {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
        }
        cleaned = cleaned
            .replacingOccurrences(of: "-SXM4-", with: " ")
            .replacingOccurrences(of: "-SXM5-", with: " ")
            .replacingOccurrences(of: "-PCIE-", with: " ")
            .replacingOccurrences(of: " PCIe", with: "")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    public func isIdle(threshold: IdleThreshold) -> Bool {
        let util = gpuUtilization ?? 0
        let memPct = memoryPercent
        let memMiB = memoryUsedMiB ?? 0
        let utilOK = util <= threshold.maxGPUUtilization
        let memOK = memPct <= threshold.maxMemoryPercent || memMiB <= threshold.maxMemoryMiB
        if threshold.requireNoProcesses && !processes.isEmpty {
            return false
        }
        return utilOK && memOK
    }
}

public struct GPUSamplePoint: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let gpuUtilization: Double
    public let memoryPercent: Double
    public let temperatureC: Double
    public let powerDrawW: Double
    public let fanSpeedPercent: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        gpuUtilization: Double,
        memoryPercent: Double,
        temperatureC: Double,
        powerDrawW: Double,
        fanSpeedPercent: Double?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.gpuUtilization = gpuUtilization
        self.memoryPercent = memoryPercent
        self.temperatureC = temperatureC
        self.powerDrawW = powerDrawW
        self.fanSpeedPercent = fanSpeedPercent
    }
}

// MARK: - Host Snapshot & Live State

public struct HostPollSnapshot: Sendable {
    public let remoteHostname: String?
    public let remoteUsername: String?
    public let gpus: [GPUMetric]
    public let slurm: SlurmClusterSnapshot?
    public let latencyMs: Int
    public let timestamp: Date

    public init(
        remoteHostname: String?,
        remoteUsername: String? = nil,
        gpus: [GPUMetric],
        slurm: SlurmClusterSnapshot? = nil,
        latencyMs: Int,
        timestamp: Date = Date()
    ) {
        self.remoteHostname = remoteHostname
        self.remoteUsername = remoteUsername
        self.gpus = gpus
        self.slurm = slurm
        self.latencyMs = latencyMs
        self.timestamp = timestamp
    }
}

public enum HostConnectionStatus: Hashable, Sendable {
    case idle
    case connecting
    case online
    case noGPU
    case paused
    case error(String)

    public var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .online: return "在线"
        case .noGPU: return "无 NVIDIA GPU"
        case .paused: return "已暂停"
        case .error: return "异常"
        }
    }

    public var errorDetail: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

public struct HostMonitorState: Identifiable, Sendable {
    public var id: String { config.alias }
    public var config: SSHHostConfig
    public var status: HostConnectionStatus
    public var remoteHostname: String?
    public var remoteUsername: String?
    public var gpus: [GPUMetric]
    public var slurm: SlurmClusterSnapshot?
    public var historyByGPU: [String: [GPUSamplePoint]]
    public var hostHistory: [GPUSamplePoint]
    public var lastUpdated: Date?
    public var latencyMs: Int?
    public var consecutiveFailures: Int
    public var isMonitored: Bool
    public var effectiveGroup: String
    public var matchReason: String
    public var matchedRuleID: UUID?

    public init(
        config: SSHHostConfig,
        status: HostConnectionStatus = .idle,
        remoteHostname: String? = nil,
        remoteUsername: String? = nil,
        gpus: [GPUMetric] = [],
        slurm: SlurmClusterSnapshot? = nil,
        historyByGPU: [String: [GPUSamplePoint]] = [:],
        hostHistory: [GPUSamplePoint] = [],
        lastUpdated: Date? = nil,
        latencyMs: Int? = nil,
        consecutiveFailures: Int = 0,
        isMonitored: Bool = false,
        effectiveGroup: String = "默认分组",
        matchReason: String = "",
        matchedRuleID: UUID? = nil
    ) {
        self.config = config
        self.status = status
        self.remoteHostname = remoteHostname
        self.remoteUsername = remoteUsername
        self.gpus = gpus
        self.slurm = slurm
        self.historyByGPU = historyByGPU
        self.hostHistory = hostHistory
        self.lastUpdated = lastUpdated
        self.latencyMs = latencyMs
        self.consecutiveFailures = consecutiveFailures
        self.isMonitored = isMonitored
        self.effectiveGroup = effectiveGroup
        self.matchReason = matchReason
        self.matchedRuleID = matchedRuleID
    }

    public var isSlurmCluster: Bool {
        slurm != nil
    }

    public var totalManagedGPUCount: Int {
        if let slurm, slurm.totalGPUs > 0 {
            return slurm.totalGPUs
        }
        return gpus.count
    }

    public var effectiveLoadPercent: Double {
        if let slurm, slurm.totalGPUs > 0 {
            return slurm.allocationPercent
        }
        return averageGPUUtilization
    }

    public var averageGPUUtilization: Double {
        let values = gpus.compactMap(\.gpuUtilization)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    public var totalMemoryUsedMiB: Double {
        gpus.compactMap(\.memoryUsedMiB).reduce(0, +)
    }

    public var totalMemoryTotalMiB: Double {
        gpus.compactMap(\.memoryTotalMiB).reduce(0, +)
    }

    public var memoryPercent: Double {
        guard totalMemoryTotalMiB > 0 else { return 0 }
        return (totalMemoryUsedMiB / totalMemoryTotalMiB) * 100.0
    }

    public var maxTemperatureC: Double? {
        gpus.compactMap(\.temperatureC).max()
    }

    public var totalPowerDrawW: Double {
        gpus.compactMap(\.powerDrawW).reduce(0, +)
    }

    public var totalPowerLimitW: Double {
        gpus.compactMap(\.powerLimitW).reduce(0, +)
    }

    public var driverVersion: String? {
        gpus.first?.driverVersion
    }

    public var allProcesses: [GPUProcess] {
        gpus.flatMap(\.processes)
    }

    public var activeUsers: [String] {
        Array(Set(allProcesses.map(\.user))).sorted()
    }

    public func idleGPUs(threshold: IdleThreshold) -> [GPUMetric] {
        gpus.filter { $0.isIdle(threshold: threshold) }
    }
}

// MARK: - Filter Rules & Settings

public enum RuleAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case include
    case exclude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .include: return "包含并监控"
        case .exclude: return "排除不连接"
        }
    }
}

public enum RuleMatchField: String, Codable, CaseIterable, Identifiable, Sendable {
    case alias
    case hostName
    case user
    case proxyJump
    case sourceFile
    case any

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .alias: return "Host 别名"
        case .hostName: return "HostName 地址"
        case .user: return "User 用户名"
        case .proxyJump: return "ProxyJump 跳板"
        case .sourceFile: return "配置文件名"
        case .any: return "任意字段"
        }
    }
}

public enum RuleMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case glob
    case contains
    case prefix
    case suffix
    case regex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .glob: return "通配符 (* / ?)"
        case .contains: return "包含文本"
        case .prefix: return "前缀匹配"
        case .suffix: return "后缀匹配"
        case .regex: return "正则表达式"
        }
    }
}

public struct HostFilterRule: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var action: RuleAction
    public var field: RuleMatchField
    public var mode: RuleMatchMode
    public var pattern: String
    public var assignGroup: String

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        action: RuleAction = .include,
        field: RuleMatchField = .alias,
        mode: RuleMatchMode = .glob,
        pattern: String,
        assignGroup: String = ""
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.action = action
        self.field = field
        self.mode = mode
        self.pattern = pattern
        self.assignGroup = assignGroup
    }
}

public enum ManualHostOverride: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case forceEnable
    case forceDisable

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "跟随规则"
        case .forceEnable: return "强制监控"
        case .forceDisable: return "强制禁用"
        }
    }
}

public struct IdleThreshold: Hashable, Codable, Sendable {
    public var maxGPUUtilization: Double
    public var maxMemoryPercent: Double
    public var maxMemoryMiB: Double
    public var requireNoProcesses: Bool

    public init(
        maxGPUUtilization: Double = 10,
        maxMemoryPercent: Double = 10,
        maxMemoryMiB: Double = 1024,
        requireNoProcesses: Bool = false
    ) {
        self.maxGPUUtilization = maxGPUUtilization
        self.maxMemoryPercent = maxMemoryPercent
        self.maxMemoryMiB = maxMemoryMiB
        self.requireNoProcesses = requireNoProcesses
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var sshConfigPath: String
    public var refreshIntervalSeconds: Double
    public var sshTimeoutSeconds: Double
    public var historyLength: Int
    public var rules: [HostFilterRule]
    public var manualOverrides: [String: ManualHostOverride]
    public var customGroups: [String: String]
    public var autoConnectWhenNoIncludeRules: Bool
    public var idleThreshold: IdleThreshold
    public var showMenuBarExtra: Bool

    public init(
        sshConfigPath: String = "~/.ssh/config",
        refreshIntervalSeconds: Double = 3.0,
        sshTimeoutSeconds: Double = 10.0,
        historyLength: Int = 120,
        rules: [HostFilterRule] = AppSettings.defaultRules,
        manualOverrides: [String: ManualHostOverride] = [:],
        customGroups: [String: String] = [:],
        autoConnectWhenNoIncludeRules: Bool = false,
        idleThreshold: IdleThreshold = IdleThreshold(),
        showMenuBarExtra: Bool = true
    ) {
        self.sshConfigPath = sshConfigPath
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.sshTimeoutSeconds = sshTimeoutSeconds
        self.historyLength = historyLength
        self.rules = rules
        self.manualOverrides = manualOverrides
        self.customGroups = customGroups
        self.autoConnectWhenNoIncludeRules = autoConnectWhenNoIncludeRules
        self.idleThreshold = idleThreshold
        self.showMenuBarExtra = showMenuBarExtra
    }

    public static var defaultRules: [HostFilterRule] {
        [
            HostFilterRule(
                name: "排除代码托管与常见非 GPU 主机",
                isEnabled: true,
                action: .exclude,
                field: .any,
                mode: .glob,
                pattern: "*github.com,*gitlab*,*bitbucket*,*gitee*,bastion*,jump*",
                assignGroup: ""
            ),
            HostFilterRule(
                name: "GPU 关键词示例（默认关闭，按需开启）",
                isEnabled: false,
                action: .include,
                field: .alias,
                mode: .glob,
                pattern: "*gpu*,*cuda*,*a100*,*h100*,*h200*,*4090*,*5090*,*3090*,*train*",
                assignGroup: "GPU 集群"
            )
        ]
    }
}

// MARK: - Formatting Helpers

public enum Formatters {
    public static func memoryMiB(_ mib: Double?) -> String {
        guard let mib else { return "—" }
        if mib >= 1024 {
            return String(format: "%.1f GiB", mib / 1024.0)
        }
        return String(format: "%.0f MiB", mib)
    }

    public static func memoryPair(usedMiB: Double?, totalMiB: Double?) -> String {
        guard let used = usedMiB, let total = totalMiB, total > 0 else { return "—" }
        if total >= 1024 {
            return String(format: "%.1f / %.1f GiB", used / 1024.0, total / 1024.0)
        }
        return String(format: "%.0f / %.0f MiB", used, total)
    }

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    public static func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°C", value)
    }

    public static func power(draw: Double?, limit: Double?) -> String {
        switch (draw, limit) {
        case let (d?, l?) where l > 0:
            return String(format: "%.0f / %.0fW", d, l)
        case let (d?, _):
            return String(format: "%.0fW", d)
        default:
            return "—"
        }
    }
}
