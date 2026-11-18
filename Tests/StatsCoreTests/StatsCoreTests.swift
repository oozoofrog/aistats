import Foundation
import Testing
@testable import StatsCore

private func tempDir() -> URL { TestTemp.dir(create: false) }

private let baseSnapshot = SystemSampler().sample()

private func point(_ secondsAgo: Double, cpu: Double, mem: Double = 50, disk: UInt64? = 100,
                   pressure: String = "normal", now: Date = Date()) -> HistoryPoint {
    var s = baseSnapshot
    s.timestamp = now.addingTimeInterval(-secondsAgo)
    var p = HistoryPoint(snapshot: s)
    p.cpuPercent = cpu; p.memoryUsedPercent = mem; p.diskAvailableBytes = disk; p.memoryPressure = pressure
    return p
}

@Suite struct HistoryTests {
    @Test func recordsAndFiltersByTime() throws {
        let store = HistoryStore(directory: tempDir())
        #expect(store.latest() == nil)
        #expect(!store.isRecording())
        try store.record(point(600, cpu: 10))
        try store.record(point(30, cpu: 20))
        try store.record(point(1, cpu: 30))
        #expect(store.points(since: Date().addingTimeInterval(-60)).map(\.cpuPercent) == [20, 30])
        #expect(store.isRecording())
    }

    @Test func staleHistoryIsNotRecording() throws {
        let store = HistoryStore(directory: tempDir())
        try store.record(point(HistoryStore.staleAfter + 5, cpu: 10))
        #expect(!store.isRecording())
    }

    @Test func compactsToCapacity() throws {
        let file = JSONLinesFile(url: tempDir().appendingPathComponent("x.jsonl"))
        for i in 0..<250 { try file.append(ActivityStore.Call(agent: "a", tool: "t\(i)"), keep: 100) }
        let calls = file.read(ActivityStore.Call.self)
        #expect(calls.count <= 200 + JSONLinesFile.compactionCheckInterval)
        #expect(calls.count >= 100)
        #expect(calls.last?.tool == "t249")
    }

    @Test func summaryComputesRanges() throws {
        let pts = [point(30, cpu: 10, mem: 40, disk: 1000, pressure: "normal"),
                   point(20, cpu: 50, mem: 60, disk: 900, pressure: "warning"),
                   point(10, cpu: 30, mem: 50, disk: 400, pressure: "normal")]
        let s = try #require(HistorySummary.make(from: pts))
        #expect(s.cpuPercent?.min == 10 && s.cpuPercent?.max == 50 && s.cpuPercent?.average == 30)
        #expect(s.memoryUsedPercent?.average == 50)
        #expect(s.worstMemoryPressure == "warning")
        #expect(s.diskAvailableChangeBytes == -600)
        #expect(s.sampleCount == 3)
        #expect(HistorySummary.make(from: []) == nil)
    }

    @Test func downsampleKeepsBoundsAndAverages() {
        let pts = (0..<300).map { point(Double(300 - $0), cpu: Double($0 % 2 == 0 ? 0 : 100)) }
        let d = HistorySummary.downsample(pts, to: 60)
        #expect(d.count == 60)
        #expect(d.allSatisfy { $0.cpuPercent == 40 || $0.cpuPercent == 60 || $0.cpuPercent == 50 })
        #expect(d.last?.t == pts.last?.t)
        #expect(HistorySummary.downsample(Array(pts.prefix(10)), to: 60).count == 10)
        // 0 means summary only, not "everything".
        #expect(HistorySummary.downsample(pts, to: 0).isEmpty)
        let summary = HistorySummary.make(from: pts, maxPoints: 0)
        #expect(summary?.points.isEmpty == true)
        #expect(summary?.sampleCount == 300)
    }

    @Test func concurrentWritersDoNotCorruptFile() throws {
        let dir = tempDir()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            ActivityStore(directory: dir).record(.init(agent: "a\(i)", tool: "get_system_stats"))
        }
        #expect(ActivityStore(directory: dir).recentCalls(limit: 100).count == 40)
    }
}

@Suite struct ActivityTests {
    @Test func presenceTracksLiveProcesses() {
        let store = ActivityStore(directory: tempDir())
        let me = ProcessInfo.processInfo.processIdentifier
        store.updatePresence(.init(name: "claude-code", pid: me, client: "claude-code", connectedAt: Date(), lastSeen: Date()))
        store.updatePresence(.init(name: "ghost", pid: 999_999, client: nil, connectedAt: Date(), lastSeen: Date()))
        #expect(store.connectedAgents().map(\.name) == ["claude-code"])
        #expect(store.uniqueAgentName("claude-code", pid: me) == "claude-code")
        #expect(store.uniqueAgentName("claude-code", pid: me + 1) == "claude-code-2")
        store.removePresence(name: "claude-code", pid: me + 1)
        #expect(store.connectedAgents().count == 1, "another pid must not remove the record")
        store.removePresence(name: "claude-code", pid: me)
        #expect(store.connectedAgents().isEmpty)
    }

    @Test func recentCallsAreNewestLast() {
        let store = ActivityStore(directory: tempDir())
        store.record(.init(agent: "a", tool: "one"))
        store.record(.init(agent: "a", tool: "two"))
        store.record(.init(agent: "a", tool: "three"))
        #expect(store.recentCalls(limit: 2).map(\.tool) == ["two", "three"])
    }

    @Test func sanitizeBlocksPathTraversal() {
        #expect(ActivityStore.sanitize("../../etc") == ".._.._etc")
        #expect(ActivityStore.sanitize("..") == "_")
        #expect(ActivityStore.sanitize("") == "_")
    }
}

@Suite struct SamplerTests {
    @Test func measurementIsPlausible() {
        let s = SystemSampler().measure(interval: 0.3, includeProcesses: true)
        #expect(s.sampleIntervalSeconds > 0.2)
        #expect((0...100).contains(s.cpu.usagePercent))
        #expect(s.cpu.logicalCores > 0)
        #expect(s.memory.totalBytes > 0)
        #expect(s.memory.usedBytes > 0 && s.memory.usedBytes <= s.memory.totalBytes)
        #expect((s.disk?.totalBytes ?? 0) > 0)
        #expect(s.network.receivedBytesPerSecond >= 0)
        #expect((s.topProcesses ?? []).contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }

    @Test func firstSampleHasNoInterval() {
        #expect(SystemSampler().sample().sampleIntervalSeconds == 0)
    }

    @Test func busyProcessShowsCPU() {
        let sampler = SystemSampler()
        _ = sampler.sample(includeProcesses: true)
        let end = Date().addingTimeInterval(0.5)
        var x = 0.0
        while Date() < end { x += sin(x) + 1 }
        let s = sampler.sample(includeProcesses: true)
        let me = s.topProcesses?.first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        #expect((me?.cpuPercent ?? 0) > 30, "spinning for 0.5s should register (x=\(x))")
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let s = SystemSampler().measure(interval: 0.1)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let data = try e.encode(s)
        #expect(try d.decode(Snapshot.self, from: data).memory.totalBytes == s.memory.totalBytes)
        #expect(String(decoding: data, as: UTF8.self).contains("usedPercent"))
    }
}
