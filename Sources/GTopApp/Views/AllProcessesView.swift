import GTopCore
import SwiftUI

enum ProcessSortOrder: String, CaseIterable, Identifiable {
    case memoryDesc = "显存降序"
    case hostAsc = "主机名"
    case userAsc = "用户名"
    case pidAsc = "PID"

    var id: String { rawValue }
}

struct AllProcessesView: View {
    @Bindable var store: ClusterMonitorStore
    let searchText: String
    let onSelectHost: (String) -> Void
    let onNotify: (String) -> Void

    @State private var selectedUser: String? = nil
    @State private var sortOrder: ProcessSortOrder = .memoryDesc

    private struct UserAggregate: Identifiable {
        var id: String { user }
        let user: String
        let processCount: Int
        let totalMemoryMiB: Double
        let gpuCount: Int
    }

    private var userSummaries: [UserAggregate] {
        let grouped = Dictionary(grouping: store.allProcesses, by: { $0.process.user })
        return grouped.map { user, items in
            let uniqueGPUs = Set(items.map(\.gpu.id))
            let totalMem = items.compactMap(\.process.usedMemoryMiB).reduce(0, +)
            return UserAggregate(
                user: user,
                processCount: items.count,
                totalMemoryMiB: totalMem,
                gpuCount: uniqueGPUs.count
            )
        }
        .sorted { $0.totalMemoryMiB > $1.totalMemoryMiB }
    }

    private var filteredProcesses: [(host: HostMonitorState, gpu: GPUMetric, process: GPUProcess)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.allProcesses.filter { item in
            if let selectedUser, item.process.user != selectedUser {
                return false
            }
            guard !q.isEmpty else { return true }
            return item.host.config.alias.localizedCaseInsensitiveContains(q) ||
                item.process.user.localizedCaseInsensitiveContains(q) ||
                item.process.commandLine.localizedCaseInsensitiveContains(q) ||
                item.gpu.name.localizedCaseInsensitiveContains(q) ||
                String(item.process.pid).contains(q)
        }

        switch sortOrder {
        case .memoryDesc:
            return filtered.sorted { ($0.process.usedMemoryMiB ?? 0) > ($1.process.usedMemoryMiB ?? 0) }
        case .hostAsc:
            return filtered.sorted {
                if $0.host.config.alias == $1.host.config.alias {
                    return $0.gpu.index < $1.gpu.index
                }
                return $0.host.config.alias < $1.host.config.alias
            }
        case .userAsc:
            return filtered.sorted { $0.process.user < $1.process.user }
        case .pidAsc:
            return filtered.sorted { $0.process.pid < $1.process.pid }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("集群 GPU 进程")
                            .font(.title2.weight(.bold))
                        Text("汇总全部在线服务器的 Compute / Graphics 进程（共 \(filteredProcesses.count) 个）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("排序", selection: $sortOrder) {
                        ForEach(ProcessSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }

                // Per-user usage pills
                if !userSummaries.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                selectedUser = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Text("全部用户")
                                    Text("(\(store.allProcesses.count))")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    selectedUser == nil ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)

                            ForEach(userSummaries) { agg in
                                let active = selectedUser == agg.user
                                Button {
                                    selectedUser = active ? nil : agg.user
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "person.fill")
                                            .font(.caption2)
                                        Text(agg.user)
                                            .fontWeight(.semibold)
                                        Text("\(agg.gpuCount) 卡 · \(Formatters.memoryMiB(agg.totalMemoryMiB))")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if filteredProcesses.isEmpty {
                    ContentUnavailableView(
                        "当前无匹配 GPU 进程",
                        systemImage: "list.bullet.rectangle.portrait",
                        description: Text("所有在线 GPU 当前处于空闲状态，或没有符合筛选条件的进程。")
                    )
                    .padding(.vertical, 48)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("服务器 / GPU").frame(width: 175, alignment: .leading)
                            Text("PID").frame(width: 62, alignment: .trailing)
                            Text("类型").frame(width: 38, alignment: .center)
                            Text("用户").frame(width: 85, alignment: .leading)
                            Text("显存").frame(width: 82, alignment: .trailing)
                            Text("运行时长").frame(width: 80, alignment: .trailing)
                            Text("命令行").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.04))

                        Divider()

                        ForEach(filteredProcesses, id: \.process.id) { item in
                            HStack(spacing: 10) {
                                Button {
                                    onSelectHost(item.host.config.alias)
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(item.host.config.alias)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        BadgePill(
                                            text: "#\(item.gpu.index)",
                                            color: GTopTheme.gpuColor(index: item.gpu.index)
                                        )
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(width: 175, alignment: .leading)

                                Text("\(item.process.pid)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 62, alignment: .trailing)

                                BadgePill(
                                    text: item.process.type.shortLabel,
                                    color: item.process.type == .compute ? .blue : .purple
                                )
                                .frame(width: 38, alignment: .center)

                                Text(item.process.user)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .frame(width: 85, alignment: .leading)

                                Text(Formatters.memoryMiB(item.process.usedMemoryMiB))
                                    .font(.caption.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.indigo)
                                    .frame(width: 82, alignment: .trailing)

                                Text(item.process.elapsedTime ?? "—")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .trailing)

                                HStack(spacing: 6) {
                                    Text(item.process.displayName)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(item.process.displayName)
                                    Spacer(minLength: 4)
                                    Button {
                                        SystemActions.copyToClipboard(item.process.displayName)
                                        onNotify("已复制进程命令行")
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)

                            Divider()
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
