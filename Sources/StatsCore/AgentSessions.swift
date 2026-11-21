import Foundation

public struct AgentSessions: Encodable {
    public struct Session: Encodable {
        public var name: String
        public var serverPid: Int32
        public var client: String?
        public var connectedAt: Date
        public var lastSeen: Date
        public var agentPid: Int32?
        public var agentStartToken: String?
        public var agentName: String?
    }

    public struct Busy: Encodable {
        public var pid: Int32
        public var startToken: String
        public var name: String
        public var cpuPercent: Double
        public var memoryBytes: UInt64
        public var agentPid: Int32?
        public var unattributed: String?
    }

    public var observedAt: Date
    public var caller: String?
    public var sessions: [Session]
    public var recentCalls: [ActivityStore.Call]
    public var busy: [Busy]?
    public var truncated = false
    public var recentCallsOmitted: Int?
    public var busyOmitted: Int?
    public var sessionsOmitted: Int?

    public static func collect(store: ActivityStore, caller: String? = nil, calls: Int = 5,
                               attribute: Bool = true, limit: Int = 10) -> AgentSessions {
        let sampler = SystemSampler()
        let snapshot = attribute ? sampler.measure(interval: 1, includeProcesses: true) : nil
        let presences = store.connectedAgents()
        let sessions = presences.map { p in
            Session(name: p.name, serverPid: p.pid, client: p.client, connectedAt: p.connectedAt,
                    lastSeen: p.lastSeen, agentPid: p.agentPid, agentStartToken: p.agentStartToken, agentName: p.agentName)
        }
        let recent = store.recentCalls(limit: calls).reversed().sorted { $0.date > $1.date }.map { ActivityStore.Call(date: $0.date, agent: $0.agent, tool: $0.tool) }
        var report = AgentSessions(observedAt: Date(), caller: caller, sessions: sessions, recentCalls: recent)
        if let snapshot {
            let ranked = sampler.topProcesses(sortedBy: .cpu, limit: limit, from: snapshot.topProcesses ?? [], includeParent: false)
            let entries = Proc.currentUserTable() ?? []
            let parents = Dictionary(entries.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
            let live = Set(sessions.compactMap { p -> Int32? in
                guard let pid = p.agentPid, let token = p.agentStartToken, let start = UInt64(token),
                      Proc.isAlive(.init(pid: pid, start: start)) else { return nil }
                return pid
            })
            report.busy = ranked.compactMap { row in
                guard let token = row.startToken, let start = UInt64(token), Proc.isAlive(.init(pid: row.pid, start: start)) else { return nil }
                let match = origin(of: row.pid, parents: parents, agents: live)
                return Busy(pid: row.pid, startToken: token, name: row.name, cpuPercent: row.cpuPercent,
                            memoryBytes: row.memoryBytes, agentPid: match.agent, unattributed: match.reason)
            }
            report.observedAt = snapshot.timestamp
        }
        return report
    }

    static func origin(of pid: Int32, parents: [Int32: Int32], agents: Set<Int32>) -> (agent: Int32?, reason: String?) {
        var next = pid
        for depth in 0...64 {
            if next == 1 { return (nil, "no_agent_ancestor") }
            guard let parent = parents[next] else { return (nil, "ancestry_unreadable") }
            if agents.contains(next) { return (next, nil) }
            if depth == 64 { break }
            next = parent
        }
        return (nil, "walk_limit")
    }

    package mutating func fit(measure: (AgentSessions) throws -> Bool) rethrows {
        while try !measure(self) {
            truncated = true
            if !recentCalls.isEmpty {
                recentCalls.removeLast()
                recentCallsOmitted = (recentCallsOmitted ?? 0) + 1
            } else if busy?.isEmpty == false {
                busy?.removeLast()
                busyOmitted = (busyOmitted ?? 0) + 1
            } else if !sessions.isEmpty {
                sessions.removeLast()
                sessionsOmitted = (sessionsOmitted ?? 0) + 1
            } else { break }
        }
    }
}
