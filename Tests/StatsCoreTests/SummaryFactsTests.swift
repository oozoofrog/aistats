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
