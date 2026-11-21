import Foundation
import Testing
@testable import StatsCore

@Test func historyBudgetRetainsWholeWindowAndMatchingText() throws {
    let dir = TestTemp.dir()
    let store = HistoryStore(directory: dir)
    let now = Date()
    var point = HistoryPoint(snapshot: SystemSampler().sample())
    point.cpuPercent = 98
    point.memoryUsedPercent = 95
    point.memoryPressure = "critical"
    point.receivedBytesPerSecond = 1_000_000_000
    point.sentBytesPerSecond = 2_000_000_000
    point.batteryPercent = 15
    for i in 0..<300 {
        point.t = now.addingTimeInterval(Double(i - 299) * 2)
        try store.record(point)
    }
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
        #expect(points.allSatisfy { $0["memoryUsedBytes"] == nil })
        if count == 10 { #expect(summary["pointsOmitted"] == nil) }
        #expect((harness.line(count)?.utf8.count ?? Int.max) <= 9216)
    }
}
