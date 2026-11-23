import Foundation
import os

public enum SSHClientError: Error, LocalizedError, Sendable {
    case timeout
    case authenticationFailed(String)
    case connectionFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "SSH 连接或采集超时"
        case .authenticationFailed(let detail):
            return "SSH 认证失败（请确认已配置免密密钥或 ssh-agent）：\(detail)"
        case .connectionFailed(let detail):
            return "SSH 连接失败：\(detail)"
        case .launchFailed(let detail):
            return "无法启动本地 ssh 进程：\(detail)"
        }
    }
}

/// Executes remote `nvidia-smi` probes via system `/usr/bin/ssh` with ControlMaster multiplexing.
/// Reusing system `ssh` ensures 100% compatibility with `~/.ssh/config` directives including
/// `ProxyJump`, `ProxyCommand`, `IdentityFile`, `Match`, and `ssh-agent`.
///
/// Crucially, stdout/stderr/stdin use temporary files instead of OS pipes so OpenSSH's
/// background `ControlPersist` mux daemon (which inherits open FDs) can NEVER cause
/// pipe-EOF deadlocks after the foreground `ssh` command exits.
public final class SSHClient: Sendable {
    private let parser = NvidiaSMIParser()
    private let controlDir: String
    private let ioDir: String
    private let probeScriptPath: String
    private let smiOnlyScriptPath: String

    public init() {
        let uid = getuid()
        self.controlDir = "/tmp/gtop-ssh-\(uid)"
        self.ioDir = "/tmp/gtop-ssh-\(uid)/io"
        self.probeScriptPath = "/tmp/gtop-ssh-\(uid)/probe.sh"
        self.smiOnlyScriptPath = "/tmp/gtop-ssh-\(uid)/smi-only.sh"

        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: controlDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.createDirectory(
            atPath: ioDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Clean up any stale temp IO files from previous sessions
        if let stale = try? fm.contentsOfDirectory(atPath: ioDir) {
            for item in stale {
                try? fm.removeItem(atPath: "\(ioDir)/\(item)")
            }
        }
        Self.ensureScript(NvidiaSMIParser.remoteProbeScript, at: probeScriptPath)
        Self.ensureScript(NvidiaSMIParser.nvidiaSMIOnlyProbeScript, at: smiOnlyScriptPath)
    }

    public func pollHost(
        alias: String,
        sshConfigPath: String,
        timeoutSeconds: Double
    ) async throws -> HostPollSnapshot {
        Self.ensureScript(NvidiaSMIParser.remoteProbeScript, at: probeScriptPath)

        let args = buildSSHBaseArgs(
            alias: alias,
            sshConfigPath: sshConfigPath,
            timeoutSeconds: timeoutSeconds
        ) + ["/bin/sh", "-s"]

        let start = Date()
        let result = try await runSubprocess(
            executablePath: "/usr/bin/ssh",
            arguments: args,
            stdinFilePath: probeScriptPath,
            timeoutSeconds: timeoutSeconds
        )
        let elapsedMs = max(1, Int(Date().timeIntervalSince(start) * 1000))

        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if result.exitCode != 0 && stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = Self.summarizeSSHStderr(stderr, exitCode: result.exitCode)
            if stderr.localizedCaseInsensitiveContains("Permission denied") ||
               stderr.localizedCaseInsensitiveContains("Host key verification failed")
            {
                throw SSHClientError.authenticationFailed(cleaned)
            }
            throw SSHClientError.connectionFailed(cleaned)
        }

        let parsed = try parser.parse(output: stdout)
        return HostPollSnapshot(
            remoteHostname: parsed.remoteHostname,
            remoteUsername: parsed.remoteUsername,
            gpus: parsed.gpus,
            slurm: parsed.slurm,
            latencyMs: elapsedMs,
            timestamp: Date()
        )
    }

    /// On-demand live `nvidia-smi` probe for a Slurm compute node (or inside a specific running job).
    /// Tries `srun --jobid=<id> --overlap` first when a jobID is given, falling back to compute-node SSH
    /// from the login node (or vice versa when probing a bare node).
    public func probeSlurmNodeLiveGPU(
        loginAlias: String,
        nodeName: String,
        jobID: String?,
        sshConfigPath: String,
        timeoutSeconds: Double
    ) async throws -> SlurmLiveNodeSnapshot {
        Self.ensureScript(NvidiaSMIParser.nvidiaSMIOnlyProbeScript, at: smiOnlyScriptPath)
        guard Self.isSafeSlurmToken(nodeName) else {
            throw SSHClientError.connectionFailed("非法的计算节点名称：\(nodeName)")
        }
        if let jobID, !Self.isSafeSlurmToken(jobID) {
            throw SSHClientError.connectionFailed("非法的作业 ID：\(jobID)")
        }

        let baseArgs = buildSSHBaseArgs(
            alias: loginAlias,
            sshConfigPath: sshConfigPath,
            timeoutSeconds: timeoutSeconds
        )

        var attempts: [(method: SlurmLiveProbeMethod, remoteCmd: String)] = []
        if let jobID {
            attempts.append((
                .srunOverlap,
                "srun --jobid=\(jobID) --overlap --nodes=1 --ntasks=1 -w \(nodeName) /bin/sh -s"
            ))
            attempts.append((
                .directNodeSSH,
                "ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \(nodeName) /bin/sh -s"
            ))
        } else {
            attempts.append((
                .directNodeSSH,
                "ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \(nodeName) /bin/sh -s"
            ))
        }

        var lastError: Error?
        for attempt in attempts {
            let start = Date()
            do {
                let result = try await runSubprocess(
                    executablePath: "/usr/bin/ssh",
                    arguments: baseArgs + [attempt.remoteCmd],
                    stdinFilePath: smiOnlyScriptPath,
                    timeoutSeconds: timeoutSeconds
                )
                let elapsedMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
                let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
                let stderr = String(data: result.stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let msg = Self.summarizeSSHStderr(stderr, exitCode: result.exitCode)
                    lastError = SSHClientError.connectionFailed(msg)
                    continue
                }

                let parsed = try parser.parse(output: stdout)
                return SlurmLiveNodeSnapshot(
                    nodeName: nodeName,
                    jobID: jobID,
                    method: attempt.method,
                    gpus: parsed.gpus,
                    latencyMs: elapsedMs,
                    timestamp: Date()
                )
            } catch {
                lastError = error
            }
        }

        let detail = lastError?.localizedDescription ?? "无法连接到计算节点 \(nodeName)"
        if jobID == nil && (detail.localizedCaseInsensitiveContains("Permission denied") || detail.localizedCaseInsensitiveContains("Access denied")) {
            throw SSHClientError.authenticationFailed(
                "集群限制直接 SSH 登录计算节点 \(nodeName)（\(detail)）。若你在此节点有运行中的作业，请从作业列表点击该作业通过 srun --overlap 探测。"
            )
        }
        throw lastError ?? SSHClientError.connectionFailed(detail)
    }

    private func buildSSHBaseArgs(
        alias: String,
        sshConfigPath: String,
        timeoutSeconds: Double
    ) -> [String] {
        let expandedConfig = SSHConfigParser.expandTilde(sshConfigPath)
        let connectTimeout = max(3, min(Int(timeoutSeconds) - 1, 6))
        let controlPath = "\(controlDir)/%C"

        var args: [String] = []
        if FileManager.default.fileExists(atPath: expandedConfig) {
            args += ["-F", expandedConfig]
        }
        args += [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=90s",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ClearAllForwardings=yes",
            alias
        ]
        return args
    }

    private static func isSafeSlurmToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
        }
    }

    public func closeControlMaster(alias: String, sshConfigPath: String) {
        let expandedConfig = SSHConfigParser.expandTilde(sshConfigPath)
        let controlPath = "\(controlDir)/%C"
        var args: [String] = []
        if FileManager.default.fileExists(atPath: expandedConfig) {
            args += ["-F", expandedConfig]
        }
        args += [
            "-o", "ControlPath=\(controlPath)",
            "-O", "exit",
            alias
        ]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = args
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    public func closeAllControlMasters() {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: controlDir) else {
            return
        }
        for entry in entries where entry != "io" && entry != "probe.sh" && entry != "smi-only.sh" {
            let socketPath = "\(controlDir)/\(entry)"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ["-S", socketPath, "-O", "exit", "placeholder"]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
        }
    }

    // MARK: - Pipe-Free Async Subprocess Execution

    struct ProcessOutput: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    func runSubprocess(
        executablePath: String,
        arguments: [String],
        stdinFilePath: String?,
        timeoutSeconds: Double
    ) async throws -> ProcessOutput {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: ioDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let token = UUID().uuidString
        let outURL = URL(fileURLWithPath: "\(ioDir)/out-\(token)")
        let errURL = URL(fileURLWithPath: "\(ioDir)/err-\(token)")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])

        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL)
        else {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
            throw SSHClientError.launchFailed("无法创建临时输出文件")
        }

        let inHandle: FileHandle
        if let stdinFilePath, let handle = FileHandle(forReadingAtPath: stdinFilePath) {
            inHandle = handle
        } else {
            inHandle = FileHandle.nullDevice
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = Self.buildSubprocessEnvironment()
            process.standardInput = inHandle
            process.standardOutput = outHandle
            process.standardError = errHandle

            final class State: @unchecked Sendable {
                var finished = false
                var timeoutTask: Task<Void, Never>?
            }
            let lock = OSAllocatedUnfairLock(initialState: State())

            let cleanupFiles: @Sendable () -> Void = {
                try? outHandle.close()
                try? errHandle.close()
                if inHandle !== FileHandle.nullDevice {
                    try? inHandle.close()
                }
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
            }

            process.terminationHandler = { proc in
                let shouldResume = lock.withLock { state -> Bool in
                    state.timeoutTask?.cancel()
                    state.timeoutTask = nil
                    if state.finished { return false }
                    state.finished = true
                    return true
                }
                guard shouldResume else {
                    cleanupFiles()
                    return
                }

                // Reading regular files NEVER blocks even if a background ControlPersist mux
                // child process inherited the open file descriptors.
                try? outHandle.synchronize()
                try? errHandle.synchronize()
                let stdoutData = (try? Data(contentsOf: outURL)) ?? Data()
                let stderrData = (try? Data(contentsOf: errURL)) ?? Data()
                cleanupFiles()

                continuation.resume(returning: ProcessOutput(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutData,
                    stderr: stderrData
                ))
            }

            let effectiveTimeout = max(1.0, timeoutSeconds)
            let timeoutTask = Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(effectiveTimeout))
                guard !Task.isCancelled else { return }

                let shouldTimeout = lock.withLock { state -> Bool in
                    state.timeoutTask = nil
                    if state.finished { return false }
                    state.finished = true
                    return true
                }
                guard shouldTimeout else { return }

                if process.isRunning {
                    process.terminate()
                    let pid = process.processIdentifier
                    Task.detached(priority: .utility) {
                        try? await Task.sleep(for: .seconds(1.0))
                        if process.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                }
                cleanupFiles()
                continuation.resume(throwing: SSHClientError.timeout)
            }
            lock.withLock { $0.timeoutTask = timeoutTask }

            do {
                try process.run()
            } catch {
                let shouldResume = lock.withLock { state -> Bool in
                    state.timeoutTask?.cancel()
                    state.timeoutTask = nil
                    if state.finished { return false }
                    state.finished = true
                    return true
                }
                cleanupFiles()
                if shouldResume {
                    continuation.resume(throwing: SSHClientError.launchFailed(error.localizedDescription))
                }
            }
        }
    }

    private static func ensureScript(_ script: String, at path: String) {
        let data = Data(script.utf8)
        let fm = FileManager.default
        if let existing = try? Data(contentsOf: URL(fileURLWithPath: path)), existing == data {
            return
        }
        fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private static func buildSubprocessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Enrich PATH when launched as a macOS GUI .app (where launchd omits /opt/homebrew/bin),
        // so ProxyCommand tools (cloudflared, nc, aws, gcloud, tailscale, etc.) work cleanly.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        var seen = Set<String>()
        for entry in existing + extraPaths where !entry.isEmpty && !seen.contains(entry) {
            seen.insert(entry)
            merged.append(entry)
        }
        env["PATH"] = merged.joined(separator: ":")
        env["SSH_ASKPASS_REQUIRE"] = "never"
        return env
    }

    private static func summarizeSSHStderr(_ stderr: String, exitCode: Int32) -> String {
        let lines = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        if let meaningful = lines.last {
            return meaningful
        }
        return "退出码 \(exitCode)"
    }
}
