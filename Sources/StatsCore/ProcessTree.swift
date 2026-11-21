import Foundation

public struct TreeMetrics: Encodable, Sendable {
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?
    public var diskBytesPerSecond: Double?
    public var partial: [String] = []

    init(_ row: ProcessUsage?) {
        cpuPercent = row?.cpuPaired == true ? row?.cpuPercent : nil
        memoryBytes = row?.memoryBytes
        diskBytesPerSecond = row?.diskRate
        partial = OriginMetric.allCases.filter { value($0) == nil }.map(\.rawValue)
    }

    mutating func add(_ other: Self) {
        if let n = other.cpuPercent { cpuPercent = (cpuPercent ?? 0) + n }
        if let n = other.memoryBytes { memoryBytes = (memoryBytes ?? 0) + n }
        if let n = other.diskBytesPerSecond { diskBytesPerSecond = (diskBytesPerSecond ?? 0) + n }
        for key in other.partial where !partial.contains(key) { partial.append(key) }
    }

    public func value(_ metric: OriginMetric) -> Double? {
        switch metric {
        case .cpu: return cpuPercent
        case .memory: return memoryBytes.map(Double.init)
        case .disk: return diskBytesPerSecond
        }
    }

    public func display(_ metric: OriginMetric, total: Bool = false) -> String {
        guard let value = value(metric) else { return "—" }
        let prefix = total && partial.contains(metric.rawValue) ? "≥" : ""
        switch metric {
        case .cpu: return prefix + String(format: "%.1f%%", value)
        case .memory: return prefix + Format.bytes(memoryBytes ?? 0)
        case .disk: return prefix + Format.rate(value)
        }
    }
}

public struct ProcessTree: Sendable {
    public struct Node: Sendable {
        public let pid: Int32
        public let parent: Int32
        public let name: String
        let groupable: Bool
        public let startToken: String?
        public let started: Date
        /// The kernel start time from the table, to check a later direct read against PID reuse.
        let startSec: Int
        let startUsec: Int32
        public var own: TreeMetrics
        public var total: TreeMetrics
        public var count = 1
        public var owner: Int32?
        public var reason: String?
        public var identity: String { "\(pid)/\(started.timeIntervalSince1970)" }
    }

    public struct Session: Sendable {
        public let serverPid: Int32
        public let agentPid: Int32
        public let name: String
    }

    public private(set) var nodes: [Int32: Node] = [:]
    public private(set) var children: [Int32: [Int32]] = [:]
    public private(set) var sessions: [Session] = []
    public private(set) var hosts: [Int32: [Int32]] = [:]
    public private(set) var unknown: [Int32] = []
    public private(set) var deviceRoots: Set<Int32> = []
    public let observedAt: Date
    public var unattributedCount: Int {
        let excluded = agents.union(hosts.keys)
        var pending = unknown
        var count = 0
        while let pid = pending.popLast() {
            count += 1
            pending.append(contentsOf: (children[pid] ?? []).filter { !excluded.contains($0) })
        }
        return count
    }
    public var agents: Set<Int32> { Set(sessions.map(\.agentPid)) }

    public static let deviceRootName = "launchd_sim"

    public static func measure(store: ActivityStore, deviceRoots: Bool = false) -> Self {
        let sample = SystemSampler().measure(interval: 1, includeProcesses: true)
        return Self(entries: Proc.currentUserTable() ?? [], processes: sample.topProcesses ?? [],
                    sessions: store.connectedAgents(), at: sample.timestamp, deviceRoots: deviceRoots)
    }

    public init(entries: [Proc.Entry], processes: [ProcessUsage], sessions: [ActivityStore.Presence], at date: Date, deviceRoots: Bool = false) {
        self.init(entries: entries, processes: processes, sessions: sessions, at: date, deviceRoots: deviceRoots, name: Proc.name) { entry, key in
            Proc.matches(entry.pid, startSec: entry.startSec, startUsec: entry.startUsec) && Proc.isAlive(key)
        }
    }

    init(entries: [Proc.Entry], processes: [ProcessUsage], sessions presences: [ActivityStore.Presence], at date: Date,
         deviceRoots detectDevices: Bool = false, name: (Int32) -> String? = { _ in nil }, verify: (Proc.Entry, Proc.Key) -> Bool) {
        observedAt = date
        let samples = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in entries where entry.pid > 1 {
            if detectDevices && entry.comm == Self.deviceRootName { deviceRoots.insert(entry.pid) }
            let fullName = name(entry.pid)
            let row = samples[entry.pid].flatMap { row -> ProcessUsage? in
                guard let start = row.startToken.flatMap(UInt64.init), verify(entry, .init(pid: entry.pid, start: start)) else { return nil }
                return row
            }
            let metrics = TreeMetrics(row)
            let start = Double(entry.startSec) + Double(entry.startUsec) / 1e6
            let validName = row == nil ? nil : fullName
            let cleanName = (validName ?? entry.comm).components(separatedBy: .controlCharacters).joined(separator: "�")
            nodes[entry.pid] = Node(pid: entry.pid, parent: entry.ppid, name: cleanName, groupable: validName != nil || entry.comm.utf8.count < 15, startToken: row?.startToken,
                                    started: Date(timeIntervalSince1970: start), startSec: entry.startSec, startUsec: entry.startUsec, own: metrics, total: metrics)
        }
        sessions = presences.compactMap { p in
            guard let agent = p.agentPid, let token = p.agentStartToken, let serverToken = p.startToken,
                  nodes[agent]?.startToken == token, nodes[p.pid]?.startToken == serverToken else { return nil }
            return Session(serverPid: p.pid, agentPid: agent, name: p.name)
        }.sorted { $0.serverPid < $1.serverPid }
        let roots = agents
        let table = nodes
        func observedParent(_ pid: Int32) -> Int32? {
            guard let node = table[pid], let parent = table[node.parent], parent.started <= node.started else { return nil }
            return parent.pid
        }
        var hostCandidates: [Int32: Set<Int32>] = [:]
        for agent in roots {
            var current = observedParent(agent)
            var seen: Set<Int32> = [agent]
            while let pid = current, !roots.contains(pid),
                  seen.count <= 64, seen.insert(pid).inserted {
                hostCandidates[pid, default: []].insert(agent)
                current = observedParent(pid)
            }
        }
        // Select the closest shared ancestor. More distant ancestors can span independent hosts.
        for agent in roots {
            var current = observedParent(agent)
            var seen: Set<Int32> = []
            while let pid = current, let group = hostCandidates[pid], seen.insert(pid).inserted {
                if group.count >= 2 { hosts[pid] = group.sorted(); break }
                current = observedParent(pid)
            }
        }
        var parentOf: [Int32: Int32] = [:]
        for node in table.values {
            let result = AgentSessions.walk(from: node.pid) { pid in
                guard let entry = table[pid] else { return nil }
                if let parent = table[entry.parent], parent.started > entry.started {
                    return roots.contains(pid) ? (1, true) : nil
                }
                return (entry.parent, roots.contains(pid))
            }
            nodes[node.pid]?.owner = result.agent
            nodes[node.pid]?.reason = result.reason
            if let parent = table[node.parent], parent.started <= node.started,
               result.reason != "walk_limit", parent.pid != node.pid {
                children[parent.pid, default: []].append(node.pid)
                if !roots.contains(node.pid) { parentOf[node.pid] = parent.pid }
            } else if !roots.contains(node.pid) && hosts[node.pid] == nil { unknown.append(node.pid) }
        }
        // Add each own reading once to each observed ancestor, stopping at the first agent or Device Root.
        let devices = deviceRoots
        for node in table.values {
            var current = devices.contains(node.pid) ? nil : parentOf[node.pid]
            while let pid = current {
                nodes[pid]?.total.add(node.own)
                nodes[pid]?.count += 1
                current = devices.contains(pid) ? nil : parentOf[pid]
            }
        }
    }

    public func ordered(_ pids: [Int32], by metric: OriginMetric) -> [Int32] {
        pids.sorted {
            let a = nodes[$0]?.total.value(metric) ?? -1
            let b = nodes[$1]?.total.value(metric) ?? -1
            return a == b ? $0 < $1 : a > b
        }
    }

    public func breadcrumb(_ pid: Int32) -> String {
        var current = pid
        var parts: [String] = []
        var seen: Set<Int32> = []
        while let node = nodes[current], seen.count <= 64, seen.insert(current).inserted {
            parts.append("\(node.name) \(node.pid)")
            if let parent = nodes[node.parent], parent.started > node.started { break }
            current = node.parent
        }
        if current == 1 { parts.append("launchd 1") }
        return parts.reversed().joined(separator: " › ")
    }

    public func leafGroups(_ pids: [Int32], by metric: OriginMetric) -> [[Int32]] {
        var groups: [[Int32]] = []
        var byName: [String: Int] = [:]
        let protected = agents.union(sessions.map(\.serverPid)).union(hosts.keys)
        for pid in ordered(pids, by: metric) {
            guard let node = nodes[pid], node.groupable, children[pid] == nil, !protected.contains(pid) else { groups.append([pid]); continue }
            if let i = byName[node.name] { groups[i].append(pid) }
            else { byName[node.name] = groups.count; groups.append([pid]) }
        }
        return groups.sorted {
            let lhs = $0.compactMap { nodes[$0]?.total.value(metric) }
            let rhs = $1.compactMap { nodes[$0]?.total.value(metric) }
            let a = lhs.isEmpty ? -1 : lhs.reduce(0,+), b = rhs.isEmpty ? -1 : rhs.reduce(0,+)
            return a == b ? $0[0] < $1[0] : a > b
        }
    }

    public func total(_ group: [Int32]) -> TreeMetrics {
        guard let first = group.first, var sum = nodes[first]?.total else { return TreeMetrics(nil) }
        for pid in group.dropFirst() { if let n = nodes[pid] { sum.add(n.total) } }
        return sum
    }

    public func label(_ group: [Int32], cli: Bool) -> String {
        guard let pid = group.first, let node = nodes[pid] else { return "" }
        if group.count > 1 { return cli ? "\(group.count)*[\(node.name)]" : "\(node.name) ×\(group.count)" }
        return "\(node.name)(\(pid))"
    }

    public func text(sort: OriginMetric) -> String {
        let roots = agents
        let header = OriginMetric.allCases.map { ($0 == sort ? "*" : "") + ($0 == .memory ? "MEM" : $0.rawValue.uppercased()) }.joined(separator: "         ")
        var lines = ["PROCESS TREE                                  " + header]
        func render(_ pids: [Int32], prefix: String, level: Int) {
            guard level <= 65 else { return }
            let groups = leafGroups(pids, by: sort)
            for (i, group) in groups.enumerated() {
                let pid = group[0], last = i + 1 == groups.count
                let sum = total(group)
                let stub = level > 0 && (roots.contains(pid) || hosts[pid] != nil)
                let name = prefix + (last ? "└─ " : "├─ ") + label(group, cli: true)
                if stub { lines.append(name + " ↗"); continue }
                let padding = String(repeating: " ", count: max(1, 46 - name.count))
                let values = OriginMetric.allCases.map { metric in
                    let value = sum.display(metric, total: true)
                    return String(repeating: " ", count: max(1, 12 - value.count)) + value
                }.joined()
                lines.append(name + padding + values + (level == 0 ? nodes[pid]?.reason.map { "  " + $0 } ?? "" : ""))
                if group.count == 1 { render(children[pid] ?? [], prefix: prefix + (last ? "   " : "│  "), level: level + 1) }
            }
        }
        for (title,pids) in [("에이전트", Array(roots)), ("호스트 앱", Array(hosts.keys)), ("출발점 불명", unknown)] {
            lines.append(title)
            render(pids, prefix: "", level: 0)
        }
        return lines.joined(separator: "\n")
    }
}
