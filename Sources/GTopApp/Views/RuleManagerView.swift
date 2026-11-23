import AppKit
import GTopCore
import SwiftUI

struct RuleManagerView: View {
    @Bindable var store: ClusterMonitorStore
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: Int = 0
    @State private var selectedRuleID: UUID?
    @State private var hostSearch: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("选择主机、过滤规则与设置")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $activeTab) {
                    Text("选择监控主机 (\(store.monitoredHostStates.count)/\(store.allHosts.count))").tag(0)
                    Text("自动过滤规则 (\(store.settings.rules.count))").tag(1)
                    Text("常规与 SSH 设置").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 470)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            Group {
                switch activeTab {
                case 0:
                    hostsOverrideTab
                case 1:
                    rulesTab
                default:
                    generalSettingsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer
            HStack {
                Text("仅连接已选中的主机：当前监控 \(store.monitoredHostStates.count) / \(store.allHosts.count) 台")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重新解析 SSH Config") {
                    store.reloadSSHConfig()
                }
                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 880, minHeight: 580)
        .onAppear {
            if selectedRuleID == nil {
                selectedRuleID = store.settings.rules.first?.id
            }
        }
    }

    // MARK: - Tab 1: Filter & Group Rules

    private var rulesTab: some View {
        HSplitView {
            // Left: Rule list
            VStack(spacing: 0) {
                HStack {
                    Text("规则列表（优先级：手动覆写 > 排除 > 包含）")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addNewRule(action: .include)
                    } label: {
                        Label("添加包含", systemImage: "plus")
                            .font(.caption)
                    }
                    .controlSize(.small)

                    Button {
                        addNewRule(action: .exclude)
                    } label: {
                        Label("添加排除", systemImage: "minus.circle")
                            .font(.caption)
                    }
                    .controlSize(.small)
                }
                .padding(10)

                Divider()

                List(selection: $selectedRuleID) {
                    ForEach(store.settings.rules) { rule in
                        HStack(spacing: 8) {
                            Toggle("", isOn: bindingForRule(rule.id, keyPath: \.isEnabled, fallback: false))
                                .labelsHidden()
                                .toggleStyle(.checkbox)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    BadgePill(
                                        text: rule.action == .include ? "包含" : "排除",
                                        color: rule.action == .include ? .green : .red
                                    )
                                    Text(rule.name.isEmpty ? "未命名规则" : rule.name)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                }
                                HStack(spacing: 6) {
                                    Text("\(rule.field.displayName) · \(rule.pattern)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if !rule.assignGroup.isEmpty && rule.action == .include {
                                        BadgePill(text: rule.assignGroup, color: .blue)
                                    }
                                }
                            }

                            Spacer()

                            let matchedCount = matchCount(for: rule)
                            Text("\(matchedCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(rule.id)
                    }
                }
                .listStyle(.inset)

                Divider()

                HStack {
                    Toggle(
                        "未启用包含规则时自动连接全部未排除主机",
                        isOn: Binding(
                            get: { store.settings.autoConnectWhenNoIncludeRules },
                            set: { val in store.updateSettings { $0.autoConnectWhenNoIncludeRules = val } }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    Spacer()
                }
                .padding(10)
            }
            .frame(minWidth: 340, idealWidth: 370)

            // Right: Rule Editor + Real-time Preview
            if let ruleID = selectedRuleID,
               let rule = store.settings.rules.first(where: { $0.id == ruleID })
            {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("编辑规则")
                                .font(.headline)
                            Spacer()
                            Button(role: .destructive) {
                                deleteRule(ruleID)
                            } label: {
                                Label("删除规则", systemImage: "trash")
                            }
                            .controlSize(.small)
                        }

                        Form {
                            TextField("规则名称", text: bindingForRule(ruleID, keyPath: \.name, fallback: ""))

                            Picker("动作", selection: bindingForRule(ruleID, keyPath: \.action, fallback: .include)) {
                                ForEach(RuleAction.allCases) { action in
                                    Text(action.displayName).tag(action)
                                }
                            }
                            .pickerStyle(.segmented)

                            Picker("匹配字段", selection: bindingForRule(ruleID, keyPath: \.field, fallback: .alias)) {
                                ForEach(RuleMatchField.allCases) { field in
                                    Text(field.displayName).tag(field)
                                }
                            }

                            Picker("匹配方式", selection: bindingForRule(ruleID, keyPath: \.mode, fallback: .glob)) {
                                ForEach(RuleMatchMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                TextField("匹配表达式", text: bindingForRule(ruleID, keyPath: \.pattern, fallback: ""))
                                    .font(.system(.body, design: .monospaced))
                                if !FilterRuleEngine.isValidPattern(rule.pattern, mode: rule.mode) {
                                    Text(rule.mode == .regex ? "正则表达式语法无效" : "请输入匹配模式")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                } else if rule.mode != .regex {
                                    Text("支持英文逗号分隔多个条件（逻辑或），例如：*gpu*,*a100*,lab-*")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if rule.action == .include {
                                TextField("自动分配分组（可选）", text: bindingForRule(ruleID, keyPath: \.assignGroup, fallback: ""))
                            }
                        }
                        .formStyle(.grouped)

                        // Live Match Preview
                        let engine = FilterRuleEngine()
                        let matchedHosts = store.allHosts.filter { engine.matches(rule: rule, host: $0) }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("实时匹配预览")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("命中 \(matchedHosts.count) / \(store.allHosts.count) 台主机")
                                    .font(.caption)
                                    .foregroundStyle(matchedHosts.isEmpty ? Color.secondary : (rule.action == .include ? Color.green : Color.red))
                            }

                            if matchedHosts.isEmpty {
                                Text("当前 SSH 配置中没有主机命中此规则。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(10)
                            } else {
                                VStack(spacing: 4) {
                                    ForEach(matchedHosts) { host in
                                        let eval = store.evaluatePreview(host: host, with: store.settings)
                                        HStack {
                                            Text(host.alias)
                                                .font(.callout.weight(.medium))
                                            if let hn = host.hostName {
                                                Text(hn)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            BadgePill(
                                                text: eval.isMonitored ? "最终：监控 (\(eval.group))" : "最终：已跳过",
                                                color: eval.isMonitored ? .green : .secondary
                                            )
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "选择或创建一条规则",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("在左侧选择规则以编辑匹配条件和自动分组。")
                )
            }
        }
    }

    // MARK: - Tab 0: Direct Host Selection & Grouping

    private var hostsOverrideTab: some View {
        let query = hostSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = store.orderedHostStates.filter { state in
            guard !query.isEmpty else { return true }
            return state.config.alias.localizedCaseInsensitiveContains(query) ||
                (state.config.hostName?.localizedCaseInsensitiveContains(query) ?? false) ||
                state.effectiveGroup.localizedCaseInsensitiveContains(query) ||
                state.config.sourceFileName.localizedCaseInsensitiveContains(query)
        }

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("搜索主机别名 / HostName / 配置文件…", text: $hostSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Button("勾选当前列表 (\(hosts.count))") {
                    store.setHostsSelected(hosts.map(\.config.alias), selected: true)
                }
                .disabled(hosts.isEmpty)

                Button("取消勾选当前列表") {
                    store.setHostsSelected(hosts.map(\.config.alias), selected: false)
                }
                .disabled(hosts.isEmpty)

                Spacer()

                Button("恢复全部跟随规则") {
                    store.updateSettings { $0.manualOverrides.removeAll() }
                }
                .disabled(store.settings.manualOverrides.isEmpty)
            }
            .padding(12)

            Divider()

            List(hosts) { state in
                HStack(spacing: 12) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { state.isMonitored },
                            set: { selected in
                                store.setHostSelected(state.config.alias, selected: selected)
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(state.config.alias)
                                .font(.callout.weight(.semibold))
                            Text(state.config.connectionSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(state.matchReason)
                                .font(.caption2)
                                .foregroundStyle(state.isMonitored ? .green : .secondary)
                            Text("· \(state.config.sourceFileName)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    TextField(
                        state.effectiveGroup,
                        text: Binding(
                            get: { store.settings.customGroups[state.config.alias] ?? "" },
                            set: { store.setCustomGroup(for: state.config.alias, group: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .help("自定义分组名（留空则按规则或配置文件名分组）")

                    Picker(
                        "",
                        selection: Binding(
                            get: { store.settings.manualOverrides[state.config.alias] ?? .auto },
                            set: { store.setManualOverride(for: state.config.alias, override: $0) }
                        )
                    ) {
                        ForEach(ManualHostOverride.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Tab 3: General Settings

    private var generalSettingsTab: some View {
        Form {
            Section("SSH 配置来源") {
                HStack {
                    TextField(
                        "SSH Config 路径",
                        text: Binding(
                            get: { store.settings.sshConfigPath },
                            set: { val in store.updateSettings { $0.sshConfigPath = val } }
                        )
                    )
                    .font(.system(.body, design: .monospaced))

                    Button("选择文件…") {
                        pickSSHConfigFile()
                    }
                }
                Text("支持递归解析 Include 指令、通配符文件（如 conf.d/*.conf）与注释分组标签（# @group: 分组名）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("采集性能与连接策略") {
                Picker(
                    "实时刷新间隔",
                    selection: Binding(
                        get: { store.settings.refreshIntervalSeconds },
                        set: { val in store.updateSettings { $0.refreshIntervalSeconds = val } }
                    )
                ) {
                    Text("1 秒（极速）").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒（推荐）").tag(3.0)
                    Text("5 秒").tag(5.0)
                    Text("10 秒（低负载）").tag(10.0)
                    Text("30 秒").tag(30.0)
                }

                Picker(
                    "单次 SSH 超时时间",
                    selection: Binding(
                        get: { store.settings.sshTimeoutSeconds },
                        set: { val in store.updateSettings { $0.sshTimeoutSeconds = val } }
                    )
                ) {
                    Text("5 秒").tag(5.0)
                    Text("10 秒（推荐）").tag(10.0)
                    Text("15 秒").tag(15.0)
                    Text("25 秒").tag(25.0)
                }

                Picker(
                    "历史曲线保留点数",
                    selection: Binding(
                        get: { store.settings.historyLength },
                        set: { val in store.updateSettings { $0.historyLength = val } }
                    )
                ) {
                    Text("60 点").tag(60)
                    Text("120 点（推荐）").tag(120)
                    Text("240 点").tag(240)
                    Text("360 点").tag(360)
                }

                Text("底层复用系统 /usr/bin/ssh 与 ControlMaster 长连接，自动兼容 ProxyJump、IdentityFile 和 ssh-agent。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("系统集成") {
                Toggle(
                    "在 macOS 顶部菜单栏显示常驻监控图标",
                    isOn: Binding(
                        get: { store.settings.showMenuBarExtra },
                        set: { val in store.updateSettings { $0.showMenuBarExtra = val } }
                    )
                )
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    // MARK: - Helpers

    private func bindingForRule<T>(
        _ id: UUID,
        keyPath: WritableKeyPath<HostFilterRule, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: {
                store.settings.rules.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                store.updateSettings { settings in
                    if let idx = settings.rules.firstIndex(where: { $0.id == id }) {
                        settings.rules[idx][keyPath: keyPath] = newValue
                    }
                }
            }
        )
    }

    private func addNewRule(action: RuleAction) {
        let newRule = HostFilterRule(
            name: action == .include ? "新建包含规则" : "新建排除规则",
            isEnabled: true,
            action: action,
            field: .alias,
            mode: .glob,
            pattern: action == .include ? "*gpu*" : "*test*",
            assignGroup: action == .include ? "新建分组" : ""
        )
        store.updateSettings { $0.rules.append(newRule) }
        selectedRuleID = newRule.id
    }

    private func deleteRule(_ id: UUID) {
        store.updateSettings { $0.rules.removeAll(where: { $0.id == id }) }
        selectedRuleID = store.settings.rules.first?.id
    }

    private func matchCount(for rule: HostFilterRule) -> Int {
        let engine = FilterRuleEngine()
        return store.allHosts.filter { engine.matches(rule: rule, host: $0) }.count
    }

    private func pickSSHConfigFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 配置文件"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            store.updateSettings { $0.sshConfigPath = url.path }
        }
    }
}
