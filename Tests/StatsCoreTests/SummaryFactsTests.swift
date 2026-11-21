import Foundation
import Testing
@testable import StatsCore

@Test func unavailableFieldsPreserveIndependentMeasurements() throws {
    var snapshot = SystemSampler().sample()
    snapshot.unavailable = ["cpu", "memory", "network", "swap"]
    func payload() throws -> [String: [String: Any]] {
        let json = try JSONSerialization.jsonObject(with: snapshot.structuredData(using: MCPServer.encoder))
        let object = try #require(json as? [String: Any])
        return object.compactMapValues { $0 as? [String: Any] }
    }
    let partial = try payload()
    for (metric, fields) in [
        ("cpu", ["usagePercent", "userPercent", "systemPercent"]),
        ("memory", ["usedBytes", "appBytes", "wiredBytes", "compressedBytes", "cachedBytes", "usedPercent", "swapUsedBytes"]),
        ("network", ["receivedBytesPerSecond", "sentBytesPerSecond"])
    ] {
        for field in fields { #expect(partial[metric]?[field] is NSNull) }
    }
    #expect(partial["memory"]?["totalBytes"] is NSNumber)
    #expect(partial["cpu"]?["logicalCores"] is NSNumber)
    #expect(partial["network"]?["receivedTotalBytes"] is NSNumber)
    snapshot.unavailable?.append("networkCounters")
    let failed = try payload()
    for field in ["receivedTotalBytes", "sentTotalBytes", "interfaces"] {
        #expect(failed["network"]?[field] is NSNull)
    }
}

@Test func historyResultsKeepRecoveryHintsInStructuredContent() throws {
    let home = TestTemp.dir()
    let history = HistoryStore(directory: home)
    let harness = MCPHarness(home: home)
    defer { harness.close() }
    harness.initialize()
    func read(_ id: Int) throws -> [String: Any] {
        harness.call(id, "get_stats_history", ["minutes": 7])
        let result = try #require(harness.response(id)?["result"] as? [String: Any])
        return try #require(result["structuredContent"] as? [String: Any])
    }
    var point = HistoryPoint(snapshot: SystemSampler().sample())
    let empty = try read(1)
    #expect(empty["minutes"] as? Int == 7 && empty["recording"] as? Bool == false)
    #expect(empty["startCommand"] as? String == "open -b " + AIStatsPaths.appBundleIdentifier)
    #expect(empty["fallbackTool"] as? String == "get_system_stats")
    point.t = Date().addingTimeInterval(-7200)
    try history.record(point)
    #expect(try read(2)["fallbackTool"] as? String == "get_system_stats")
    point.t = Date().addingTimeInterval(-60)
    try history.record(point)
    let old = try read(3)
    #expect(old["fallbackTool"] == nil && old["startCommand"] != nil)
    #expect((old["notes"] as? [String])?.first?.contains("last recorded sample") == true)
    point.t = Date()
    try history.record(point)
    let fresh = try read(4)
    #expect(fresh["recording"] as? Bool == true && fresh["startCommand"] == nil && fresh["notes"] == nil)
}
