import Foundation

struct ProcessTreeReport: Encodable {
    struct Row: Encodable {
        var pid: Int32?
        var pids: [Int32]?
        var name: String
        var cpuPercent: Double?
        var memoryBytes: UInt64?
        var diskBytesPerSecond: Double?
        var partial: [String]?
        var processCount: Int
        var unattributed: String?
        var serverPid: Int32?
        var top: [Row]?
        var more: Int?
    }
    struct Host: Encodable {
        var pid: Int32
        var agentPids: [Int32]
    }
    var observedAt: Date
    var sort: String
    var processes: Int
    var agents: [Row]
    var unattributed: [Row]
    var hosts: [Host]
    var truncated: Bool
    var agentsOmitted: Int
    var unattributedOmitted: Int
    var hostsOmitted = 0

    init(_ tree: ProcessTree, metric: OriginMetric, limit: Int) {
        observedAt = tree.observedAt
        sort = metric == .memory ? "mem" : metric.rawValue
        processes = tree.nodes.count
        let roots = tree.agents
        func row(_ group: [Int32]) -> Row {
            let pid = group[0], sum = tree.total(group)
            return Row(pid: group.count == 1 ? pid : nil, pids: group.count > 1 ? group : nil, name: group.count == 1 ? tree.nodes[pid]!.name : tree.label(group, cli: true),
                       cpuPercent: sum.cpuPercent, memoryBytes: sum.memoryBytes, diskBytesPerSecond: sum.diskBytesPerSecond,
                       partial: sum.partial.isEmpty ? nil : sum.partial, processCount: group.reduce(0) { $0 + (tree.nodes[$1]?.count ?? 0) })
        }
        agents = tree.ordered(Array(roots), by: metric).prefix(limit).map { pid in
            var agent = row([pid])
            agent.serverPid = tree.sessions.first { $0.agentPid == pid }?.serverPid
            let groups = tree.leafGroups((tree.children[pid] ?? []).filter { !roots.contains($0) }, by: metric)
            agent.top = groups.prefix(limit).map(row)
            agent.more = groups.count > limit ? groups.count - limit : nil
            return agent
        }
        unattributed = tree.ordered(tree.unknown, by: metric).prefix(limit).map { pid in
            var result = row([pid])
            result.unattributed = tree.nodes[pid]?.reason
            return result
        }
        hosts = tree.hosts.sorted { $0.key < $1.key }.map { Host(pid: $0.key, agentPids: $0.value) }
        agentsOmitted = roots.count - agents.count
        unattributedOmitted = tree.unknown.count - unattributed.count
        truncated = agentsOmitted + unattributedOmitted > 0 || agents.contains { $0.more != nil }
    }

    mutating func trim() -> Bool {
        truncated = true
        if let i = agents.indices.reversed().max(by: { (agents[$0].top?.count ?? 0) < (agents[$1].top?.count ?? 0) }),
           agents[i].top?.isEmpty == false {
            agents[i].top?.removeLast()
            agents[i].more = (agents[i].more ?? 0) + 1
        } else if !unattributed.isEmpty { unattributed.removeLast(); unattributedOmitted += 1 }
        else if !agents.isEmpty { agents.removeLast(); agentsOmitted += 1 }
        else if !hosts.isEmpty { hosts.removeLast(); hostsOmitted += 1 }
        else { return false }
        return true
    }

    func text() -> String {
        func line(_ row: Row) -> String {
            let values = [row.cpuPercent.map { String(format: "%.1f%%", $0) }, row.memoryBytes.map(Format.bytes),
                          row.diskBytesPerSecond.map(Format.rate)]
            let metrics = zip(OriginMetric.allCases, values).map { m, v in
                v.map { (row.partial?.contains(m.rawValue) == true ? "≥" : "") + $0 } ?? "—"
            }.joined(separator: "  ")
            return row.name + (row.pid.map { "(\($0))" } ?? "") + "  " + metrics
        }
        var lines = ["CPU / MEM / DISK · \(sort)", "에이전트"]
        for r in agents {
            lines.append(line(r) + (r.serverPid.map { "  serverPid=\($0)" } ?? ""))
            lines += (r.top ?? []).map { "  ├─ " + line($0) }
            if let n = r.more { lines.append("  └─ +\(n) more") }
        }
        lines.append("호스트 앱")
        lines += hosts.map { "\($0.pid) → " + $0.agentPids.map(String.init).joined(separator: ",") }
        lines.append("출발점 불명")
        lines += unattributed.map { line($0) + "  " + ($0.unattributed ?? "ancestry_unreadable") }
        return lines.joined(separator: "\n")
    }
}
