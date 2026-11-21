import Foundation
import Testing
@testable import StatsCore

@Test func sessionWalkStopsAtNearestLiveAgentAndHonorsBoundaries() {
    let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11, 13: 12, 14: 10, 17: 18, 18: 17]
    let agents: Set<Int32> = [11, 12]
    #expect(AgentSessions.origin(of: 13, parents: parents, agents: agents).agent == 12)
    #expect(AgentSessions.origin(of: 11, parents: parents, agents: agents).agent == 11)
    #expect(AgentSessions.origin(of: 14, parents: parents, agents: agents).reason == "no_agent_ancestor")
    #expect(AgentSessions.origin(of: 15, parents: parents, agents: agents).reason == "ancestry_unreadable")
    #expect(AgentSessions.origin(of: 17, parents: parents, agents: agents).reason == "walk_limit")
}

@Test func parentIdentityRejectsReparentingUnreadableAndReusedPids() {
    #expect(MCPServer.parentIdentity(parent: { 1 }, start: { _ in 99 }, readName: { _ in "fixture" }) == nil)
    #expect(MCPServer.parentIdentity(parent: { 5 }, start: { _ in nil }, readName: { _ in nil }) == nil)
    var parent: [Int32] = [5,1]
    #expect(MCPServer.parentIdentity(parent: { parent.removeFirst() }, start: { _ in 12 }, readName: { _ in "fixture" }) == nil)
    var tokens: [UInt64] = [12,13]
    #expect(MCPServer.parentIdentity(parent: { 5 }, start: { _ in tokens.removeFirst() }, readName: { _ in "fixture" }) == nil)
}

@Test func aReusedAgentPidCannotOwnASampledWorker() throws {
    let pid = getpid()
    let process = try #require(Proc.usage(pid))
    let entries = try #require(Proc.currentUserTable())
    var presence = ActivityStore.Presence(name: "fixture", pid: pid, client: nil, connectedAt: Date(),
                                          lastSeen: Date(), startToken: String(process.start))
    presence.agentPid = pid
    presence.agentStartToken = String(process.start - 1)
    let row = ProcessUsage(cpuPaired: true, startToken: String(process.start), pid: pid, name: "fixture",
                           cpuPercent: 20, memoryBytes: 10)
    let snapshot = OriginSnapshot(processes: [row], entries: entries, sessions: [presence])
    let busy = try #require(snapshot.ranking(.cpu, limit: 1).first)
    #expect(busy.agentPid == nil && busy.unattributed == "ancestry_unreadable")
}

@Test func legacySessionHasNoFabricatedAgentAndCallsAreNewestFirst() throws {
    let store = ActivityStore(directory: TestTemp.dir())
    let date = Date()
    let old = ActivityStore.Presence(name: "legacy", pid: getpid(), client: nil, connectedAt: date, lastSeen: date)
    store.updatePresence(old)
    for i in 0..<30 {
        store.record(.init(date: date.addingTimeInterval(Double(i)), agent: "legacy", tool: "tool-\(i)", detail: "private-marker"))
    }
    store.record(.init(date: date, agent: "legacy", tool: "late-append", detail: nil))
    let report = AgentSessions.collect(store: store, caller: "legacy", calls: 3, attribute: false)
    let data = try MCPServer.encoder.encode(report)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let row = try #require((json["sessions"] as? [[String:Any]])?.first)
    #expect(row["agentPid"] == nil && row["agentName"] == nil && row["client"] == nil && row["agentStartToken"] == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains("private-marker"))
    #expect(report.recentCalls.map(\.tool) == ["tool-29","tool-28","tool-27"] && json["busy"] == nil)
}
