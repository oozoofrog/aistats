import Foundation
import Testing
@testable import StatsCore

@Test func historyBudgetRetainsWholeWindowAndMatchingText() throws {
    let dir = TestTemp.dir()
    let now = Date()
    var point = HistoryPoint(snapshot: SystemSampler().sample())
    point.cpuPercent = 98
    point.memoryUsedPercent = 95
    point.memoryPressure = "critical"
    point.receivedBytesPerSecond = 1_000_000_000
    point.sentBytesPerSecond = 2_000_000_000
    point.batteryPercent = 15
    var history = Data()
    for i in 0..<HistoryStore.capacity {
        point.t = now.addingTimeInterval(Double(i - HistoryStore.capacity + 1) * 2)
        try history.append(JSONLinesFile.encoder.encode(point))
        history.append(10)
    }
    try history.write(to: dir.appendingPathComponent("history.jsonl"))
    let harness = MCPHarness(home: dir)
    defer { harness.close() }
    harness.initialize()
    for count in [10, 60] {
        harness.call(count, "get_stats_history", ["minutes": 60, "maxPoints": count])
        let result = try #require(harness.response(count)?["result"] as? [String: Any])
        let body = try #require(result["structuredContent"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let data = try #require(text.split(separator: "\n").last.map { Data($0.utf8) })
        #expect(data.count <= 4096)
        #expect(try (JSONSerialization.jsonObject(with: data) as? NSDictionary) == body as NSDictionary)
        let summary = try #require(body["summary"] as? [String: Any])
        let points = try #require(summary["points"] as? [[String: Any]])
        #expect(points.count + (summary["pointsOmitted"] as? Int ?? 0) == count)
        #expect(points.last?["t"] as? String == summary["to"] as? String)
        #expect(summary["sampleCount"] as? Int == HistoryStore.capacity)
        for key in ["cpuPercent", "memoryUsedPercent", "receivedBytesPerSecond", "sentBytesPerSecond"] {
            #expect((summary[key] as? [String: Double])?.keys.sorted() == ["average","max","min"])
        }
        let formatter = ISO8601DateFormatter()
        let dates = points.compactMap { ($0["t"] as? String).flatMap(formatter.date(from:)) }
        let gaps = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }
        #expect(dates.count == points.count && (gaps.max() ?? 0) - (gaps.min() ?? 0) <= 2)
        #expect(points.allSatisfy { $0["memoryUsedBytes"] == nil })
        if count == 10 { #expect(summary["pointsOmitted"] == nil) }
        #expect((harness.line(count)?.utf8.count ?? Int.max) <= 9216)
    }
}

@Test func worstCaseToolPayloadsRetainTheirFactsAndRankOrder() throws {
    typealias Object = [String: Any]
    let h = MCPHarness()
    defer { h.close() }
    let server = h.server
    func check(_ rpc: Object, strict: Bool = false) throws -> Object {
        let line = MCPServer.line(rpc, toolCall: true)
        #expect(line.count <= (strict ? 4096 : 9216))
        let message = try #require(JSONSerialization.jsonObject(with: line) as? Object)
        let result = try #require(message["result"] as? Object)
        #expect(result["isError"] as? Bool == false)
        let body = try #require(result["structuredContent"] as? Object)
        let text = try #require((result["content"] as? [Object])?.first?["text"] as? String)
        let parts = try #require(text.range(of: "\n\n", options: .backwards))
        #expect(text[..<parts.lowerBound].utf8.count <= 512)
        let data = Data(text[parts.upperBound...].utf8)
        #expect(data.count <= 4096)
        #expect(try (JSONSerialization.jsonObject(with: data) as? NSDictionary) == body as NSDictionary)
        #expect(MCPServer.line(rpc, toolCall: true) == line)
        return body
    }
    func simple<T: Encodable>(_ summary: String, _ value: T) throws -> Object {
        try check(["jsonrpc": "2.0", "id": 1, "result": server.leanResult(summary, value)])
    }
    let rows: [ProcessUsage] = (1...50).map { (i: Int) -> ProcessUsage in
        let bytes: UInt64 = 10_000_000_000 - UInt64(i)
        return ProcessUsage(startToken: String(i), ppid: 1, pid: Int32(i + 10), name: String(repeating: "z", count: 255),
                     cpuPercent: Double(1000 - i), memoryBytes: bytes)
    }
    var sample = SystemSampler().sample()
    sample.cpu.usagePercent = 99
    sample.cpu.loadAverage1m = Double(sample.cpu.logicalCores) * 3
    sample.thermalState = "critical"
    sample.memory.pressure = "critical"
    sample.disk = .init(mountPath: "/", totalBytes: 20 << 30, availableBytes: 1024)
    sample.battery = .init(percent: 1, isCharging: false, powerSource: "Battery Power")
    sample.unavailable = nil
    sample.topProcesses = Array(rows.prefix(5))
    let full = try check(server.snapshotResponse(sample, since: nil, id: 1))
    #expect(full["topProcessesOmitted"] == nil && (full["topProcesses"] as? [Object])?.count == 5)
    for sort in ProcessSort.allCases {
        for n in [10, 50] {
            let out = try check(server.topResponse(Array(rows.prefix(n)), sort: sort, id: 1))
            let repeated = try check(server.topResponse(Array(rows.prefix(n)), sort: sort, id: 1))
            #expect((out as NSDictionary).isEqual(to: repeated))
            let shown = try #require(out["processes"] as? [Object])
            #expect(shown.compactMap { $0["pid"] as? Int32 } == rows.prefix(shown.count).map(\.pid))
            #expect(shown.count + (out["processesOmitted"] as? Int ?? 0) == n)
            if n == 10 { #expect(shown.count == 10) }
        }
    }
    let diagnosis = Diagnosis.make(purpose: "heavy_work", snapshot: sample, top: rows)
    let facts = try simple(diagnosis.summaryLine, diagnosis)
    #expect(facts["readiness"] as? String == "caution" && (facts["evidence"] as? [Object])?.count == 4)
    #expect((facts["topProcesses"] as? [Object])?.count == 3)
    let wait = WaitResult(state: "timed_out", condition: "cpu_idle", elapsedSeconds: 20, timeoutSeconds: 20,
                          culprits: rows.prefix(3).map { .init(startToken: $0.startToken, ppid: 1, pid: $0.pid, name: $0.name, cpuPercent: $0.cpuPercent) })
    let outcome = try simple(wait.summaryLine, wait)
    #expect((outcome["culprits"] as? [Object])?.count == 3 && outcome["state"] as? String == "timed_out")
    let path = "/" + String(repeating: "p", count: 1023)
    var env = EnvironmentProbe.collect(includeToolchain: false)
    env.toolchain = .init(developerDir: path, developerDirSource: "DEVELOPER_DIR",
                          errors: ["unavailable toolchain"], checkedAt: Date())
    let environment = try simple(env.summaryLine, env)
    #expect((environment["toolchain"] as? Object)?["developerDir"] as? String == path)
    let found = FindResult(observedAt: Date(), scope: "current_user", selector: "path",
                           processes: rows.prefix(15).map { .init(pid: $0.pid, startToken: $0.startToken, name: $0.name,
                                                             ppid: 1, footprintBytes: $0.memoryBytes, path: path) }, matched: 15, truncated: false)
    let matches = try check(server.findResponse(found, id: 1), strict: true)
    #expect((matches["processes"] as? [Object] ?? []).count + (matches["processesOmitted"] as? Int ?? 0) == 15)
    let repeated = try check(server.findResponse(found, id: 1), strict: true)
    #expect((matches as NSDictionary).isEqual(to: repeated))
    #expect(matches["matched"] as? Int == 15)
}
