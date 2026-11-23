import Foundation

public struct HostRuleEvaluation: Hashable, Sendable {
    public let isMonitored: Bool
    public let group: String
    public let matchedRuleID: UUID?
    public let reason: String

    public init(isMonitored: Bool, group: String, matchedRuleID: UUID?, reason: String) {
        self.isMonitored = isMonitored
        self.group = group
        self.matchedRuleID = matchedRuleID
        self.reason = reason
    }
}

public struct FilterRuleEngine: Sendable {
    public init() {}

    public func evaluate(host: SSHHostConfig, settings: AppSettings) -> HostRuleEvaluation {
        let enabledRules = settings.rules.filter(\.isEnabled)
        let excludeRules = enabledRules.filter { $0.action == .exclude }
        let includeRules = enabledRules.filter { $0.action == .include }

        // Determine matching include rule first for group assignment even if manually overridden
        let matchedInclude = includeRules.first { matches(rule: $0, host: host) }
        let matchedExclude = excludeRules.first { matches(rule: $0, host: host) }

        let resolvedGroup = resolveGroup(
            host: host,
            customGroup: settings.customGroups[host.alias],
            matchedIncludeRule: matchedInclude
        )

        // 1. Manual per-host override always takes precedence
        let overrideMode = settings.manualOverrides[host.alias] ?? .auto
        switch overrideMode {
        case .forceEnable:
            return HostRuleEvaluation(
                isMonitored: true,
                group: resolvedGroup,
                matchedRuleID: matchedInclude?.id,
                reason: "已手动选中"
            )
        case .forceDisable:
            return HostRuleEvaluation(
                isMonitored: false,
                group: resolvedGroup,
                matchedRuleID: nil,
                reason: "已手动取消"
            )
        case .auto:
            break
        }

        // 2. Exclude rules take precedence over include rules
        if let excludeRule = matchedExclude {
            return HostRuleEvaluation(
                isMonitored: false,
                group: resolvedGroup,
                matchedRuleID: excludeRule.id,
                reason: "命中排除规则：\(excludeRule.name)"
            )
        }

        // 3. Include rules (whitelist)
        if !includeRules.isEmpty {
            if let includeRule = matchedInclude {
                return HostRuleEvaluation(
                    isMonitored: true,
                    group: resolvedGroup,
                    matchedRuleID: includeRule.id,
                    reason: "命中包含规则：\(includeRule.name)"
                )
            } else {
                return HostRuleEvaluation(
                    isMonitored: false,
                    group: resolvedGroup,
                    matchedRuleID: nil,
                    reason: "未选中（未命中包含规则）"
                )
            }
        }

        // 4. No include rules enabled
        if settings.autoConnectWhenNoIncludeRules {
            return HostRuleEvaluation(
                isMonitored: true,
                group: resolvedGroup,
                matchedRuleID: nil,
                reason: "未配置包含规则（默认全连）"
            )
        } else {
            return HostRuleEvaluation(
                isMonitored: false,
                group: resolvedGroup,
                matchedRuleID: nil,
                reason: "未选中（不发起连接）"
            )
        }
    }

    public func matches(rule: HostFilterRule, host: SSHHostConfig) -> Bool {
        let rawPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPattern.isEmpty else { return false }

        // For non-regex modes, comma separates multiple OR patterns (e.g. "*gpu*,*a100*")
        let subPatterns: [String]
        if rule.mode == .regex {
            subPatterns = [rawPattern]
        } else {
            subPatterns = rawPattern
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let candidateValues = fieldValues(for: rule.field, host: host)
        guard !candidateValues.isEmpty else { return false }

        for subPattern in subPatterns {
            for value in candidateValues {
                if Self.matchSingle(value: value, pattern: subPattern, mode: rule.mode) {
                    return true
                }
            }
        }
        return false
    }

    public static func isValidPattern(_ pattern: String, mode: RuleMatchMode) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if mode == .regex {
            return (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) != nil
        }
        return true
    }

    private func resolveGroup(
        host: SSHHostConfig,
        customGroup: String?,
        matchedIncludeRule: HostFilterRule?
    ) -> String {
        if let custom = customGroup?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let ruleGroup = matchedIncludeRule?.assignGroup.trimmingCharacters(in: .whitespacesAndNewlines),
           !ruleGroup.isEmpty
        {
            return ruleGroup
        }
        if let commentGroup = host.commentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
           !commentGroup.isEmpty
        {
            return commentGroup
        }
        let fileName = host.sourceFileName
        if fileName != "config" && !fileName.isEmpty {
            let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            if !base.isEmpty {
                return base
            }
        }
        return "默认分组"
    }

    private func fieldValues(for field: RuleMatchField, host: SSHHostConfig) -> [String] {
        switch field {
        case .alias:
            return [host.alias]
        case .hostName:
            return host.hostName.map { [$0] } ?? []
        case .user:
            return host.user.map { [$0] } ?? []
        case .proxyJump:
            return host.proxyJump.map { [$0] } ?? []
        case .sourceFile:
            return [host.sourceFile, host.sourceFileName]
        case .any:
            var values = [host.alias, host.sourceFileName]
            if let h = host.hostName { values.append(h) }
            if let u = host.user { values.append(u) }
            if let p = host.proxyJump { values.append(p) }
            if let g = host.commentGroup { values.append(g) }
            return values
        }
    }

    private static func matchSingle(value: String, pattern: String, mode: RuleMatchMode) -> Bool {
        switch mode {
        case .contains:
            return value.localizedCaseInsensitiveContains(pattern)
        case .prefix:
            return value.lowercased().hasPrefix(pattern.lowercased())
        case .suffix:
            return value.lowercased().hasSuffix(pattern.lowercased())
        case .glob:
            let regexStr = globToRegex(pattern)
            guard let regex = try? NSRegularExpression(pattern: regexStr, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, options: [], range: range) != nil
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, options: [], range: range) != nil
        }
    }

    private static func globToRegex(_ glob: String) -> String {
        var regex = "^"
        for ch in glob {
            switch ch {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case ".", "+", "^", "$", "(", ")", "[", "]", "{", "}", "|", "\\":
                regex += "\\\(ch)"
            default:
                regex.append(ch)
            }
        }
        regex += "$"
        return regex
    }
}
