import Foundation

public enum OriginMetric: String, CaseIterable, Sendable {
    case cpu, memory, disk

    public static func treeSort(_ name: String) -> Self? {
        switch name { case "cpu": return .cpu; case "mem": return .memory; case "disk": return .disk; default: return nil }
    }
}

public struct OriginFilter: Sendable {
    public var session: Proc.Key?
    public var ancestor: Proc.Key?
    public init(session: Proc.Key? = nil, ancestor: Proc.Key? = nil) { self.session = session; self.ancestor = ancestor }
}

public struct OriginSnapshot {
    public struct Node: Codable, Sendable {
        public var pid: Int32
        public var startToken: String
        public var name: String
    }
    private let rows: [Int32: ProcessUsage]
    private let entries: [Int32: Proc.Entry]
    private let agents: [Proc.Key: [ActivityStore.Presence]]
    public let diskAvailable: Bool

    public init(processes: [ProcessUsage], entries: [Proc.Entry], sessions: [ActivityStore.Presence]) {
        let eligible = Set(entries.map(\.pid))
        rows = Dictionary(processes.filter { eligible.contains($0.pid) }.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        self.entries = Dictionary(entries.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var live: [Proc.Key: [ActivityStore.Presence]] = [:]
        for session in sessions {
            guard let pid = session.agentPid, let token = session.agentStartToken, let start = UInt64(token),
                  let server = session.startToken.flatMap(UInt64.init), Proc.isAlive(.init(pid: session.pid, start: server)) else { continue }
            let key = Proc.Key(pid: pid, start: start)
            if Proc.isAlive(key) { live[key, default: []].append(session) }
        }
        agents = live
        let intervalRows = rows.values
        let table = self.entries
        diskAvailable = intervalRows.contains { row in
            guard row.diskRate != nil, let start = row.startToken.flatMap(UInt64.init), let entry = table[row.pid] else { return false }
            return Proc.matches(row.pid, startSec: entry.startSec, startUsec: entry.startUsec) && Proc.isAlive(.init(pid: row.pid, start: start))
        }
    }

    public func ranking(_ metric: OriginMetric, limit: Int, filter: OriginFilter = .init(), details: Bool = true) -> [AgentSessions.Busy] {
        let order = rows.values.compactMap { row -> (ProcessUsage, Double)? in
            guard let value = !details && metric == .cpu ? row.cpuPercent : Self.value(row, metric) else { return nil }
            return (row, value)
        }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if !details && a.0.memoryBytes != b.0.memoryBytes { return a.0.memoryBytes > b.0.memoryBytes }
            return a.0.pid < b.0.pid
        }
        var result: [AgentSessions.Busy] = []
        for (row, _) in order {
            guard let busy = explain(row, metric: metric, filter: filter, details: details) else { continue }
            result.append(busy)
            if result.count == limit { break }
        }
        return result
    }

    public static func value(_ row: ProcessUsage, _ metric: OriginMetric) -> Double? {
        switch metric {
        case .cpu: return row.cpuPaired ? row.cpuPercent : nil
        case .memory: return Double(row.memoryBytes)
        case .disk: return row.diskRate
        }
    }

    public func explain(_ row: ProcessUsage, metric: OriginMetric, filter: OriginFilter = .init(),
                        details: Bool = true) -> AgentSessions.Busy? {
        guard let token = row.startToken, let start = UInt64(token), Proc.isAlive(.init(pid: row.pid, start: start)) else { return nil }
        var chain: [Node] = []
        var subjectName: String?
        var matchedAncestor = false
        var agent: Proc.Key?
        let walk = AgentSessions.walk(from: row.pid) { pid -> (parent: Int32, agent: Bool)? in
            guard let entry = entries[pid], let row = rows[pid], let token = row.startToken, let start = UInt64(token),
                  Proc.matches(pid, startSec: entry.startSec, startUsec: entry.startUsec),
                  Proc.isAlive(.init(pid: pid, start: start)) else { return nil }
            let key = Proc.Key(pid: pid, start: start)
            let name = Proc.name(pid) ?? entry.comm
            guard Proc.isAlive(key) else { return nil }
            if subjectName == nil { subjectName = name }
            if details { chain.append(Node(pid: pid, startToken: token, name: name)) }
            if filter.ancestor == key { matchedAncestor = true }
            if agents[key] != nil { agent = key }
            return (entry.ppid, agent != nil)
        }
        guard let subjectName else { return nil }
        if let session = filter.session {
            guard let agent, agents[agent]?.contains(where: { $0.pid == session.pid && $0.startToken == session.token }) == true else { return nil }
        }
        if filter.ancestor != nil && !matchedAncestor { return nil }
        return AgentSessions.Busy(chain: details ? chain : nil, agentName: details ? agent.flatMap { agents[$0]?.first?.agentName } : nil,
                                  readBytes: metric == .disk ? row.readBytes : nil, writtenBytes: metric == .disk ? row.writtenBytes : nil,
                                  diskBytesPerSecond: metric == .disk ? row.diskRate : nil, pid: row.pid, startToken: token,
                                  name: subjectName, cpuPercent: row.cpuPercent, memoryBytes: row.memoryBytes,
                                  agentPid: walk.agent, unattributed: walk.reason)
    }
}
