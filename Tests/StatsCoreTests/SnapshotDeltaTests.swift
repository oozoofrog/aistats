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
    let cursor = try #require(first["cursor"] as? String)
    for suffix in ["01", "+1"] {
        let malformed = String(cursor.dropLast()) + suffix
        #expect(!SnapshotDelta.isCursor(malformed))
        #expect(try sample(10, since: malformed)["deltaReset"] as? String == "unknown_cursor")
    }
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

@Test func snapshotDeltaComparesEverySectionAndRetainsGrowingNetworkTotals() throws {
    typealias Object = [String: Any]
    let top: Object = ["pid": 42, "startToken": "8", "cpuPercent": 40, "memoryBytes": 1000]
    let base: Object = ["cpu": ["usagePercent": 15, "userPercent": 10, "systemPercent": 5, "logicalCores": 4,
                                "loadAverage1m": 1, "loadAverage5m": 2, "loadAverage15m": 3],
                        "memory": ["totalBytes": 10_000, "pressure": "normal", "usedPercent": 10,
                                   "usedBytes": 1000, "appBytes": 100, "wiredBytes": 40, "compressedBytes": 20,
                                   "swapUsedBytes": 20, "cachedBytes": 50],
                        "disk": ["mountPath": "/", "totalBytes": 10000, "availableBytes": 20, "availableForImportantUsageBytes": 50],
                        "network": ["interfaces": ["en0"], "receivedBytesPerSecond": 0, "sentBytesPerSecond": 100,
                                    "receivedTotalBytes": 10, "sentTotalBytes": 20],
                        "battery": ["percent": 70, "isCharging": false, "powerSource": "Battery Power", "minutesRemaining": 30],
                        "topProcesses": [top], "thermalState": "nominal", "timestamp": "fixture",
                        "sampleIntervalSeconds": 0.5, "uptimeSeconds": 100]
    let cache = SnapshotDelta()
    func delta(_ new: Object) throws -> Object {
        let full = try cache.response(base, since: nil, now: 1) { _ in true }
        return try cache.response(new, since: full["cursor"] as? String, now: 1) { _ in true }
    }
    var stable = base
    var net = try #require(stable["network"] as? Object)
    net["receivedTotalBytes"] = 9999
    stable["network"] = net
    let unchanged = try delta(stable)
    #expect(Set(unchanged["unchanged"] as? [String] ?? []) == ["cpu","memory","disk","network","battery","thermalState","topProcesses"])
    #expect((unchanged["network"] as? [String:Int]) == ["receivedTotalBytes":9999,"sentTotalBytes":20])
    for key in ["cursor","delta","unchanged","timestamp","sampleIntervalSeconds","uptimeSeconds","unavailable"] { #expect(unchanged[key] != nil) }
    #expect(try JSONSerialization.data(withJSONObject: unchanged).count <= 400)
    for (section, raw) in base {
        guard let fields = raw as? Object else { continue }
        for (key,value) in fields where !key.hasSuffix("TotalBytes") {
            var changed = fields
            if let text = value as? String { changed[key] = text + " changed" }
            else if value is [String] { changed[key] = ["another"] }
            else if key == "isCharging" { changed[key] = true }
            else { changed[key] = 10_000_000_000 }
            var sample = base
            sample[section] = changed
            let result = try delta(sample)
            #expect(!(result["unchanged"] as? [String] ?? []).contains(section), "\(section).\(key)")
            #expect(result[section] != nil)
        }
    }
    for (field,value) in [("pid", 43 as Any), ("startToken", "9"), ("cpuPercent", 51), ("memoryBytes", 1101)] {
        var changed = top
        changed[field] = value
        var sample = base
        sample["topProcesses"] = [changed]
        #expect(try delta(sample)["topProcesses"] != nil)
    }
    var hot = base
    hot["thermalState"] = "serious"
    #expect(try delta(hot)["thermalState"] as? String == "serious")
    var unavailable = base
    unavailable["unavailable"] = ["cpu"]
    #expect(try delta(unavailable)["cpu"] != nil)
    let first = try cache.response(base, since: nil, now: 0) { _ in true }
    let cursor = try #require(first["cursor"] as? String)
    let other = SnapshotDelta()
    #expect(try other.response(base, since: cursor, now: 0) { _ in true }["deltaReset"] as? String == "unknown_cursor")
    for _ in 0..<8 { _ = try cache.response(base, since: nil, now: 1) { _ in true } }
    #expect(try cache.response(base, since: cursor, now: 2) { _ in true }["deltaReset"] as? String == "expired")
}

@Test func trackDeltaReportsChangesToEverySectionAndPreservesAlwaysFields() throws {
    let home = TestTemp.dir()
    let manager = TrackManager(home: home)
    let id = try manager.start(TrackOptions(selector: .pid(getpid(), startToken: nil), includeChildren: true)).trackId
    let base = try manager.stop(id)
    func response(_ report: TrackReport, _ since: String?) throws -> [String: Any] {
        try TrackDelta.response(report: report, home: home, since: since) { _ in 1 }
    }
    let mutations: [(String,String,(inout TrackReport) -> Void)] = [
        ("config","durationSeconds",{ $0.durationSeconds += 1 }),
        ("members","members",{ $0.members[0].name += " changed" }),
        ("instances","instances",{ $0.instances.append(.init(pid: 300,startToken: "88",startedAt: Date())) }),
        ("spawn","spawn",{ $0.spawn?.forks += 1 }),
        ("notes","notes",{ $0.notes = ["example"] }),
        ("events","events",{ $0.events.append(.init(t: Date(),kind:"exit",pid:300)) }),
        ("spikes","spikes",{ $0.spikes.append(.init(t:Date(),pid:300,name:"worker",cpuPercent:150)) })
    ]
    for (section,field,mutate) in mutations {
        var next = base
        mutate(&next)
        let before = try response(base,nil)
        let result = try response(next,before["cursor"] as? String)
        #expect(result["delta"] as? Bool == true && result[field] != nil)
        #expect(!(result["unchanged"] as? [String] ?? []).contains(section), "\(section)")
        for key in ["trackId","state","endReason","endedAt","elapsedSeconds","validSamples","aggregate",
                    "restartCount","additionalInstances","membersDropped","spikesRateLimited","argsUnreadable"] where before[key] != nil {
            #expect(result[key] != nil, "\(key)")
        }
    }
}
