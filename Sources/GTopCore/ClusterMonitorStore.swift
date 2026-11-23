import Foundation
import Observation

@MainActor
@Observable
public final class ClusterMonitorStore {
    public var allHosts: [SSHHostConfig] = []
    public var hostStates: [String: HostMonitorState] = [:]
    public var settings: AppSettings
    public var isPaused: Bool = false
    public var isDemoMode: Bool = false
    public var configError: String?
    public var lastConfigReload: Date?
    public var isRefreshingAll: Bool = false

    private let sshConfigParser = SSHConfigParser()
    private let ruleEngine = FilterRuleEngine()
    private let sshClient = SSHClient()
    private let settingsStore: SettingsStore
    private let demoProvider = DemoDataProvider()

    private var pollLoopTask: Task<Void, Never>?
    private var inFlightHosts: Set<String> = []
    private var lastConfigMTime: Date?
    private var demoTick: Int = 0
    /// Separate in-memory selection overrides for Demo Mode so user's real SSH selections are never modified
    private var demoOverrides: [String: ManualHostOverride] = [:]

    public init(settingsStore: SettingsStore = SettingsStore(), autoStart: Bool = true) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        reloadSSHConfig()
        if autoStart {
            startPollingLoop()
        }
    }

    public func startIfNeeded() {
        guard pollLoopTask == nil else { return }
        startPollingLoop()
    }

    // MARK: - Computed Views

    public var orderedHostStates: [HostMonitorState] {
        allHosts.compactMap { hostStates[$0.alias] }
    }

    public var monitoredHostStates: [HostMonitorState] {
        orderedHostStates.filter(\.isMonitored)
    }

    public var filteredOutHostStates: [HostMonitorState] {
        orderedHostStates.filter { !$0.isMonitored }
    }

    public var onlineHostCount: Int {
        monitoredHostStates.filter { $0.status.isOnline }.count
    }

    public var allOnlineGPUs: [(host: HostMonitorState, gpu: GPUMetric)] {
        monitoredHostStates
            .filter { $0.status.isOnline }
            .flatMap { host in host.gpus.map { (host: host, gpu: $0) } }
    }

    public var idleGPUs: [(host: HostMonitorState, gpu: GPUMetric)] {
        allOnlineGPUs.filter { $0.gpu.isIdle(threshold: settings.idleThreshold) }
    }

    public var allProcesses: [(host: HostMonitorState, gpu: GPUMetric, process: GPUProcess)] {
        allOnlineGPUs.flatMap { item in
            item.gpu.processes.map { (host: item.host, gpu: item.gpu, process: $0) }
        }
    }

    public var totalGPUCount: Int {
        allOnlineGPUs.count
    }

    public var averageClusterGPUUtilization: Double {
        let utils = allOnlineGPUs.compactMap(\.gpu.gpuUtilization)
        guard !utils.isEmpty else { return 0 }
        return utils.reduce(0, +) / Double(utils.count)
    }

    public var totalClusterMemoryUsedMiB: Double {
        allOnlineGPUs.compactMap(\.gpu.memoryUsedMiB).reduce(0, +)
    }

    public var totalClusterMemoryTotalMiB: Double {
        allOnlineGPUs.compactMap(\.gpu.memoryTotalMiB).reduce(0, +)
    }

    public var clusterMemoryPercent: Double {
        guard totalClusterMemoryTotalMiB > 0 else { return 0 }
        return (totalClusterMemoryUsedMiB / totalClusterMemoryTotalMiB) * 100.0
    }

    public var averageLatencyMs: Int? {
        let latencies = monitoredHostStates.compactMap(\.latencyMs)
        guard !latencies.isEmpty else { return nil }
        return latencies.reduce(0, +) / latencies.count
    }

    public var groupSummaries: [GroupSummary] {
        var buckets: [String: [HostMonitorState]] = [:]
        for host in monitoredHostStates {
            buckets[host.effectiveGroup, default: []].append(host)
        }
        return buckets.keys.sorted().map { name in
            let hosts = buckets[name] ?? []
            let online = hosts.filter { $0.status.isOnline }
            let totalGPUs = online.reduce(0) { $0 + $1.gpus.count }
            let freeGPUs = online.reduce(0) { $0 + $1.idleGPUs(threshold: settings.idleThreshold).count }
            return GroupSummary(
                name: name,
                totalHosts: hosts.count,
                onlineHosts: online.count,
                totalGPUs: totalGPUs,
                idleGPUs: freeGPUs
            )
        }
    }

    // MARK: - Configuration & Rules

    public func reloadSSHConfig() {
        if isDemoMode {
            allHosts = demoProvider.demoHostConfigs()
            configError = nil
            lastConfigReload = Date()
            reconcileHostStates()
            return
        }

        let path = settings.sshConfigPath
        let expanded = SSHConfigParser.expandTilde(path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
           let mtime = attrs[.modificationDate] as? Date
        {
            lastConfigMTime = mtime
        }

        do {
            let parsed = try sshConfigParser.parseFile(at: path)
            allHosts = parsed
            configError = nil
            lastConfigReload = Date()
            reconcileHostStates()
        } catch {
            allHosts = []
            hostStates = [:]
            configError = error.localizedDescription
            lastConfigReload = Date()
        }
    }

    public func toggleDemoMode() {
        isDemoMode.toggle()
        demoTick = 0
        hostStates = [:]
        inFlightHosts.removeAll()
        if isDemoMode {
            demoOverrides = [
                "gpu-h100-01": .forceEnable,
                "gpu-a100-02": .forceEnable,
                "lab-4090-workstation": .forceEnable,
                "gpu-a100-offline": .forceEnable
            ]
        } else {
            demoOverrides.removeAll()
        }
        reloadSSHConfig()
        Task { await refreshAllNow() }
    }

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let previousPath = settings.sshConfigPath
        mutate(&settings)
        settingsStore.save(settings)

        if settings.sshConfigPath != previousPath && !isDemoMode {
            reloadSSHConfig()
        } else {
            reconcileHostStates()
        }

        // Immediately trigger poll for newly enabled monitored hosts
        Task { await pollNewlyMonitoredHosts() }
    }

    public func toggleHostSelection(_ alias: String) {
        let currentlyMonitored = hostStates[alias]?.isMonitored ?? false
        setHostSelected(alias, selected: !currentlyMonitored)
    }

    public func setHostSelected(_ alias: String, selected: Bool) {
        if isDemoMode {
            demoOverrides[alias] = selected ? .forceEnable : .forceDisable
            reconcileHostStates()
            if selected {
                Task { await pollSingleHost(alias: alias) }
            }
            return
        }

        var withoutOverride = settings
        withoutOverride.manualOverrides.removeValue(forKey: alias)
        let host = allHosts.first(where: { $0.alias == alias })
        let autoMonitored = host.map { ruleEngine.evaluate(host: $0, settings: withoutOverride).isMonitored } ?? false

        if selected == autoMonitored {
            setManualOverride(for: alias, override: .auto)
        } else {
            setManualOverride(for: alias, override: selected ? .forceEnable : .forceDisable)
        }
    }

    public func setHostsSelected(_ aliases: [String], selected: Bool) {
        if isDemoMode {
            for alias in aliases {
                demoOverrides[alias] = selected ? .forceEnable : .forceDisable
            }
            reconcileHostStates()
            if selected {
                Task { await pollNewlyMonitoredHosts() }
            }
            return
        }

        updateSettings { s in
            for alias in aliases {
                var probe = s
                probe.manualOverrides.removeValue(forKey: alias)
                let host = allHosts.first(where: { $0.alias == alias })
                let autoMonitored = host.map { ruleEngine.evaluate(host: $0, settings: probe).isMonitored } ?? false
                if selected == autoMonitored {
                    s.manualOverrides.removeValue(forKey: alias)
                } else {
                    s.manualOverrides[alias] = selected ? .forceEnable : .forceDisable
                }
            }
        }
        if !selected {
            for alias in aliases {
                sshClient.closeControlMaster(alias: alias, sshConfigPath: settings.sshConfigPath)
            }
        }
    }

    public func setManualOverride(for alias: String, override: ManualHostOverride) {
        if isDemoMode {
            if override == .auto {
                demoOverrides.removeValue(forKey: alias)
            } else {
                demoOverrides[alias] = override
            }
            reconcileHostStates()
            if hostStates[alias]?.isMonitored == true {
                Task { await pollSingleHost(alias: alias) }
            }
            return
        }

        updateSettings { s in
            if override == .auto {
                s.manualOverrides.removeValue(forKey: alias)
            } else {
                s.manualOverrides[alias] = override
            }
        }
        if override == .forceDisable {
            sshClient.closeControlMaster(alias: alias, sshConfigPath: settings.sshConfigPath)
        }
    }

    public func setCustomGroup(for alias: String, group: String) {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSettings { s in
            if trimmed.isEmpty {
                s.customGroups.removeValue(forKey: alias)
            } else {
                s.customGroups[alias] = trimmed
            }
        }
    }

    public func addQuickIncludeRule(name: String, pattern: String, group: String, mode: RuleMatchMode = .glob) {
        let rule = HostFilterRule(
            name: name,
            isEnabled: true,
            action: .include,
            field: .alias,
            mode: mode,
            pattern: pattern,
            assignGroup: group
        )
        updateSettings { s in
            s.rules.append(rule)
        }
    }

    public func evaluatePreview(host: SSHHostConfig, with previewSettings: AppSettings) -> HostRuleEvaluation {
        ruleEngine.evaluate(host: host, settings: previewSettings)
    }

    private func effectiveEvaluationSettings() -> AppSettings {
        guard isDemoMode else { return settings }
        var demoSettings = settings
        demoSettings.manualOverrides = demoOverrides
        return demoSettings
    }

    private func reconcileHostStates() {
        let validAliases = Set(allHosts.map(\.alias))
        // Drop removed hosts
        hostStates = hostStates.filter { validAliases.contains($0.key) }

        let evalSettings = effectiveEvaluationSettings()
        for host in allHosts {
            let evaluation = ruleEngine.evaluate(host: host, settings: evalSettings)
            if var existing = hostStates[host.alias] {
                let becameMonitored = !existing.isMonitored && evaluation.isMonitored
                existing.config = host
                existing.isMonitored = evaluation.isMonitored
                existing.effectiveGroup = evaluation.group
                existing.matchReason = evaluation.reason
                existing.matchedRuleID = evaluation.matchedRuleID
                if !evaluation.isMonitored {
                    existing.status = .idle
                } else if becameMonitored {
                    existing.status = .connecting
                    existing.lastUpdated = nil
                }
                hostStates[host.alias] = existing
            } else {
                hostStates[host.alias] = HostMonitorState(
                    config: host,
                    status: evaluation.isMonitored ? .connecting : .idle,
                    isMonitored: evaluation.isMonitored,
                    effectiveGroup: evaluation.group,
                    matchReason: evaluation.reason,
                    matchedRuleID: evaluation.matchedRuleID
                )
            }
        }
    }

    // MARK: - Polling Scheduler

    public func togglePause() {
        isPaused.toggle()
        if !isPaused {
            Task { await refreshAllNow() }
        }
    }

    public func refreshAllNow() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        if isDemoMode {
            demoTick += 1
        } else {
            checkConfigFileModified()
        }

        let targets = monitoredHostStates.map(\.config.alias)
        await pollHostsConcurrently(aliases: targets)
    }

    public func refreshHost(_ alias: String) async {
        if isDemoMode {
            demoTick += 1
        }
        await pollSingleHost(alias: alias)
    }

    public func shutdown() {
        pollLoopTask?.cancel()
        pollLoopTask = nil
        if !isDemoMode {
            sshClient.closeAllControlMasters()
        }
    }

    private func startPollingLoop() {
        pollLoopTask?.cancel()
        pollLoopTask = Task { [weak self] in
            guard let self else { return }
            // Initial poll right after launch
            await self.refreshAllNow()

            while !Task.isCancelled {
                let interval = max(1.0, self.settings.refreshIntervalSeconds)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                if !self.isPaused {
                    await self.refreshAllNow()
                }
            }
        }
    }

    private func pollNewlyMonitoredHosts() async {
        let targets = monitoredHostStates
            .filter { $0.lastUpdated == nil || $0.status == .connecting }
            .map(\.config.alias)
        guard !targets.isEmpty else { return }
        await pollHostsConcurrently(aliases: targets)
    }

    private func checkConfigFileModified() {
        let expanded = SSHConfigParser.expandTilde(settings.sshConfigPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              let mtime = attrs[.modificationDate] as? Date
        else { return }

        if lastConfigMTime != mtime {
            reloadSSHConfig()
        }
    }

    private func pollHostsConcurrently(aliases: [String]) async {
        let maxConcurrency = 16
        var index = 0

        await withTaskGroup(of: Void.self) { group in
            while index < min(maxConcurrency, aliases.count) {
                let alias = aliases[index]
                index += 1
                group.addTask { [weak self] in
                    await self?.pollSingleHost(alias: alias)
                }
            }

            while await group.next() != nil {
                if index < aliases.count {
                    let alias = aliases[index]
                    index += 1
                    group.addTask { [weak self] in
                        await self?.pollSingleHost(alias: alias)
                    }
                }
            }
        }
    }

    private func pollSingleHost(alias: String) async {
        guard !inFlightHosts.contains(alias) else { return }
        guard var currentState = hostStates[alias], currentState.isMonitored else { return }

        inFlightHosts.insert(alias)
        defer { inFlightHosts.remove(alias) }

        if currentState.lastUpdated == nil && currentState.status == .idle {
            currentState.status = .connecting
            hostStates[alias] = currentState
        }

        let configPath = settings.sshConfigPath
        let timeout = settings.sshTimeoutSeconds
        let demoMode = isDemoMode
        let currentDemoTick = demoTick

        let result: Result<HostPollSnapshot, Error>
        if demoMode {
            result = demoProvider.generateSnapshot(for: alias, tick: currentDemoTick)
        } else {
            do {
                let snapshot = try await sshClient.pollHost(
                    alias: alias,
                    sshConfigPath: configPath,
                    timeoutSeconds: timeout
                )
                result = .success(snapshot)
            } catch {
                result = .failure(error)
            }
        }

        guard var updated = hostStates[alias] else { return }
        let maxHistory = max(20, settings.historyLength)

        switch result {
        case .success(let snapshot):
            updated.status = .online
            updated.remoteHostname = snapshot.remoteHostname
            updated.gpus = snapshot.gpus
            updated.latencyMs = snapshot.latencyMs
            updated.lastUpdated = snapshot.timestamp
            updated.consecutiveFailures = 0

            for gpu in snapshot.gpus {
                let sample = GPUSamplePoint(
                    timestamp: snapshot.timestamp,
                    gpuUtilization: gpu.gpuUtilization ?? 0,
                    memoryPercent: gpu.memoryPercent,
                    temperatureC: gpu.temperatureC ?? 0,
                    powerDrawW: gpu.powerDrawW ?? 0,
                    fanSpeedPercent: gpu.fanSpeedPercent
                )
                var series = updated.historyByGPU[gpu.id] ?? []
                series.append(sample)
                if series.count > maxHistory {
                    series.removeFirst(series.count - maxHistory)
                }
                updated.historyByGPU[gpu.id] = series
            }

            let hostSample = GPUSamplePoint(
                timestamp: snapshot.timestamp,
                gpuUtilization: updated.averageGPUUtilization,
                memoryPercent: updated.memoryPercent,
                temperatureC: updated.maxTemperatureC ?? 0,
                powerDrawW: updated.totalPowerDrawW,
                fanSpeedPercent: nil
            )
            updated.hostHistory.append(hostSample)
            if updated.hostHistory.count > maxHistory {
                updated.hostHistory.removeFirst(updated.hostHistory.count - maxHistory)
            }

        case .failure(let error):
            updated.consecutiveFailures += 1
            updated.lastUpdated = Date()
            if let smiError = error as? NvidiaSMIParseError, smiError == .noNvidiaSMI {
                updated.status = .noGPU
                updated.gpus = []
            } else {
                updated.status = .error(error.localizedDescription)
            }
        }

        hostStates[alias] = updated
    }
}

public struct GroupSummary: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let totalHosts: Int
    public let onlineHosts: Int
    public let totalGPUs: Int
    public let idleGPUs: Int
}
