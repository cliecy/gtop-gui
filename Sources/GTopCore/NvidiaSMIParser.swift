import Foundation

public enum NvidiaSMIParseError: Error, LocalizedError, Equatable, Sendable {
    case noNvidiaSMI
    case smiCommandFailed(String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .noNvidiaSMI:
            return "未检测到 nvidia-smi（主机可能未安装 NVIDIA 驱动或无 GPU）"
        case .smiCommandFailed(let detail):
            return "nvidia-smi 执行失败：\(detail)"
        case .emptyOutput:
            return "远端未返回有效监控数据"
        }
    }
}

public struct NvidiaSMIParseResult: Sendable {
    public let remoteHostname: String?
    public let gpus: [GPUMetric]
}

public struct NvidiaSMIParser: Sendable {
    public init() {}

    /// POSIX /bin/sh script sent via stdin to `/bin/sh -s` over SSH.
    /// Avoids all remote login-shell quoting issues (fish/csh/tcsh/zsh/bash) and fetches
    /// GPU metrics, compute/graphics processes, and per-PID user/cmdline in one round-trip.
    public static let remoteProbeScript: String = """
    PATH="$PATH:/usr/local/nvidia/bin:/usr/bin:/bin"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
      echo "__GTOP_ERR__:NO_NVIDIA_SMI"
      exit 0
    fi
    echo "__GTOP_META__"
    hostname 2>/dev/null || true
    echo "__GTOP_GPUS__"
    nvidia-smi --query-gpu=index,uuid,name,driver_version,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed,pstate --format=csv,noheader,nounits 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "__GTOP_SMI_RC__:$rc"
    fi
    echo "__GTOP_PROCS__"
    C=$(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null || true)
    [ -n "$C" ] && printf '%s\\n' "$C"
    echo "__GTOP_GPROCS__"
    G=$(nvidia-smi --query-graphics-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null || true)
    [ -n "$G" ] && printf '%s\\n' "$G"
    echo "__GTOP_PS__"
    PIDS=$(printf '%s\\n%s\\n' "$C" "$G" | awk -F',' 'NF>=2 {gsub(/ /, "", $2); if ($2 ~ /^[0-9]+$/) print $2}' | sort -u | tr '\\n' ',' | sed 's/,$//')
    if [ -n "$PIDS" ]; then
      ps -o pid=,user:32=,etime=,args= -p "$PIDS" 2>/dev/null || ps -o pid=,user=,args= -p "$PIDS" 2>/dev/null || true
    fi
    echo "__GTOP_END__"
    """

    public func parse(output: String) throws -> NvidiaSMIParseResult {
        let lines = output.components(separatedBy: .newlines)

        enum Section {
            case none, meta, gpus, computeProcs, graphicsProcs, ps
        }

        var section: Section = .none
        var metaLines: [String] = []
        var gpuLines: [String] = []
        var computeProcLines: [String] = []
        var graphicsProcLines: [String] = []
        var psLines: [String] = []
        var smiReturnCode: Int?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: CharacterSet.newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "__GTOP_ERR__:NO_NVIDIA_SMI" {
                throw NvidiaSMIParseError.noNvidiaSMI
            }
            if trimmed.hasPrefix("__GTOP_SMI_RC__:") {
                let codeStr = String(trimmed.dropFirst("__GTOP_SMI_RC__:".count))
                smiReturnCode = Int(codeStr)
                continue
            }

            switch trimmed {
            case "__GTOP_META__":
                section = .meta
                continue
            case "__GTOP_GPUS__":
                section = .gpus
                continue
            case "__GTOP_PROCS__":
                section = .computeProcs
                continue
            case "__GTOP_GPROCS__":
                section = .graphicsProcs
                continue
            case "__GTOP_PS__":
                section = .ps
                continue
            case "__GTOP_END__":
                section = .none
                continue
            default:
                break
            }

            guard !trimmed.isEmpty else { continue }
            switch section {
            case .meta: metaLines.append(trimmed)
            case .gpus: gpuLines.append(trimmed)
            case .computeProcs: computeProcLines.append(trimmed)
            case .graphicsProcs: graphicsProcLines.append(trimmed)
            case .ps: psLines.append(line)
            case .none: break
            }
        }

        if let rc = smiReturnCode, rc != 0 {
            let detail = gpuLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.localizedCaseInsensitiveContains("No devices were found") {
                throw NvidiaSMIParseError.noNvidiaSMI
            }
            throw NvidiaSMIParseError.smiCommandFailed(detail.isEmpty ? "exit code \(rc)" : detail)
        }

        if gpuLines.isEmpty {
            throw NvidiaSMIParseError.emptyOutput
        }

        // Check if nvidia-smi printed an error message instead of CSV
        if let first = gpuLines.first,
           first.localizedCaseInsensitiveContains("NVIDIA-SMI has failed") ||
           first.localizedCaseInsensitiveContains("Failed to initialize NVML")
        {
            throw NvidiaSMIParseError.smiCommandFailed(first)
        }

        let psMap = parsePSLines(psLines)

        var gpus: [GPUMetric] = []
        var uuidToIndex: [String: Int] = [:]

        for line in gpuLines {
            if let gpu = parseGPULine(line) {
                uuidToIndex[gpu.uuid] = gpu.index
                gpus.append(gpu)
            }
        }

        if gpus.isEmpty {
            let fallbackDetail = gpuLines.prefix(2).joined(separator: " ")
            throw NvidiaSMIParseError.smiCommandFailed(fallbackDetail)
        }

        var procsByUUID: [String: [GPUProcess]] = [:]
        for line in computeProcLines {
            if let proc = parseProcessLine(line, type: .compute, uuidToIndex: uuidToIndex, psMap: psMap) {
                procsByUUID[proc.gpuUUID, default: []].append(proc)
            }
        }
        for line in graphicsProcLines {
            if let proc = parseProcessLine(line, type: .graphics, uuidToIndex: uuidToIndex, psMap: psMap) {
                // Avoid duplicate if same PID already listed under compute on same GPU
                let existing = procsByUUID[proc.gpuUUID, default: []]
                if !existing.contains(where: { $0.pid == proc.pid && $0.type == .graphics }) {
                    procsByUUID[proc.gpuUUID, default: []].append(proc)
                }
            }
        }

        for i in gpus.indices {
            let uuid = gpus[i].uuid
            let sortedProcs = (procsByUUID[uuid] ?? []).sorted {
                ($0.usedMemoryMiB ?? 0) > ($1.usedMemoryMiB ?? 0)
            }
            gpus[i].processes = sortedProcs
        }

        gpus.sort { $0.index < $1.index }

        return NvidiaSMIParseResult(
            remoteHostname: metaLines.first,
            gpus: gpus
        )
    }

    // MARK: - Line Parsers

    private struct PSInfo {
        let user: String
        let elapsed: String?
        let commandLine: String
    }

    private func parseGPULine(_ line: String) -> GPUMetric? {
        let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cols.count >= 13, let idx = Int(cols[0]) else {
            return nil
        }

        return GPUMetric(
            index: idx,
            uuid: cols[1],
            name: cols[2],
            driverVersion: cols[3],
            gpuUtilization: parseOptionalDouble(cols[4]),
            memoryUtilization: parseOptionalDouble(cols[5]),
            memoryUsedMiB: parseOptionalDouble(cols[6]),
            memoryTotalMiB: parseOptionalDouble(cols[7]),
            temperatureC: parseOptionalDouble(cols[8]),
            powerDrawW: parseOptionalDouble(cols[9]),
            powerLimitW: parseOptionalDouble(cols[10]),
            fanSpeedPercent: parseOptionalDouble(cols[11]),
            pstate: parseOptionalString(cols[12])
        )
    }

    private func parseProcessLine(
        _ line: String,
        type: GPUProcessType,
        uuidToIndex: [String: Int],
        psMap: [Int: PSInfo]
    ) -> GPUProcess? {
        // Format: gpu_uuid, pid, process_name (may theoretically contain commas), used_gpu_memory
        let rawCols = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard rawCols.count >= 4 else { return nil }

        let uuid = rawCols[0]
        guard let pid = Int(rawCols[1]) else { return nil }
        let memMiB = parseOptionalDouble(rawCols[rawCols.count - 1])
        let procName = rawCols[2..<(rawCols.count - 1)].joined(separator: ", ")

        let ps = psMap[pid]
        let gpuIdx = uuidToIndex[uuid] ?? -1

        return GPUProcess(
            gpuUUID: uuid,
            gpuIndex: gpuIdx,
            pid: pid,
            type: type,
            user: ps?.user ?? "unknown",
            processName: procName,
            commandLine: ps?.commandLine ?? procName,
            usedMemoryMiB: memMiB,
            elapsedTime: ps?.elapsed
        )
    }

    private func parsePSLines(_ lines: [String]) -> [Int: PSInfo] {
        var result: [Int: PSInfo] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split first 3 whitespace-separated fields: PID, USER, ETIME (or ARGS)
            let parts = splitLeadingFields(trimmed, count: 3)
            guard parts.count >= 3, let pid = Int(parts[0]) else { continue }
            let user = parts[1]
            let rest = parts[2]

            // Detect whether 3rd token looks like ps etime (e.g., 02:15, 12:34:56, 3-04:12:01)
            let restParts = splitLeadingFields(rest, count: 2)
            if restParts.count == 2, Self.looksLikeElapsedTime(restParts[0]) {
                result[pid] = PSInfo(user: user, elapsed: restParts[0], commandLine: restParts[1])
            } else {
                result[pid] = PSInfo(user: user, elapsed: nil, commandLine: rest)
            }
        }
        return result
    }

    private func splitLeadingFields(_ text: String, count: Int) -> [String] {
        var fields: [String] = []
        var idx = text.startIndex

        while fields.count < count - 1 && idx < text.endIndex {
            while idx < text.endIndex && text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
            let start = idx
            while idx < text.endIndex && !text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
            if start < idx {
                fields.append(String(text[start..<idx]))
            }
        }

        while idx < text.endIndex && text[idx].isWhitespace {
            idx = text.index(after: idx)
        }
        if idx < text.endIndex {
            fields.append(String(text[idx...]))
        }
        return fields
    }

    private static func looksLikeElapsedTime(_ token: String) -> Bool {
        // Matches MM:SS, HH:MM:SS, D-HH:MM:SS
        guard token.contains(":") else { return false }
        return token.allSatisfy { $0.isNumber || $0 == ":" || $0 == "-" }
    }

    private func parseOptionalDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty ||
            trimmed.hasPrefix("[") ||
            trimmed.caseInsensitiveCompare("N/A") == .orderedSame
        {
            return nil
        }
        return Double(trimmed)
    }

    private func parseOptionalString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty ||
            trimmed.hasPrefix("[") ||
            trimmed.caseInsensitiveCompare("N/A") == .orderedSame
        {
            return nil
        }
        return trimmed
    }
}
