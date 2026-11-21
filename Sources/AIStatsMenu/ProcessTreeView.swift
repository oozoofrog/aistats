import StatsCore
import SwiftUI

private struct TreeItem: Identifiable {
    var id: String
    var title: String
    var pids: [Int32]
    var prefix: String
    var parent: String?
    var expandable: Bool
    var section = false
    var link = false
}

struct ProcessTreeView: View {
    let tree: ProcessTree
    let metric: OriginMetric
    @State private var filter = "all"
    @State private var expanded: Set<String> = ["agents", "unknown"]
    @State private var selected: String?
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var accessibleRow: String?

    private func id(_ pid: Int32) -> String { tree.nodes[pid]?.identity ?? String(pid) }
    private func sessionID(_ s: ProcessTree.Session) -> String { "session/" + id(s.serverPid) }

    private var items: [TreeItem] {
        var result: [TreeItem] = []
        let agents = tree.agents
        func branch(_ pids: [Int32], parent: String, prefix: String, depth: Int, grouped: Bool, isRoot: Bool = false) {
            guard depth <= 65 else { return }
            let groups = grouped ? tree.leafGroups(pids, by: metric) : tree.ordered(pids, by: metric).map { [$0] }
            for (i, group) in groups.enumerated() {
                let pid = group[0]
                let many = group.count > 1
                let stub = !isRoot && (agents.contains(pid) || tree.hosts[pid] != nil)
                let key = many ? parent + "/group/" + (tree.nodes[pid]?.name ?? "") : (stub ? parent + "/link/" : "") + id(pid)
                let children = tree.children[pid] ?? []
                let last = i + 1 == groups.count
                result.append(TreeItem(id: key, title: tree.label(group, cli: false) + (stub ? " ↗" : ""),
                                       pids: group, prefix: prefix + (last ? "└─" : "├─"), parent: parent,
                                       expandable: !stub && (many || !children.isEmpty), link: stub))
                if !stub && expanded.contains(key) {
                    branch(many ? group : children, parent: key, prefix: prefix + (last ? "  " : "│ "),
                           depth: depth + 1, grouped: !many)
                }
            }
        }
        func section(_ key: String, _ title: String, _ pids: [Int32], parent: String? = nil, hasOther: Bool = false) {
            result.append(TreeItem(id: key, title: title, pids: [], prefix: "", parent: parent, expandable: hasOther || !pids.isEmpty, section: true))
            if expanded.contains(key) { branch(pids, parent: key, prefix: "", depth: 0, grouped: false, isRoot: true) }
        }
        if filter == "all" || filter.hasPrefix("session/") {
            let active = filter == "all" ? Array(agents) : tree.sessions.filter { sessionID($0) == filter }.map(\.agentPid)
            section("agents", "에이전트에서 시작", active)
        }
        if filter == "all" { section("hosts", "호스트 앱 · 귀속 안 함", Array(tree.hosts.keys)) }
        if filter == "all" || filter == "unknown" {
            let dev = tree.unknown.filter { pid in
                let name = tree.nodes[pid]?.name.lowercased() ?? ""
                return ["xcode", "sourcekit", "swbbuild", "launchd_sim", "python", "node"].contains { name.hasPrefix($0) }
            }
            section("unknown", "출발점 불명 · launchd", dev, hasOther: dev.count < tree.unknown.count)
            let known = Set(dev)
            let other = tree.unknown.filter { !known.contains($0) }
            if expanded.contains("unknown") && !other.isEmpty { section("other", "기타 (\(other.count))", other, parent: "unknown") }
        }
        return result
    }

    var body: some View {
        let rows = items
        let selectedItem = rows.first { $0.id == selected }
        let scale = rows.compactMap { $0.pids.isEmpty ? nil : tree.total($0.pids).value(metric) }.max() ?? 1
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack {
                    chip("전체", "all")
                    ForEach(tree.sessions, id: \.serverPid) { chip("\($0.name) · \($0.serverPid)", sessionID($0)) }
                    chip("출발점 불명 \(tree.unattributedCount)", "unknown")
                }
            }
            Text("\(metric.label) · 자체 / 하위 합계").font(.caption)
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(rows) { item in row(item, scale: scale).id(item.id) }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 240, alignment: .leading)
                .focusable().focused($focused)
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    guard !rows.isEmpty else { return .ignored }
                    let i = rows.firstIndex { $0.id == selected } ?? 0
                    let item = rows[i]
                    switch press.key {
                    case .upArrow: selected = rows[max(0, i - 1)].id
                    case .downArrow: selected = rows[min(rows.count - 1, i + 1)].id
                    case .leftArrow:
                        if expanded.remove(item.id) == nil { selected = item.parent ?? item.id }
                    default:
                        if item.link { activate(item) }
                        else if item.expandable && expanded.contains(item.id), i + 1 < rows.count { selected = rows[i + 1].id }
                        else if item.expandable { expanded.insert(item.id) }
                    }
                    return .handled
                }
                .onChange(of: focused) { _, focus in
                    if focus && selected == nil { selected = rows.first?.id }
                }
                .onChange(of: rows.map(\.id)) { _, ids in
                    if let selected, !ids.contains(selected) { self.selected = ids.first }
                }
                .onChange(of: selected) { _, key in if let key { reader.scrollTo(key); accessibleRow = key } }
            }
            if let item = selectedItem, item.pids.count == 1, let pid = item.pids.first, let node = tree.nodes[pid] {
                Text(tree.breadcrumb(pid)).textSelection(.enabled)
                Text("시작 \(node.started.formatted()) · 경과 \(Int(max(0, tree.observedAt.timeIntervalSince(node.started))))초")
                if let reason = node.reason { Text(reason == "no_agent_ancestor" ? "launchd에서 추적 종료" : reason == "walk_limit" ? "추적 한도 도달" : "상위 프로세스를 확인할 수 없음") }
                ForEach(OriginMetric.allCases, id: \.self) { m in
                    Text("\(m.label) · 자체 \(item.pids.count > 1 ? "—" : node.own.display(m)) / 하위 합계 \(tree.total(item.pids).display(m, total: true))")
                }
                Text("메모리 출처 · physical footprint").font(.caption)
            }
        }
    }

    private func chip(_ label: String, _ key: String) -> some View {
        Button(label) { filter = key; selected = nil; expanded.formUnion(["agents", "unknown"]) }
            .buttonStyle(.bordered).accessibilityAddTraits(filter == key ? .isSelected : [])
            .tint(filter == key ? .accentColor : .secondary)
    }

    private func activate(_ item: TreeItem) {
        focused = true
        if item.link, let pid = item.pids.first {
            filter = "all"
            expanded.insert(tree.agents.contains(pid) ? "agents" : "hosts")
            selected = id(pid)
        } else { selected = item.id }
    }

    private func row(_ item: TreeItem, scale: Double) -> some View {
        let node = item.pids.first.flatMap { tree.nodes[$0] }
        let sum = tree.total(item.pids)
        let heavy = node.map { ($0.own.cpuPercent ?? 0) >= 5 || ($0.own.memoryBytes ?? 0) >= 1_000_000_000 || ($0.own.diskBytesPerSecond ?? 0) >= 1_000_000 } ?? false
        let agent = node.map { tree.agents.contains($0.pid) } ?? false
        let server = tree.sessions.contains { $0.serverPid == node?.pid }
        return HStack(spacing: 4) {
            Text(item.prefix).font(.caption.monospaced()).accessibilityHidden(true)
            if item.expandable {
                Button {
                    activate(item)
                    if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                } label: { Image(systemName: expanded.contains(item.id) ? "chevron.down" : "chevron.right") }
                .buttonStyle(.plain)
                .accessibilityRepresentation {
                    DisclosureGroup(item.title, isExpanded: Binding(get: { expanded.contains(item.id) }, set: { open in
                        activate(item)
                        if open { expanded.insert(item.id) } else { expanded.remove(item.id) }
                    })) { Text(item.title) }
                }
            }
            Button { activate(item) } label: {
                HStack {
                    Text(item.title).foregroundStyle(agent ? Color.green : heavy ? Color.orange : server ? Color.secondary : Color.primary)
                    if let node, !item.link {
                        Text("\(item.pids.count > 1 ? "—" : node.own.display(metric)) / \(sum.display(metric, total: true))")
                        ProgressView(value: min(1, (sum.value(metric) ?? 0) / max(1, scale))).frame(width: 35).accessibilityHidden(true)
                    }
                }
            }.buttonStyle(.plain).accessibilityFocused($accessibleRow, equals: item.id).accessibilityAddTraits(selected == item.id ? .isSelected : [])
        }.font(.caption).background(selected == item.id ? Color.accentColor.opacity(0.18) : .clear)
    }
}
