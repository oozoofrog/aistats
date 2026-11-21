import Darwin
import Foundation
import Testing
@testable import StatsCore

@Test func rankedProcessRetainsSampleIdentity() throws {
    let pid = getpid()
    let sampler = SystemSampler()
    let snapshot = sampler.measure(interval: 0.1, includeProcesses: true)
    let own = try #require(snapshot.topProcesses?.first { $0.pid == pid })
    let found = try #require(ProcessFinder.find(.pid(pid, startToken: nil)).processes.first)
    let row = try #require(sampler.topProcesses(sortedBy: .memory, limit: 1, from: [own]).first)
    #expect(row.startToken == found.startToken)
    #expect(row.ppid == getppid())
    var earlier = own
    earlier.startToken = "1"
    earlier.name = "earlier"
    #expect(sampler.topProcesses(sortedBy: .cpu, limit: 1, from: [earlier]).isEmpty)
    var parentReads = 0
    sampler.readParent = { _ in parentReads += 1; return nil }
    let limited = sampler.topProcesses(sortedBy: .memory, limit: 5, from: Array(repeating: own, count: 300))
    #expect(parentReads == 5 && limited.count == 5)
    #expect(limited.allSatisfy { $0.ppid == nil })
    let old = try JSONDecoder().decode(ProcessUsage.self, from: Data(#"{"pid":1,"name":"old","cpuPercent":0,"memoryBytes":1}"#.utf8))
    #expect(old.startToken == nil && old.ppid == nil)
}
