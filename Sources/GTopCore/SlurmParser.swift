import Foundation

public struct SlurmParser: Sendable {
    public init() {}

    public func parse(
        currentUser: String?,
        scontrolNodeLines: [String],
        sinfoNodeFallbackLines: [String],
        partitionLines: [String],
        jobsV2Lines: [String],
        jobsV1Lines: [String]
    ) -> SlurmClusterSnapshot {
        var nodes: [SlurmNodeMetric]
        if !scontrolNodeLines.isEmpty {
            nodes = scontrolNodeLines.compactMap(parseScontrolNodeLine)
        } else {
            nodes = parseSinfoNodeFallback(sinfoNodeFallbackLines)
        }

        let jobs: [SlurmJobMetric]
        if !jobsV2Lines.isEmpty {
            jobs = jobsV2Lines.compactMap(parseJobV2Line)
        } else {
            jobs = jobsV1Lines.compactMap(parseJobV1Line)
        }

        // If nodes came from sinfo fallback without allocated GPU counts, infer allocated GPUs from running jobs
        if scontrolNodeLines.isEmpty && !jobs.isEmpty {
            nodes = enrichFallbackNodesWithJobs(nodes: nodes, jobs: jobs)
        }

        nodes.sort { lhs, rhs in
            if (lhs.totalGPUs > 0) != (rhs.totalGPUs > 0) {
                return lhs.totalGPUs > 0
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let partitions = buildPartitionSummaries(partitionLines: partitionLines, nodes: nodes)

        let sortedJobs = jobs.sorted { lhs, rhs in
            let lMine = lhs.isOwnedBy(currentUser)
            let rMine = rhs.isOwnedBy(currentUser)
            if lMine != rMine { return lMine }
            if lhs.state.isRunning != rhs.state.isRunning { return lhs.state.isRunning }
            if lhs.gpuCount != rhs.gpuCount { return lhs.gpuCount > rhs.gpuCount }
            return lhs.jobID.localizedStandardCompare(rhs.jobID) == .orderedAscending
        }

        return SlurmClusterSnapshot(
            currentUser: currentUser,
            nodes: nodes,
            partitions: partitions,
            jobs: sortedJobs
        )
    }

    // MARK: - scontrol show node -o Parser

    func parseScontrolNodeLine(_ line: String) -> SlurmNodeMetric? {
        let kv = parseKeyValuePairs(line)
        guard let name = kv["NodeName"], !name.isEmpty else { return nil }

        let rawState = kv["State"] ?? "UNKNOWN"
        let stateCategory = classifyNodeState(rawState)

        let partitions = (kv["Partitions"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "") }
            .filter { !$0.isEmpty }

        let cpusAllocated = Int(kv["CPUAlloc"] ?? "") ?? 0
        let cpusTotal = Int(kv["CPUTot"] ?? "") ?? 0
        let cpuLoad = Double(kv["CPULoad"] ?? "")
        let memAlloc = Int(kv["AllocMem"] ?? "") ?? 0
        let memTotal = Int(kv["RealMemory"] ?? "") ?? 0
        let reason: String? = {
            guard let r = kv["Reason"], !r.isEmpty, r != "(null)", r != "none" else { return nil }
            return r
        }()

        // Parse GPU totals & allocations from CfgTRES / Gres and AllocTRES / GresUsed
        let cfgTRES = parseTRESGPUs(kv["CfgTRES"] ?? "")
        let gresTotal = parseGresGPUs(kv["Gres"] ?? "")
        let allocTRES = parseTRESGPUs(kv["AllocTRES"] ?? "")
        let gresUsed = parseGresGPUs(kv["GresUsed"] ?? "")

        let totalByType: [String: Int] = !cfgTRES.typed.isEmpty
            ? cfgTRES.typed
            : (!gresTotal.typed.isEmpty ? gresTotal.typed : [:])
        let totalCount = max(cfgTRES.total, gresTotal.total)

        let allocByType: [String: Int] = !allocTRES.typed.isEmpty
            ? allocTRES.typed
            : gresUsed.typed
        let allocCount = min(totalCount, max(allocTRES.total, gresUsed.total))

        let breakdown: [SlurmGPUTypeCount]
        let primaryGPUType: String
        if !totalByType.isEmpty {
            breakdown = totalByType.keys.sorted().map { rawType in
                let clean = formatGPUType(rawType)
                let tot = totalByType[rawType] ?? 0
                let alloc = min(tot, allocByType[rawType] ?? (totalByType.count == 1 ? allocCount : 0))
                return SlurmGPUTypeCount(type: clean, total: tot, allocated: alloc)
            }
            primaryGPUType = breakdown.map(\.type).joined(separator: " + ")
        } else if totalCount > 0 {
            breakdown = [SlurmGPUTypeCount(type: "GPU", total: totalCount, allocated: allocCount)]
            primaryGPUType = "GPU"
        } else {
            breakdown = []
            primaryGPUType = "无 GPU"
        }

        return SlurmNodeMetric(
            name: name,
            partitions: partitions,
            rawState: rawState,
            stateCategory: stateCategory,
            reason: reason,
            gpuType: primaryGPUType,
            totalGPUs: totalCount,
            allocatedGPUs: allocCount,
            gpuBreakdown: breakdown,
            cpusAllocated: cpusAllocated,
            cpusTotal: cpusTotal,
            cpuLoad: cpuLoad,
            memoryAllocatedMiB: memAlloc,
            memoryTotalMiB: memTotal
        )
    }

    // MARK: - sinfo Fallback Parser ("%N|%P|%T|%G|%C|%m|%O")

    private func parseSinfoNodeFallback(_ lines: [String]) -> [SlurmNodeMetric] {
        var nodeMap: [String: SlurmNodeMetric] = [:]
        var partMap: [String: Set<String>] = [:]

        for line in lines {
            let cols = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 6 else { continue }
            let name = cols[0]
            guard !name.isEmpty else { continue }

            let part = cols[1].replacingOccurrences(of: "*", with: "")
            if !part.isEmpty {
                partMap[name, default: []].insert(part)
            }

            if nodeMap[name] != nil { continue }

            let rawState = cols[2]
            let gres = parseGresGPUs(cols[3])
            let cpuParts = cols[4].split(separator: "/") // A/I/O/T
            let cpusAlloc = cpuParts.count >= 4 ? (Int(cpuParts[0]) ?? 0) : 0
            let cpusTot = cpuParts.count >= 4 ? (Int(cpuParts[3]) ?? 0) : 0
            let memTot = Int(cols[5]) ?? 0
            let load = cols.count >= 7 ? Double(cols[6]) : nil

            let primaryType: String
            if let first = gres.typed.keys.sorted().first {
                primaryType = formatGPUType(first)
            } else if gres.total > 0 {
                primaryType = "GPU"
            } else {
                primaryType = "无 GPU"
            }

            nodeMap[name] = SlurmNodeMetric(
                name: name,
                partitions: [],
                rawState: rawState,
                stateCategory: classifyNodeState(rawState),
                gpuType: primaryType,
                totalGPUs: gres.total,
                allocatedGPUs: 0,
                cpusAllocated: cpusAlloc,
                cpusTotal: cpusTot,
                cpuLoad: load,
                memoryAllocatedMiB: 0,
                memoryTotalMiB: memTot
            )
        }

        return nodeMap.values.map { node in
            SlurmNodeMetric(
                name: node.name,
                partitions: Array(partMap[node.name] ?? []).sorted(),
                rawState: node.rawState,
                stateCategory: node.stateCategory,
                reason: node.reason,
                gpuType: node.gpuType,
                totalGPUs: node.totalGPUs,
                allocatedGPUs: node.allocatedGPUs,
                gpuBreakdown: node.gpuBreakdown,
                cpusAllocated: node.cpusAllocated,
                cpusTotal: node.cpusTotal,
                cpuLoad: node.cpuLoad,
                memoryAllocatedMiB: node.memoryAllocatedMiB,
                memoryTotalMiB: node.memoryTotalMiB
            )
        }
    }

    private func enrichFallbackNodesWithJobs(
        nodes: [SlurmNodeMetric],
        jobs: [SlurmJobMetric]
    ) -> [SlurmNodeMetric] {
        var allocPerNode: [String: Int] = [:]
        for job in jobs where job.state.isRunning && job.gpuCount > 0 {
            let nodeCount = max(1, job.expandedNodes.count)
            let perNode = max(1, job.gpuCount / nodeCount)
            for nodeName in job.expandedNodes {
                allocPerNode[nodeName, default: 0] += perNode
            }
        }
        return nodes.map { node in
            let inferred = min(node.totalGPUs, allocPerNode[node.name] ?? (node.stateCategory == .allocated ? node.totalGPUs : 0))
            return SlurmNodeMetric(
                name: node.name,
                partitions: node.partitions,
                rawState: node.rawState,
                stateCategory: node.stateCategory,
                reason: node.reason,
                gpuType: node.gpuType,
                totalGPUs: node.totalGPUs,
                allocatedGPUs: inferred,
                gpuBreakdown: node.gpuBreakdown,
                cpusAllocated: node.cpusAllocated,
                cpusTotal: node.cpusTotal,
                cpuLoad: node.cpuLoad,
                memoryAllocatedMiB: node.memoryAllocatedMiB,
                memoryTotalMiB: node.memoryTotalMiB
            )
        }
    }

    // MARK: - squeue Job Parsers

    /// Format V2: JobID|UserName|Partition|State|TimeUsed|TimeLimit|NodeList|Reason|tres-alloc|tres-per-node|tres-per-job|NumNodes|NumCPUs|Name
    private func parseJobV2Line(_ line: String) -> SlurmJobMetric? {
        let cols = line.split(separator: "|", maxSplits: 13, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count >= 14, !cols[0].isEmpty else { return nil }

        let jobID = cols[0]
        let user = cols[1]
        let partition = cols[2]
        let rawState = cols[3]
        let elapsed = cols[4]
        let timeLimit = cols[5]
        let nodeListRaw = cols[6]
        let reason = cols[7]
        let tresAlloc = cols[8]
        let tresPerNode = cols[9]
        let tresPerJob = cols[10]
        let numNodes = max(1, Int(cols[11]) ?? 1)
        let numCPUs = Int(cols[12]) ?? 0
        let name = cols[13]

        let expanded = Self.expandNodeList(nodeListRaw)
        let state = classifyJobState(rawState)

        let allocParsed = parseTRESGPUs(tresAlloc)
        let perNodeParsed = parseJobTresSpec(tresPerNode)
        let perJobParsed = parseJobTresSpec(tresPerJob)

        let gpuCount: Int
        let gpuTypeRaw: String?
        if allocParsed.total > 0 {
            gpuCount = allocParsed.total
            gpuTypeRaw = allocParsed.typed.keys.sorted().first
        } else if perJobParsed.total > 0 {
            gpuCount = perJobParsed.total
            gpuTypeRaw = perJobParsed.type
        } else if perNodeParsed.total > 0 {
            gpuCount = perNodeParsed.total * max(numNodes, expanded.count)
            gpuTypeRaw = perNodeParsed.type
        } else {
            gpuCount = 0
            gpuTypeRaw = nil
        }

        return SlurmJobMetric(
            jobID: jobID,
            user: user,
            name: name.isEmpty ? jobID : name,
            partition: partition,
            rawState: rawState,
            state: state,
            elapsedTime: elapsed,
            timeLimit: timeLimit,
            nodeListRaw: nodeListRaw,
            expandedNodes: expanded,
            reason: cleanReason(reason),
            gpuCount: gpuCount,
            gpuType: gpuTypeRaw.map(formatGPUType),
            numNodes: numNodes,
            numCPUs: numCPUs
        )
    }

    /// Format V1 fallback: %i|%u|%P|%T|%M|%l|%N|%R|%b|%D|%C|%j
    private func parseJobV1Line(_ line: String) -> SlurmJobMetric? {
        let cols = line.split(separator: "|", maxSplits: 11, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count >= 12, !cols[0].isEmpty else { return nil }

        let jobID = cols[0]
        let user = cols[1]
        let partition = cols[2]
        let rawState = cols[3]
        let elapsed = cols[4]
        let timeLimit = cols[5]
        let nodeListRaw = cols[6]
        let reason = cols[7]
        let tresPerNode = cols[8]
        let numNodes = max(1, Int(cols[9]) ?? 1)
        let numCPUs = Int(cols[10]) ?? 0
        let name = cols[11]

        let expanded = Self.expandNodeList(nodeListRaw)
        let perNodeParsed = parseJobTresSpec(tresPerNode)
        let gpuCount = perNodeParsed.total * max(numNodes, expanded.count)

        return SlurmJobMetric(
            jobID: jobID,
            user: user,
            name: name.isEmpty ? jobID : name,
            partition: partition,
            rawState: rawState,
            state: classifyJobState(rawState),
            elapsedTime: elapsed,
            timeLimit: timeLimit,
            nodeListRaw: nodeListRaw,
            expandedNodes: expanded,
            reason: cleanReason(reason),
            gpuCount: gpuCount,
            gpuType: perNodeParsed.type.map(formatGPUType),
            numNodes: numNodes,
            numCPUs: numCPUs
        )
    }

    // MARK: - Partition Aggregation

    private func buildPartitionSummaries(
        partitionLines: [String],
        nodes: [SlurmNodeMetric]
    ) -> [SlurmPartitionSummary] {
        struct Meta {
            var isDefault: Bool
            var availability: String
            var timeLimit: String?
        }

        var metaMap: [String: Meta] = [:]
        for line in partitionLines {
            let cols = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2, !cols[0].isEmpty else { continue }
            let rawName = cols[0]
            let isDefault = rawName.hasSuffix("*")
            let cleanName = rawName.replacingOccurrences(of: "*", with: "")
            let avail = cols[1]
            let limit = cols.count >= 3 && !cols[2].isEmpty ? cols[2] : nil
            metaMap[cleanName] = Meta(isDefault: isDefault, availability: avail, timeLimit: limit)
        }

        var nodesByPart: [String: [SlurmNodeMetric]] = [:]
        for node in nodes {
            for part in node.partitions {
                nodesByPart[part, default: []].append(node)
            }
        }

        let allNames = Set(metaMap.keys).union(nodesByPart.keys)
        return allNames.map { name in
            let partNodes = nodesByPart[name] ?? []
            let meta = metaMap[name]
            let gpuNodes = partNodes.filter { $0.totalGPUs > 0 }
            let gpuTypes = Array(Set(gpuNodes.flatMap { $0.gpuBreakdown.map(\.type) })).sorted()
            return SlurmPartitionSummary(
                name: name,
                isDefault: meta?.isDefault ?? false,
                availability: meta?.availability ?? "up",
                timeLimit: meta?.timeLimit,
                totalNodes: partNodes.count,
                availableNodes: partNodes.filter { $0.stateCategory.isSchedulable }.count,
                totalGPUs: gpuNodes.reduce(0) { $0 + $1.totalGPUs },
                allocatedGPUs: gpuNodes.reduce(0) { $0 + $1.allocatedGPUs },
                freeGPUs: gpuNodes.reduce(0) { $0 + $1.freeGPUs },
                gpuTypes: gpuTypes
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalGPUs != rhs.totalGPUs { return lhs.totalGPUs > rhs.totalGPUs }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name < rhs.name
        }
    }

    // MARK: - Slurm Node Hostlist Expansion

    /// Expands Slurm compressed hostlists such as `gpu-[01-03,05],a100-02` into concrete node names.
    public static func expandNodeList(_ raw: String, limit: Int = 512) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "N/A",
              trimmed != "(null)",
              !trimmed.hasPrefix("(")
        else { return [] }

        // Split on top-level commas (outside `[...]`)
        var groups: [String] = []
        var current = ""
        var bracketDepth = 0
        for ch in trimmed {
            if ch == "[" {
                bracketDepth += 1
                current.append(ch)
            } else if ch == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(ch)
            } else if ch == "," && bracketDepth == 0 {
                if !current.isEmpty {
                    groups.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { groups.append(current) }

        var expanded: [String] = []
        for group in groups {
            if expanded.count >= limit { break }
            expandSingleGroup(group, into: &expanded, limit: limit)
        }
        return expanded
    }

    private static func expandSingleGroup(_ token: String, into out: inout [String], limit: Int) {
        guard let openIdx = token.firstIndex(of: "["),
              let closeIdx = token[openIdx...].firstIndex(of: "]")
        else {
            out.append(token)
            return
        }

        let prefix = String(token[..<openIdx])
        let rangeBody = String(token[token.index(after: openIdx)..<closeIdx])
        let suffix = String(token[token.index(after: closeIdx)...])

        for part in rangeBody.split(separator: ",") {
            if out.count >= limit { return }
            let item = String(part)
            if let dashIdx = item.firstIndex(of: "-") {
                let startStr = String(item[..<dashIdx])
                let endStr = String(item[item.index(after: dashIdx)...])
                if let start = Int(startStr), let end = Int(endStr), start <= end {
                    let padWidth = startStr.hasPrefix("0") ? startStr.count : 0
                    for num in start...end {
                        if out.count >= limit { return }
                        let formatted = padWidth > 0
                            ? String(format: "%0\(padWidth)d", num)
                            : "\(num)"
                        let combined = "\(prefix)\(formatted)\(suffix)"
                        if combined.contains("[") {
                            expandSingleGroup(combined, into: &out, limit: limit)
                        } else {
                            out.append(combined)
                        }
                    }
                    continue
                }
            }
            let combined = "\(prefix)\(item)\(suffix)"
            if combined.contains("[") {
                expandSingleGroup(combined, into: &out, limit: limit)
            } else {
                out.append(combined)
            }
        }
    }

    // MARK: - Key-Value, GRES, and TRES Helpers

    /// Parses `scontrol show node -o` space-separated `Key=Value` tokens while keeping
    /// multi-word values (like `Reason=GPU XID error [admin@2026-11-20]`) intact.
    func parseKeyValuePairs(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        var currentKey: String?
        var currentVal = ""

        for rawToken in tokens {
            let token = String(rawToken)
            if let eqIdx = token.firstIndex(of: "=") {
                let candidateKey = String(token[..<eqIdx])
                if !candidateKey.isEmpty && candidateKey.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    if let key = currentKey {
                        result[key] = currentVal
                    }
                    currentKey = candidateKey
                    currentVal = String(token[token.index(after: eqIdx)...])
                    continue
                }
            }
            if currentKey != nil {
                currentVal += (currentVal.isEmpty ? "" : " ") + token
            }
        }
        if let key = currentKey {
            result[key] = currentVal
        }
        return result
    }

    /// Parses Slurm TRES strings like `cpu=64,mem=256G,gres/gpu=4,gres/gpu:a100=4`
    func parseTRESGPUs(_ tres: String) -> (total: Int, typed: [String: Int]) {
        guard !tres.isEmpty, tres != "(null)", tres != "N/A" else { return (0, [:]) }
        var genericTotal = 0
        var typed: [String: Int] = [:]

        for entry in tres.split(separator: ",") {
            let pair = entry.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let countStr = pair[1].trimmingCharacters(in: .whitespaces)
            guard let count = Int(countStr), count > 0 else { continue }

            if key == "gres/gpu" {
                genericTotal = max(genericTotal, count)
            } else if key.hasPrefix("gres/gpu:") {
                let gpuType = String(key.dropFirst("gres/gpu:".count))
                if !gpuType.isEmpty {
                    typed[gpuType, default: 0] += count
                }
            }
        }

        let typedSum = typed.values.reduce(0, +)
        return (max(genericTotal, typedSum), typed)
    }

    /// Parses Slurm GRES strings like `gpu:a100:8(S:0-1)`, `gpu:8`, `gpu:h100:4(IDX:0-3),gpu:a100:2(IDX:4-5)`
    func parseGresGPUs(_ gres: String) -> (total: Int, typed: [String: Int]) {
        guard !gres.isEmpty, gres != "(null)", gres != "N/A" else { return (0, [:]) }
        var total = 0
        var typed: [String: Int] = [:]

        for rawItem in gres.split(separator: ",") {
            var item = rawItem.trimmingCharacters(in: .whitespaces)
            // Strip parenthesized socket/index annotations like (S:0-1) or (IDX:0-3)
            if let paren = item.firstIndex(of: "(") {
                item = String(item[..<paren])
            }
            let parts = item.split(separator: ":").map(String.init)
            guard let head = parts.first?.lowercased(), head == "gpu" else { continue }

            if parts.count == 2, let count = Int(parts[1]) {
                total += count
            } else if parts.count >= 3, let count = Int(parts.last ?? "") {
                let typeName = parts[1..<(parts.count - 1)].joined(separator: ":").lowercased()
                typed[typeName, default: 0] += count
                total += count
            } else if parts.count == 1 {
                total += 1
            }
        }

        return (total, typed)
    }

    /// Parses squeue `tres-per-node` / `tres-per-job` specs like `gres/gpu:a100:4`, `gres:gpu:2`, `gpu:h100:8`
    func parseJobTresSpec(_ spec: String) -> (total: Int, type: String?) {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "N/A", trimmed != "(null)" else { return (0, nil) }

        var total = 0
        var foundType: String?

        for rawItem in trimmed.split(separator: ",") {
            var item = rawItem.trimmingCharacters(in: .whitespaces)
            if let paren = item.firstIndex(of: "(") {
                item = String(item[..<paren])
            }
            // Normalize `gres/gpu:a100:4` or `gres:gpu:a100:4` or `gres/gpu=4`
            let lower = item.lowercased()
            if lower.contains("gpu") {
                if let eq = item.firstIndex(of: "=") {
                    let lhs = String(item[..<eq]).lowercased()
                    let rhs = String(item[item.index(after: eq)...])
                    if let n = Int(rhs) {
                        total += n
                        if let colon = lhs.lastIndex(of: ":") {
                            let t = String(lhs[lhs.index(after: colon)...])
                            if !t.isEmpty && t != "gpu" { foundType = t }
                        }
                    }
                    continue
                }

                let normalized = item
                    .replacingOccurrences(of: "gres/gpu", with: "gpu", options: .caseInsensitive)
                    .replacingOccurrences(of: "gres:gpu", with: "gpu", options: .caseInsensitive)
                let parts = normalized.split(separator: ":").map(String.init)
                guard parts.first?.lowercased() == "gpu" else { continue }
                if parts.count == 2, let n = Int(parts[1]) {
                    total += n
                } else if parts.count >= 3, let n = Int(parts.last ?? "") {
                    total += n
                    let t = parts[1..<(parts.count - 1)].joined(separator: ":")
                    if !t.isEmpty { foundType = t }
                } else if parts.count == 1 {
                    total += 1
                }
            }
        }
        return (total, foundType)
    }

    private func classifyNodeState(_ raw: String) -> SlurmNodeStateCategory {
        let upper = raw.uppercased()
        if upper.contains("DOWN") || upper.contains("FAIL") || upper.contains("NOT_RESPONDING") || upper.contains("POWERED_DOWN") {
            return .down
        }
        if upper.contains("DRAIN") || upper.contains("MAINT") || upper.contains("RESERVED") || upper.contains("RESV") {
            return .draining
        }
        if upper.contains("IDLE") {
            return .idle
        }
        if upper.contains("MIX") {
            return .mixed
        }
        if upper.contains("ALLOC") || upper.contains("COMPLETING") {
            return .allocated
        }
        return .other
    }

    private func classifyJobState(_ raw: String) -> SlurmJobState {
        let upper = raw.uppercased()
        switch upper {
        case "R", "RUNNING":
            return .running
        case "PD", "PENDING", "CF", "CONFIGURING":
            return .pending
        case "CG", "COMPLETING":
            return .completing
        default:
            return .other(raw)
        }
    }

    private func cleanReason(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "None" || trimmed == "(None)" || trimmed == "N/A" {
            return ""
        }
        return trimmed
    }

    private func formatGPUType(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "GPU" }
        cleaned = cleaned
            .replacingOccurrences(of: "nvidia_", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "geforce_", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "tesla_", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
        let upper = cleaned.uppercased()
        // Keep well-known short GPU names uppercase (a100 -> A100, h100 -> H100, rtx 4090 -> RTX 4090)
        return upper
    }
}
