import Foundation

public struct AgentSessions: Encodable {
    public struct Session: Encodable {
        public var name: String
        public var serverStartToken: String?
        public var serverPid: Int32
        public var client: String?
        public var connectedAt: Date
        public var lastSeen: Date
        public var agentPid: Int32?
        public var agentStartToken: String?
        public var agentName: String?
    }

    public struct Busy: Encodable, Sendable {
        public var chain: [OriginSnapshot.Node]?
        public var agentName: String?
        public var omittedNodes: Int?
        public var readBytes: UInt64?
        public var writtenBytes: UInt64?
        public var diskBytesPerSecond: Double?
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
    public var omittedRows: Int?
    public var diskUnavailable: String?
    private var originMode: Bool { busy?.contains { $0.chain != nil } == true || omittedRows != nil }

    public static func collect(store: ActivityStore, caller: String? = nil, calls: Int = 5,
                               attribute: Bool = true, limit: Int = 10, origin: Bool = false,
                               sort: OriginMetric = .cpu, filter: OriginFilter = .init()) -> AgentSessions {
        let sampler = SystemSampler()
        let snapshot = attribute ? sampler.measure(interval: 1, includeProcesses: true) : nil
        let presences = store.connectedAgents()
        let sessions = presences.map { p in
            Session(name: p.name, serverStartToken: origin && p.startToken.flatMap(UInt64.init).map { Proc.isAlive(.init(pid: p.pid, start: $0)) } == true ? p.startToken : nil, serverPid: p.pid, client: p.client, connectedAt: p.connectedAt,
                    lastSeen: p.lastSeen, agentPid: p.agentPid, agentStartToken: p.agentStartToken, agentName: p.agentName)
        }
        let recent = store.recentCalls(limit: ActivityStore.logCapacity).reversed()
            .sorted { $0.date > $1.date }.prefix(calls)
            .map { ActivityStore.Call(date: $0.date, agent: $0.agent, tool: $0.tool) }
        var report = AgentSessions(observedAt: Date(), caller: caller, sessions: sessions, recentCalls: recent)
        if let snapshot {
            let origins = OriginSnapshot(processes: snapshot.topProcesses ?? [], entries: Proc.currentUserTable() ?? [], sessions: presences)
            report.busy = origins.ranking(sort, limit: limit, filter: filter, details: origin)
            if origin && sort == .disk && !origins.diskAvailable { report.diskUnavailable = "no_counter_pair" }
            report.observedAt = snapshot.timestamp
        }
        return report
    }

    static func origin(of pid: Int32, parents: [Int32: Int32], agents: Set<Int32>) -> (agent: Int32?, reason: String?) {
        walk(from: pid) { next in parents[next].map { ($0, agents.contains(next)) } }
    }

    static func walk(from pid: Int32, step: (Int32) -> (parent: Int32, agent: Bool)?) -> (agent: Int32?, reason: String?) {
        var next = pid
        var seen: Set<Int32> = []
        for _ in 0...64 {
            if next == 1 { return (nil, "no_agent_ancestor") }
            guard seen.insert(next).inserted else { break }
            guard let node = step(next) else { return (nil, "ancestry_unreadable") }
            if node.agent { return (next, nil) }
            next = node.parent
        }
        return (nil, "walk_limit")
    }

    package mutating func fit(measure: (AgentSessions) throws -> Bool) rethrows {
        while try !measure(self) {
            truncated = true
            if !recentCalls.isEmpty {
                recentCalls.removeLast()
                recentCallsOmitted = (recentCallsOmitted ?? 0) + 1
            } else if let i = busy?.lastIndex(where: { ($0.chain?.count ?? 0) > 1 }) {
                let omitted = busy?[i].omittedNodes ?? 0
                busy?[i].chain?.removeLast()
                busy?[i].omittedNodes = omitted + 1
            } else if busy?.isEmpty == false {
                if originMode { omittedRows = (omittedRows ?? 0) + 1 }
                busy?.removeLast()
                busyOmitted = (busyOmitted ?? 0) + 1
            } else if !sessions.isEmpty {
                sessions.removeLast()
                sessionsOmitted = (sessionsOmitted ?? 0) + 1
            } else { break }
        }
    }
}
