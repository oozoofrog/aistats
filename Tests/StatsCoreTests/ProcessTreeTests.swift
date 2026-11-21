import Foundation
import Testing
@testable import StatsCore

private func fixtureTree() -> ProcessTree {
    let date = Date()
    let pairs: [(Int32, Int32, String)] = [(2,1,"host"), (3,2,"agentA"), (4,2,"agentB"),
        (5,3,"worker"), (6,3,"worker"), (7,3,"server"), (8,4,"server"), (9,2,"helper"), (10,1,"build")]
    let entries = pairs.map { Proc.Entry(pid: $0.0, ppid: $0.1, comm: $0.2, startSec: Int($0.0), startUsec: 0) }
    let processes = pairs.filter { $0.0 != 6 }.map { pid, _, name in
        ProcessUsage(cpuPaired: pid != 10, diskRate: 0, startToken: String(pid),
                     pid: pid, name: name, cpuPercent: Double(pid), memoryBytes: UInt64(pid) * 100)
    }
    let sessions = [(Int32(3),Int32(7)),(4,8)].map { agent, server in
        var session = ActivityStore.Presence(name: "session", pid: server, client: nil, connectedAt: date,
                                             lastSeen: date, startToken: String(server))
        session.agentPid = agent
        session.agentStartToken = String(agent)
        return session
    }
    return ProcessTree(entries: entries, processes: processes, sessions: sessions, at: date) { _,_ in true }
}

@Test func treeUsesCompleteForestAndStopsTotalsAtNestedAttributionBoundaries() throws {
    let tree = fixtureTree()
    #expect(tree.nodes.count == 9)
    #expect(tree.hosts[2] == [3,4])
    #expect(tree.nodes[2]?.total.memoryBytes == 1100)
    #expect(tree.nodes[3]?.total.memoryBytes == 1500)
    #expect(tree.nodes[6]?.own.display(.memory) == "—")
    #expect(tree.nodes[3]?.total.display(.memory, total: true).hasPrefix("≥") == true)
    #expect(tree.nodes[10]?.own.display(.cpu) == "—")
    #expect(tree.nodes[10]?.own.diskBytesPerSecond == 0)
    #expect(tree.nodes[9]?.owner == nil)
    #expect(tree.unattributedCount == 1)
    #expect(tree.breadcrumb(5) == "launchd 1 › host 2 › agentA 3 › worker 5")
    let text = tree.text(sort: .memory)
    #expect(text.contains("2*[worker]") && text.contains("no_agent_ancestor") && text.contains("에이전트"))
    let groups = tree.leafGroups(tree.children[3] ?? [], by: .memory)
    #expect(groups.contains([5,6]))
}

@Test func treeTrimsChildrenBeforeUnattributedRowsAndAgents() {
    var report = ProcessTreeReport(fixtureTree(), metric: .cpu, limit: 10)
    #expect(report.agents.count == 2 && report.hosts[0].agentPids == [3,4])
    #expect(report.unattributed.first?.unattributed == "no_agent_ancestor")
    while report.agents.contains(where: { $0.top?.isEmpty == false }) {
        let removed = report.trim()
        #expect(removed)
        #expect(report.agents.count == 2 && report.unattributed.count == 1)
    }
    let droppedUnknown = report.trim()
    #expect(droppedUnknown)
    #expect(report.unattributed.isEmpty && report.agents.count == 2)
    let droppedAgent = report.trim()
    #expect(droppedAgent)
    #expect(report.agents.count == 1 && report.truncated)
}
