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
