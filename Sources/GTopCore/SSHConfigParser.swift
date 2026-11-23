import Foundation
import Darwin

public enum SSHConfigParserError: Error, LocalizedError, Sendable {
    case fileNotFound(String)
    case unreadable(String, String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "找不到 SSH 配置文件：\(path)"
        case .unreadable(let path, let reason):
            return "无法读取 SSH 配置文件 \(path)：\(reason)"
        }
    }
}

public struct SSHConfigParser: Sendable {
    public init() {}

    public func parseFile(at path: String) throws -> [SSHHostConfig] {
        let expandedPath = Self.expandTilde(path)
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SSHConfigParserError.fileNotFound(path)
        }
        var visited = Set<String>()
        var hostOrder: [String] = []
        var hostMap: [String: SSHHostConfig] = [:]
        try parseRecursive(
            filePath: expandedPath,
            baseDir: URL(fileURLWithPath: expandedPath).deletingLastPathComponent().path,
            visited: &visited,
            hostOrder: &hostOrder,
            hostMap: &hostMap
        )
        return hostOrder.compactMap { hostMap[$0] }
    }

    public func parseContent(
        _ content: String,
        sourceFile: String = "~/.ssh/config",
        includeBaseDir: String? = nil
    ) -> [SSHHostConfig] {
        var visited = Set<String>()
        var hostOrder: [String] = []
        var hostMap: [String: SSHHostConfig] = [:]
        parseLines(
            content: content,
            sourceFile: sourceFile,
            baseDir: includeBaseDir,
            visited: &visited,
            hostOrder: &hostOrder,
            hostMap: &hostMap
        )
        return hostOrder.compactMap { hostMap[$0] }
    }

    private func parseRecursive(
        filePath: String,
        baseDir: String,
        visited: inout Set<String>,
        hostOrder: inout [String],
        hostMap: inout [String: SSHHostConfig]
    ) throws {
        // Safety cap against overly broad Include globs (e.g., Include *)
        guard visited.count < 200 else { return }
        let canonical = URL(fileURLWithPath: filePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard !visited.contains(canonical) else { return }
        visited.insert(canonical)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: canonical),
           let fileSize = attrs[.size] as? NSNumber,
           fileSize.intValue > 2 * 1024 * 1024
        {
            return
        }

        let content: String
        do {
            content = try String(contentsOfFile: canonical, encoding: .utf8)
        } catch {
            throw SSHConfigParserError.unreadable(canonical, error.localizedDescription)
        }

        parseLines(
            content: content,
            sourceFile: canonical,
            baseDir: baseDir,
            visited: &visited,
            hostOrder: &hostOrder,
            hostMap: &hostMap
        )
    }

    private func parseLines(
        content: String,
        sourceFile: String,
        baseDir: String?,
        visited: inout Set<String>,
        hostOrder: inout [String],
        hostMap: inout [String: SSHHostConfig]
    ) {
        let lines = content.components(separatedBy: .newlines)
        var activeAliases: [String] = []
        var pendingCommentGroup: String?
        var inMatchBlock = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                pendingCommentGroup = nil
                continue
            }

            if trimmed.hasPrefix("#") {
                if let group = Self.extractCommentGroup(from: trimmed) {
                    pendingCommentGroup = group
                }
                continue
            }

            let stripped = Self.stripInlineComment(from: trimmed)
            guard !stripped.isEmpty else { continue }

            guard let (rawKey, rawValue) = Self.splitDirective(stripped) else {
                continue
            }
            let key = rawKey.lowercased()

            switch key {
            case "include":
                guard let baseDir else { continue }
                let patterns = Self.tokenizeArguments(rawValue)
                for pattern in patterns {
                    let resolvedFiles = Self.resolveIncludePattern(pattern, baseDir: baseDir)
                    for includedPath in resolvedFiles {
                        try? parseRecursive(
                            filePath: includedPath,
                            baseDir: baseDir,
                            visited: &visited,
                            hostOrder: &hostOrder,
                            hostMap: &hostMap
                        )
                    }
                }
                pendingCommentGroup = nil

            case "match":
                inMatchBlock = true
                activeAliases = []
                pendingCommentGroup = nil

            case "host":
                inMatchBlock = false
                let tokens = Self.tokenizeArguments(rawValue)
                var concreteAliases: [String] = []
                for token in tokens {
                    if Self.isConcreteHostAlias(token) {
                        concreteAliases.append(token)
                        if hostMap[token] == nil {
                            hostOrder.append(token)
                            hostMap[token] = SSHHostConfig(
                                alias: token,
                                sourceFile: sourceFile,
                                commentGroup: pendingCommentGroup
                            )
                        } else if hostMap[token]?.commentGroup == nil, let grp = pendingCommentGroup {
                            hostMap[token]?.commentGroup = grp
                        }
                    }
                }
                activeAliases = concreteAliases
                pendingCommentGroup = nil

            default:
                pendingCommentGroup = nil
                guard !inMatchBlock, !activeAliases.isEmpty else { continue }
                let value = Self.unquote(rawValue)
                for alias in activeAliases {
                    guard var entry = hostMap[alias] else { continue }
                    // OpenSSH uses first-obtained value for each parameter
                    switch key {
                    case "hostname":
                        if entry.hostName == nil { entry.hostName = value }
                    case "user":
                        if entry.user == nil { entry.user = value }
                    case "port":
                        if entry.port == nil, let portNum = Int(value) { entry.port = portNum }
                    case "proxyjump":
                        if entry.proxyJump == nil { entry.proxyJump = value }
                    case "identityfile":
                        if entry.identityFile == nil { entry.identityFile = value }
                    default:
                        break
                    }
                    hostMap[alias] = entry
                }
            }
        }
    }

    // MARK: - Parsing Helpers

    public static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(rest).path
        }
        return path
    }

    static func isConcreteHostAlias(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.hasPrefix("!") { return false }
        if token.contains("*") || token.contains("?") { return false }
        return true
    }

    static func extractCommentGroup(from commentLine: String) -> String? {
        // Supports "# @group: A100 Cluster", "# group: Lab", "# @tag: Prod"
        let body = commentLine.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" })
        let lower = body.lowercased()
        for prefix in ["@group:", "@group ", "group:", "@tag:", "tag:"] {
            if lower.hasPrefix(prefix) {
                let value = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func stripInlineComment(from line: String) -> String {
        var result = ""
        var inDoubleQuote = false
        var inSingleQuote = false

        for ch in line {
            if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                result.append(ch)
            } else if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                result.append(ch)
            } else if ch == "#" && !inDoubleQuote && !inSingleQuote {
                break
            } else {
                result.append(ch)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func splitDirective(_ line: String) -> (String, String)? {
        // OpenSSH accepts whitespace or '=' between keyword and arguments
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == " " || ch == "\t" || ch == "=" {
                break
            }
            idx = line.index(after: idx)
        }
        let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, idx < line.endIndex else { return nil }

        var rest = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !rest.isEmpty else { return nil }
        return (key, rest)
    }

    static func tokenizeArguments(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inDoubleQuote = false
        var inSingleQuote = false

        for ch in raw {
            if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if (ch == " " || ch == "\t") && !inDoubleQuote && !inSingleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2 &&
            ((trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
             (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")))
        {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    static func resolveIncludePattern(_ pattern: String, baseDir: String) -> [String] {
        let expanded: String
        if pattern.hasPrefix("~") {
            expanded = expandTilde(pattern)
        } else if pattern.hasPrefix("/") {
            expanded = pattern
        } else {
            expanded = URL(fileURLWithPath: baseDir).appendingPathComponent(pattern).path
        }

        var gt = glob_t()
        let flags = GLOB_TILDE | GLOB_BRACE
        let status = glob(expanded, flags, nil, &gt)
        defer { globfree(&gt) }

        guard status == 0, let pathv = gt.gl_pathv else {
            return []
        }

        var results: [String] = []
        let count = Int(gt.gl_matchc)
        for i in 0..<count {
            if let cStr = pathv[i] {
                let candidate = String(cString: cStr)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                    results.append(candidate)
                }
            }
        }
        return results.sorted()
    }
}
