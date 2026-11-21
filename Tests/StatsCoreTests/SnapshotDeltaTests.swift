import Foundation
import Testing
@testable import StatsCore

@Test func deltaCarriesTheLastValuesActuallySentToTheCaller() throws {
    let cache = SnapshotDelta()
    func sample(_ value: Double, since: String? = nil, now: Double = 0) throws -> [String: Any] {
        try cache.response(["cpu": ["usagePercent": value]], since: since, now: now) { _ in true }
    }
    let first = try sample(10)
    #expect(first["delta"] == nil)
    let second = try sample(11.9, since: first["cursor"] as? String)
    #expect(second["cpu"] == nil)
    let third = try sample(13.8, since: second["cursor"] as? String)
    #expect(third["cpu"] != nil)
    let reset = try sample(10, since: first["cursor"] as? String, now: 601)
    #expect(reset["deltaReset"] as? String == "expired")
    #expect(try sample(10, since: "bad")["deltaReset"] as? String == "unknown_cursor")
}

@Test func deltaClearsUnavailableAndRemovedOptionalSections() throws {
    let cache = SnapshotDelta()
    let first = try cache.response(["battery": ["percent": 65], "unavailable": ["memory"]], since: nil, now: 0) { _ in true }
    let next = try cache.response([:], since: first["cursor"] as? String, now: 1) { _ in true }
    #expect(next["battery"] is NSNull)
    #expect(next["unavailable"] as? [String] == [])
}

@Test func trackCursorCarriesEventWatermarkAndLateSpikeCaptureAcrossReads() throws {
    let directory = TestTemp.dir()
    let manager = TrackManager(home: directory)
    let options = try TrackOptions(selector: .pid(getpid(), startToken: nil))
    var report = try manager.start(options)
    defer { _ = try? manager.stop(report.trackId) }
    let spike = TrackReport.Spike(t: Date(), pid: getpid(), name: "worker", cpuPercent: 120)
    report.spikes = [spike]
    func response(_ since: String?) throws -> [String: Any] {
        try TrackDelta.response(report: report, home: directory, since: since) {
            try JSONSerialization.data(withJSONObject: $0).count
        }
    }
    let full = try response(nil)
    let previous = try #require(full["cursor"] as? String)
    #expect(previous.utf8.count <= 64)
    let oldTotal = report.events.count + (report.eventsOmitted ?? 0)
    report.events = (0..<8).map { _ in .init(t: Date(), kind: "spawn", pid: getpid()) }
    report.eventsOmitted = oldTotal + 40 - 8
    report.spikes[0].sampleTopFrames = ["finished"]
    let delta = try response(previous)
    #expect((delta["events"] as? [[String: Any]])?.count == 8)
    #expect(delta["eventsOmitted"] as? Int == 32)
    let spikes = try #require(delta["spikes"] as? [[String: Any]])
    #expect(spikes.count == 1 && spikes[0]["sampleTopFrames"] as? [String] == ["finished"])
    for _ in 0..<8 { _ = try response(nil) }
    #expect(try response(previous)["deltaReset"] as? String == "expired")
}

@Test func snapshotSectionToleranceBoundaries() throws {
    let cases: [(String, String, Double, Double, Double)] = [
        ("cpu", "usagePercent", 40, 42, 42.1), ("cpu", "loadAverage1m", 1, 1.5, 1.6),
        ("memory", "usedPercent", 60, 61, 61.1), ("memory", "usedBytes", 5000, 5100, 5101),
        ("disk", "availableBytes", 100, 1073741924, 1073741925),
        ("network", "receivedBytesPerSecond", 1000000, 1250000, 1250001),
        ("battery", "percent", 55, 53, 52), ("battery", "minutesRemaining", 50, 65, 66)
    ]
    for (section, field, start, inside, outside) in cases {
        let cache = SnapshotDelta()
        func sample(_ value: Double, since: String?) throws -> [String: Any] {
            var fields: [String: Any] = [field: value]
            if section == "memory" { fields["totalBytes"] = 10000 }
            if section == "network" { fields["sentTotalBytes"] = 100; fields["receivedTotalBytes"] = 200 }
            return try cache.response([section: fields], since: since, now: 1) { _ in true }
        }
        let first = try sample(start, since: nil)
        let second = try sample(inside, since: first["cursor"] as? String)
        #expect((second["unchanged"] as? [String])?.contains(section) == true, "within tolerance: \(section).\(field)")
        let third = try sample(outside, since: second["cursor"] as? String)
        #expect((third["unchanged"] as? [String])?.contains(section) == false, "outside tolerance: \(section).\(field)")
    }
}

@Test func expiringAStoredTrackRemovesItsCursorIndex() throws {
    let home = TestTemp.dir()
    let manager = TrackManager(home: home)
    let options = try TrackOptions(selector: .pid(getpid(), startToken: nil))
    let id = try manager.start(options).trackId
    var report = try manager.stop(id)
    _ = try TrackDelta.response(report: report, home: home, since: nil) { _ in 1 }
    let directory = TrackDelta.directory(id, home: home)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast],
        ofItemAtPath: TrackManager.tracksDir(home).appendingPathComponent(id + ".json").path)
    for number in 0..<TrackManager.maxStoredReports {
        report.trackId = "trk-fixture-\(number)"
        TrackManager.save(report, home: home)
    }
    #expect(TrackManager.load(id, home: home) == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
