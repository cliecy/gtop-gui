import Testing
@testable import GTopCore

struct FilterRuleEngineTests {
    private let engine = FilterRuleEngine()

    @Test("Default settings never auto-connect unselected hosts; only explicitly selected hosts are monitored")
    func defaultSettingsNeverAutoConnectUnselectedHosts() {
        let defaults = AppSettings()
        let candidates = [
            SSHHostConfig(alias: "gpu-h100-01", hostName: "10.0.0.1"),
            SSHHostConfig(alias: "lab-server", hostName: "10.0.0.2"),
            SSHHostConfig(alias: "github.com", hostName: "github.com")
        ]
        for host in candidates {
            let eval = engine.evaluate(host: host, settings: defaults)
            #expect(!eval.isMonitored, "Host \(host.alias) should NOT be auto-monitored before user selects it")
        }

        // Once user explicitly selects a host, ONLY that host is monitored
        var selectedSettings = defaults
        selectedSettings.manualOverrides["gpu-h100-01"] = .forceEnable
        #expect(engine.evaluate(host: candidates[0], settings: selectedSettings).isMonitored)
        #expect(!engine.evaluate(host: candidates[1], settings: selectedSettings).isMonitored)
        #expect(!engine.evaluate(host: candidates[2], settings: selectedSettings).isMonitored)
    }

    @Test("Rule precedence: manual override > exclude > include")
    func includeExcludeAndOverridePrecedence() {
        let gpuHost = SSHHostConfig(
            alias: "gpu-a100-01",
            hostName: "10.0.0.11",
            user: "ml",
            sourceFile: "~/.ssh/conf.d/prod.conf"
        )
        let githubHost = SSHHostConfig(
            alias: "github-gpu-mirror",
            hostName: "github.com",
            user: "git",
            sourceFile: "~/.ssh/config"
        )
        let randomHost = SSHHostConfig(
            alias: "web-server-01",
            hostName: "10.0.0.99",
            user: "www",
            sourceFile: "~/.ssh/config"
        )

        var settings = AppSettings(
            rules: [
                HostFilterRule(
                    name: "Exclude GitHub",
                    action: .exclude,
                    field: .any,
                    mode: .glob,
                    pattern: "*github.com"
                ),
                HostFilterRule(
                    name: "Include GPUs",
                    action: .include,
                    field: .alias,
                    mode: .glob,
                    pattern: "*gpu*,*a100*",
                    assignGroup: "A100 集群"
                )
            ],
            autoConnectWhenNoIncludeRules: false
        )

        let evalGPU = engine.evaluate(host: gpuHost, settings: settings)
        #expect(evalGPU.isMonitored)
        #expect(evalGPU.group == "A100 集群")

        // Matches BOTH include and exclude -> exclude wins
        let evalGH = engine.evaluate(host: githubHost, settings: settings)
        #expect(!evalGH.isMonitored)

        // Matches nothing -> excluded by whitelist
        let evalWeb = engine.evaluate(host: randomHost, settings: settings)
        #expect(!evalWeb.isMonitored)

        // Force enable overrides exclude / unmatched
        settings.manualOverrides[randomHost.alias] = .forceEnable
        settings.customGroups[randomHost.alias] = "手动分组"
        let evalForced = engine.evaluate(host: randomHost, settings: settings)
        #expect(evalForced.isMonitored)
        #expect(evalForced.group == "手动分组")

        // Force disable overrides include
        settings.manualOverrides[gpuHost.alias] = .forceDisable
        let evalDisabled = engine.evaluate(host: gpuHost, settings: settings)
        #expect(!evalDisabled.isMonitored)
    }

    @Test("Regex matching works and invalid regex fails safely")
    func regexMatchingAndInvalidRegexSafety() {
        let host = SSHHostConfig(alias: "train-node-08", hostName: "10.12.0.8")
        let validRule = HostFilterRule(
            name: "Regex",
            action: .include,
            field: .alias,
            mode: .regex,
            pattern: #"^train-node-\d{2}$"#
        )
        #expect(FilterRuleEngine.isValidPattern(validRule.pattern, mode: .regex))
        #expect(engine.matches(rule: validRule, host: host))

        let invalidRule = HostFilterRule(
            name: "Bad Regex",
            action: .include,
            field: .alias,
            mode: .regex,
            pattern: "[unclosed"
        )
        #expect(!FilterRuleEngine.isValidPattern(invalidRule.pattern, mode: .regex))
        #expect(!engine.matches(rule: invalidRule, host: host))
    }

    @Test("Included config filename acts as fallback group name")
    func sourceFileFallbackGroup() {
        let host = SSHHostConfig(
            alias: "node-1",
            sourceFile: "/Users/me/.ssh/conf.d/stanford-lab.conf"
        )
        let settings = AppSettings(
            rules: [],
            autoConnectWhenNoIncludeRules: true
        )
        let eval = engine.evaluate(host: host, settings: settings)
        #expect(eval.isMonitored)
        #expect(eval.group == "stanford-lab")
    }
}
