import Darwin
import Foundation
import Testing
@testable import StatsCore

private typealias Object = [String: Any]
private let local = UInt32(MNT_LOCAL), hidden = UInt32(MNT_DONTBROWSE)
private let gib: UInt64 = 1 << 30

private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

private func wholeSecond(_ d: Date = Date()) -> Date { Date(timeIntervalSince1970: floor(d.timeIntervalSince1970)) }

/// History lines as the app writes them; `read` gives the Disk Read Time of each point (nil leaves it out).
private func writeHistory(_ home: URL, _ points: [(t: Date, free: UInt64?, read: Date?)]) throws {
    let lines = points.map { p -> String in
        var o: Object = ["t": iso(p.t), "memoryPressure": "normal", "cpuPercent": 5.0]
        if let free = p.free { o["diskAvailableBytes"] = free }
        if let read = p.read { o["diskReadAt"] = iso(read) }
        return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    try (lines.joined(separator: "\n") + "\n").write(to: home.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
}

/// Points every 2 s that end at `end`; free space falls `drop` bytes over `span` seconds of 30 s disk reads.
private func drainFixture(end: Date, span: TimeInterval, drop: Int64, base: UInt64 = 500 * gib) -> [(t: Date, free: UInt64?, read: Date?)] {
    let start = end.addingTimeInterval(-span)
    return stride(from: 0.0, through: span, by: 2).map { offset in
        let read = (offset / 30).rounded(.down) * 30
        let free = UInt64(Int64(base) - Int64(Double(drop) * read / span))
        return (start.addingTimeInterval(offset), free, start.addingTimeInterval(read))
    }
}

private func report(at measured: Date, directories: Int = 3, longPaths: Bool = false) -> StorageReport {
    let dirs = (0..<directories).map { i in
        StorageReport.Directory(path: "~/Library/Developer/Xcode/" + (longPaths ? String(repeating: "x", count: 40) : "") + "Root \(i) DeviceSupport",
                                sizeBytes: UInt64(100 - i) * gib, complete: true, mountPath: "/System/Volumes/Data")
    }
    return StorageReport(passStartedAt: measured.addingTimeInterval(-3600), measuredAt: measured, passSeconds: 3600, cpuSeconds: 12.5,
                         slices: 125, slicesSkippedForCpu: 0, endReason: "complete", derivedDataLocation: "custom",
                         deviceSupportOmitted: 0, directories: dirs,
                         notMeasured: [.init(path: "/Volumes/External/DerivedData", reason: "volume_unqualified", source: "xcode_setting")])
}

private func object(_ value: some Encodable) throws -> Object {
    try #require(JSONSerialization.jsonObject(with: MCPServer.encoder.encode(value)) as? Object)
}

private func structured(_ r: [String: Any]?) -> Object? {
    (r?["result"] as? Object)?["structuredContent"] as? Object
}

private let fixedStats: @Sendable (MountEntry) -> VolumeStats? = { m in
    VolumeStats(totalBytes: 1000 * gib, availableBytes: 200 * gib, availableForImportantUsageBytes: 250 * gib, apfsContainer: "disk3")
}

@Suite(.serialized) struct DeveloperStorageTests {
    @Test func volumeListShowsBootDataAndFinderVolumesAndCountsTheRest() throws {
        let mounts = [
            MountEntry(path: "/", fromName: "/dev/disk3s1s1", flags: local),
            MountEntry(path: "/dev", fileSystem: "devfs", flags: local | hidden),
            MountEntry(path: "/System/Volumes/VM", flags: local | hidden),
            MountEntry(path: "/System/Volumes/Data", fromName: "/dev/disk3s5", flags: local | hidden),
            MountEntry(path: "/Volumes/Image", flags: local),
            MountEntry(path: "/Volumes/Share", fileSystem: "smbfs", flags: 0, totalBytes: 4000 * gib, availableBytes: 1000 * gib),
            MountEntry(path: "/Volumes/Gone", fileSystem: "smbfs", flags: 0),
            MountEntry(path: "/Volumes/Broken", flags: local),
        ]
        let list = VolumeList.build(mounts: mounts) { $0.path == "/Volumes/Broken" ? nil : fixedStats($0) }
        #expect(list.volumes.map(\.mountPath) == ["/", "/System/Volumes/Data", "/Volumes/Broken", "/Volumes/Gone", "/Volumes/Image", "/Volumes/Share"])
        #expect(list.volumes.count + list.omitted == mounts.count, "STO-008")
        #expect(list.unavailable == ["/Volumes/Broken", "/Volumes/Gone"])
        let body = try object(DeveloperStorage(appRunning: true, volumes: list.volumes, volumesOmitted: list.omitted,
                                                unavailable: list.unavailable, drain: DrainRate(diskSamples: 0)))
        let rows = try #require(body["volumes"] as? [Object])
        for row in rows {
            let unavailable = list.unavailable.contains(row["mountPath"] as? String ?? "")
            for key in ["totalBytes", "availableBytes"] {
                if unavailable { #expect(row[key] == nil, "STO-011") } else { #expect(row[key] is Int, "STO-009") }
            }
        }
        #expect(rows[0]["availableForImportantUsageBytes"] as? Int == Int(250 * gib) && rows[0]["apfsContainer"] as? String == "disk3")
        let share = try #require(rows.first { $0["mountPath"] as? String == "/Volumes/Share" })
        #expect(share["availableBytes"] as? Int == Int(1000 * gib) && share["network"] as? Bool == true && share["apfsContainer"] == nil)
        let keys = Set(body.keys).union(rows.flatMap(\.keys))
        #expect(!keys.contains { $0.lowercased().contains("sum") || $0.lowercased().contains("total") && $0 != "totalBytes" }, "STO-054")
    }

    @Test func volumeListReturnsWithinTheDeadlineWhenOneVolumeBlocks() {
        let mounts = [MountEntry(path: "/", flags: local), MountEntry(path: "/Volumes/Stuck", flags: local)]
        let start = Date()
        let list = VolumeList.build(mounts: mounts) { m in
            if m.path == "/Volumes/Stuck" { Thread.sleep(forTimeInterval: 30) }
            return fixedStats(m)
        }
        #expect(Date().timeIntervalSince(start) < 0.2, "STO-012")
        #expect(list.unavailable == ["/Volumes/Stuck"] && list.volumes[0].availableBytes == 200 * gib)
    }

    @Test func liveVolumeListReadsTheBootVolume() throws {
        let table = MountEntry.table()
        #expect(table.contains { $0.path == "/" })
        let list = VolumeList.build(mounts: table)
        let boot = try #require(list.volumes.first)
        #expect(boot.mountPath == "/" && (boot.totalBytes ?? 0) > 0 && boot.availableBytes != nil)
        #expect(list.volumes.count + list.omitted == table.count)
        if let container = list.volumes.first(where: { $0.mountPath == VolumeList.bootData })?.apfsContainer {
            #expect(container.hasPrefix("disk") && container == boot.apfsContainer, "STO-053: one APFS container")
        }
    }

    @Test func aBlockedVolumeKeepsOneThreadAcrossCalls() throws {
        let stuck = "/Volumes/Blocked-\(UUID().uuidString.prefix(8))"
        final class Probe: @unchecked Sendable { let lock = NSLock(); var calls = 0; let gate = DispatchSemaphore(value: 0) }
        let probe = Probe()
        let mounts = [MountEntry(path: "/", flags: local), MountEntry(path: stuck, flags: local)]
        let stats: @Sendable (MountEntry) -> VolumeStats? = { m in
            guard m.path == stuck else { return fixedStats(m) }
            probe.lock.lock(); probe.calls += 1; probe.lock.unlock()
            probe.gate.wait()
            return fixedStats(m)
        }
        for _ in 0..<3 {
            let list = VolumeList.build(mounts: mounts, stats: stats)
            #expect(list.unavailable == [stuck] && list.volumes[0].availableBytes == 200 * gib, "STO-012")
        }
        probe.lock.lock(); let blocked = probe.calls; probe.lock.unlock()
        #expect(blocked == 1, "one blocked thread per mount, not one per call")
        probe.gate.signal()
        let deadline = Date().addingTimeInterval(5)
        while VolumeList.probes.isBlocked(stuck), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        probe.gate.signal()
        let list = VolumeList.build(mounts: mounts, stats: stats)
        #expect(list.unavailable.isEmpty && probe.calls == 2, "a mount that answers again is read again")
    }

    @Test func trimmingKeepsTheBootDataVolume() {
        let volumes = ["/", VolumeList.bootData, "/Volumes/A", "/Volumes/B"].map { StorageVolume(mountPath: $0, totalBytes: 1, availableBytes: 1) }
        var result = DeveloperStorage(appRunning: true, volumes: volumes, volumesOmitted: 0, unavailable: [], storage: report(at: Date()),
                                      drain: DrainRate(diskSamples: 0))
        #expect(result.trim() && result.trim() && result.trim())
        #expect(result.volumes.map(\.mountPath) == ["/", VolumeList.bootData] && result.volumesOmitted == 2, "STO-007")
        #expect(result.storage?.directoriesOmitted == 1)
    }

    @Test func drainRateUsesDistinctDiskReadTimes() throws {
        let now = wholeSecond()
        let falling = drainFixture(end: now, span: 1800, drop: Int64(6 * gib)).map { HistoryPoint.decoded($0) }
        let rate = DrainRate.make(points: falling, now: now)
        let expected = Double(12 * gib)
        #expect(abs(Double(rate.drainBytesPerHour ?? 0) - expected) <= expected * 0.01, "STO-036")
        #expect(rate.windowSeconds == 1800 && rate.diskSamples == 61 && rate.reason == nil, "STO-037")

        let rising = drainFixture(end: now, span: 1800, drop: -Int64(gib)).map { HistoryPoint.decoded($0) }
        #expect((DrainRate.make(points: rising, now: now).drainBytesPerHour ?? 0) < 0, "STO-039")
        #expect(rate.drainBytesPerHour! > 0)

        let shared = (0..<15).map { HistoryPoint.decoded((now.addingTimeInterval(Double($0 - 15) * 2), 10 * gib, now.addingTimeInterval(-40))) }
        let single = DrainRate.make(points: shared, now: now)
        #expect(single.drainBytesPerHour == nil && single.reason != nil && single.diskSamples == 1, "STO-038")

        var mixed = falling
        for i in stride(from: 0, to: mixed.count, by: 7) { mixed[i].diskReadAt = nil; mixed[i].diskAvailableBytes = 1 }
        let filtered = DrainRate.make(points: mixed, now: now)
        #expect(filtered.windowSeconds == 1800 && filtered.diskSamples == 61, "STO-048: points without diskReadAt are ignored")
    }

    @Test func toolReportsStorageVolumesAndDrainInOneCall() throws {
        let home = TestTemp.dir()
        let now = wholeSecond()
        try writeHistory(home, drainFixture(end: now, span: 1800, drop: Int64(6 * gib)))
        try StorageFiles.write(report(at: now.addingTimeInterval(-120)), StorageFiles.report, home: home)
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "get_developer_storage")
        let s = try #require(structured(h.response(1)), "STO-030")
        #expect(s["volumes"] is [Any] && s["storage"] is Object && s["drain"] is Object)
        let storage = try #require(s["storage"] as? Object)
        #expect(storage["scope"] as? String == "current_user" && storage["sizeKind"] as? String == "allocated_blocks" && storage["schemaVersion"] as? Int == 1)
        #expect((s["ageSeconds"] as? Int).map { (120...130).contains($0) } == true)
        #expect(s["appRunning"] as? Bool == true && s["startCommand"] == nil)
        let line = try #require(h.line(1))
        #expect(line.utf8.count <= 9216)
        h.call(2, "get_developer_storage", ["x": 1])
        #expect((h.response(2)?["result"] as? Object)?["isError"] as? Bool == true)
        h.close()
        _ = h.finished.wait(timeout: .now() + 5)
    }

    @Test func toolGivesNullStorageWithAReasonAndTheStartCommand() throws {
        let home = TestTemp.dir()
        let now = wholeSecond()
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "get_developer_storage")
        let missing = try #require(structured(h.response(1)))
        #expect(missing.keys.contains("storage") && missing["storage"] is NSNull && missing["storageReason"] as? String == "no_report", "STO-032")
        #expect(missing["appRunning"] as? Bool == false, "STO-033")
        #expect((missing["startCommand"] as? String)?.contains("open -b " + AIStatsPaths.appBundleIdentifier) == true)
        #expect((missing["drain"] as? Object)?["reason"] is String)

        var future = try object(report(at: now))
        future["schemaVersion"] = 99
        try FileManager.default.createDirectory(at: StorageFiles.directory(home), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: future).write(to: StorageFiles.directory(home).appendingPathComponent(StorageFiles.report))
        h.call(2, "get_developer_storage")
        let unsupported = try #require(structured(h.response(2)))
        #expect(unsupported["storage"] is NSNull && unsupported["storageReason"] as? String == "unsupported_schema", "STO-052")
        try Data("{not json".utf8).write(to: StorageFiles.directory(home).appendingPathComponent(StorageFiles.report))
        h.call(3, "get_developer_storage")
        #expect(structured(h.response(3))?["storageReason"] as? String == "unreadable")
        h.close()
        _ = h.finished.wait(timeout: .now() + 5)
    }

    @Test func ageAndPersistedHistoryUseTheCallTime() throws {
        let home = TestTemp.dir()
        let now = wholeSecond()
        try StorageFiles.write(report(at: now.addingTimeInterval(-120)), StorageFiles.report, home: home)
        try writeHistory(home, drainFixture(end: now.addingTimeInterval(-600), span: 1200, drop: Int64(gib)))
        let mounts = [MountEntry(path: "/", flags: local)]
        let stopped = DeveloperStorage.collect(home: home, now: now, mounts: mounts, stats: fixedStats)
        #expect(stopped.ageSeconds == 120, "STO-031")
        #expect(!stopped.appRunning && stopped.drain.drainBytesPerHour != nil && stopped.drain.windowSeconds == 1200, "STO-048")
        try writeHistory(home, drainFixture(end: now.addingTimeInterval(-61 * 60), span: 1200, drop: Int64(gib)))
        let old = DeveloperStorage.collect(home: home, now: now, mounts: mounts, stats: fixedStats)
        #expect(old.drain.drainBytesPerHour == nil && old.drain.reason != nil)
    }

    @Test func fullResultFitsTheResponseBudgetWithOmittedCounts() throws {
        let home = TestTemp.dir()
        let now = wholeSecond()
        let mounts = [MountEntry(path: "/", flags: local), MountEntry(path: "/System/Volumes/Data", flags: local | hidden)]
            + (0..<30).map { MountEntry(path: "/Volumes/External Volume Number \($0) With A Long Name", flags: local) }
        var full = DeveloperStorage.collect(home: home, now: now, mounts: mounts, stats: fixedStats)
        full.storage = report(at: now, directories: 14, longPaths: true)
        full.storageReason = nil
        let server = MCPServer(history: HistoryStore(directory: home), activity: ActivityStore(directory: home),
                               tracks: TrackManager(home: home), name: "t")
        let response = try server.storageResponse(full, id: 1)
        let body = try #require(response["result"] as? Object)
        let data = try #require((body["structuredContent"] as? RawJSON)?.data)
        #expect(data.count <= MCPServer.maxResponseBytes, "STO-034")
        let s = try #require(JSONSerialization.jsonObject(with: data) as? Object)
        let shown = (s["volumes"] as? [Any])?.count ?? 0
        #expect(shown + (s["volumesOmitted"] as? Int ?? 0) == 32 && shown < 32)
        let kept = ((s["volumes"] as? [Object]) ?? []).compactMap { $0["mountPath"] as? String }
        #expect(kept.prefix(2) == ["/", VolumeList.bootData], "STO-007: trimming keeps the boot data volume")
        let storage = try #require(s["storage"] as? Object)
        #expect(((storage["directories"] as? [Any])?.count ?? 0) + (storage["directoriesOmitted"] as? Int ?? 0) == 14)
        #expect(MCPServer.encodeLine(response).count <= 9216)
    }

    @Test func historyPointsCarryTheDiskReadTimeOutsideStatsHistory() throws {
        let sampler = SystemSampler(slowMetricsInterval: 0.3)
        let a = HistoryPoint(snapshot: sampler.sample()), b = HistoryPoint(snapshot: sampler.sample())
        Thread.sleep(forTimeInterval: 0.4)
        let c = HistoryPoint(snapshot: sampler.sample())
        #expect(a.diskAvailableBytes != nil && a.diskReadAt != nil, "STO-047")
        #expect(a.diskReadAt == b.diskReadAt && c.diskReadAt != a.diskReadAt)
        let snapshot = try object(sampler.sample())
        #expect((snapshot["disk"] as? Object)?["readAt"] == nil)

        let home = TestTemp.dir()
        try writeHistory(home, drainFixture(end: wholeSecond(), span: 300, drop: Int64(gib)))
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "get_stats_history", ["minutes": 10, "maxPoints": 60])
        _ = h.response(1)
        h.call(2, "get_stats_history", ["minutes": 10])
        _ = h.response(2)
        for id in [1, 2] {
            let line = try #require(h.line(id))
            #expect(line.contains("diskAvailableBytes") && !line.contains("diskReadAt"), "STO-049")
        }
        h.close()
        _ = h.finished.wait(timeout: .now() + 5)
    }

    @Test func storageFilesArePrivateAndVersioned() throws {
        let home = TestTemp.dir()
        try StorageFiles.write(report(at: Date()), StorageFiles.report, home: home)
        try StorageFiles.write(StorageSchedule(lastPassStartedAt: Date()), StorageFiles.schedule, home: home)
        var st = stat()
        #expect(stat(StorageFiles.directory(home).path, &st) == 0 && st.st_mode & 0o777 == 0o700)
        for name in [StorageFiles.report, StorageFiles.schedule] {
            #expect(stat(StorageFiles.directory(home).appendingPathComponent(name).path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        }
        #expect(StorageFiles.readReport(home: home).report?.schemaVersion == 1)
        #expect((try FileManager.default.contentsOfDirectory(atPath: StorageFiles.directory(home).path)).sorted() == ["report.json", "schedule.json"])
    }
}

extension HistoryPoint {
    static func decoded(_ p: (t: Date, free: UInt64?, read: Date?)) -> HistoryPoint {
        var o: Object = ["t": iso(p.t), "memoryPressure": "normal"]
        if let free = p.free { o["diskAvailableBytes"] = free }
        if let read = p.read { o["diskReadAt"] = iso(read) }
        return try! JSONLinesFile.decoder.decode(HistoryPoint.self, from: JSONSerialization.data(withJSONObject: o))
    }
}
