import Darwin
import Foundation
import Testing
@testable import StatsCore

// Regression tests for the independent review's findings (process tracking, waits, subprocesses,
// retention, metrics). Timing is generous: these run on a Mac whose load average is often 100+.

private func tempDir() -> URL { TestTemp.dir() }

/// Copies a system binary under `name` in `dir` (ad-hoc signed so it runs).
private func copyBinary(_ source: String, to dir: URL, name: String) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: url)
    let r = try Subprocess.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path], timeout: 120)
    #expect(r.succeeded, "codesign: \(r.stderr)")
    return URL(fileURLWithPath: ProcessSelector.realPath(url.path) ?? url.path)
}

private func manager(_ home: URL = tempDir()) -> TrackManager {
    let m = TrackManager(home: home)
    m.discoveryInterval = 300_000_000
    return m
}

@Suite(.serialized) struct WaitRegressionTests {
    /// Review MEDIUM 5: a wrong startToken, a name matching nothing, an exited pid and a finished track
    /// all reported cpu_idle as met.
    @Test func cpuIdleNeedsALiveMatchingInstance() throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.kill() }
        let wrong = Waiter(condition: .cpuIdle(.selector(.pid(child.pid, startToken: "12345")), belowPercent: 50), timeout: 5).run()
        #expect(wrong.state == "unavailable")
        #expect(wrong.reason?.contains("reused") == true)

        let nobody = Waiter(condition: .cpuIdle(.selector(.name("no-such-\(UUID().uuidString.prefix(8))", glob: false)), belowPercent: 50),
                            timeout: 3).run()
        #expect(nobody.state == "unavailable", "no match is never idle: \(nobody.state)")

        // A busy process that is killed mid-wait: the wait ends unavailable, not met.
        let busy = try Child.sh("while :; do :; done")
        defer { busy.kill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { busy.kill() }
        let gone = Waiter(condition: .cpuIdle(.selector(.pid(busy.pid, startToken: nil)), belowPercent: 0.001), timeout: 55).run()
        #expect(gone.state == "unavailable", "\(gone.state) \(gone.reason ?? "")")
        #expect(gone.reason?.contains("exited") == true)

        // A track that already finished is not a running track.
        let m = manager()
        let t = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60))
        _ = try m.stop(t.trackId)
        let ended = Waiter(condition: .cpuIdle(.track(t.trackId), belowPercent: 50), timeout: 3, tracks: m).run()
        #expect(ended.state == "unavailable")
    }

    /// Review MEDIUM 6: a 2.2 s timeout returned after ~3.1 s (it waited for the next 1 s tick).
    /// Re-review L2: the sampling period is set far past the timeout, so only the deadline timer can end
    /// the wait in time (without it this takes 30 s and fails).
    @Test func timeoutDoesNotWaitForTheNextTick() {
        let begin = Proc.nowNs()
        let waiter = Waiter(condition: .cpuIdle(.system, belowPercent: 0), timeout: 2.2)
        waiter.tickPeriod = 30
        let r = waiter.run()
        let wall = Double(Proc.nowNs() - begin) / 1e9
        #expect(r.state == "timed_out")
        #expect(r.elapsedSeconds <= 2.2)
        #expect(wall >= 2.2)
        // Generous for a loaded Mac; the old code needed a whole extra tick plus scheduling delay.
        #expect(wall < 2.2 + 3, "returned after \(wall) s")
    }

    /// Review MEDIUM 6: a 70 s track with a 60 s interval ran to ~120 s. Scaled: 12 s with a 10 s interval.
    @Test func trackEndsAtItsDurationNotTheNextTick() throws {
        let child = try Child("/bin/sleep", ["120"])
        defer { child.kill() }
        let m = manager()
        let done = DispatchSemaphore(value: 0)
        var final: TrackReport?
        _ = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 12, intervalSeconds: 10),
                        onFinish: { final = $0; done.signal() })
        #expect(done.wait(timeout: .now() + 120) == .success)
        let r = try #require(final)
        #expect(r.endReason == "duration_elapsed")
        let ran = try #require(r.endedAt).timeIntervalSince(r.startedAt)
        // The next tick would have been at 20 s.
        #expect(ran >= 11.9 && ran < 19.5, "ended after \(ran) s")
    }
}

@Suite(.serialized) struct TrackRegressionTests {
    /// Review MEDIUM 7: exec to another path with the same short name kept the old cached path.
    @Test func execToSameNameElsewhereRefreshesThePath() throws {
        let root = tempDir()
        let name = "aistats-x\(UUID().uuidString.prefix(4).lowercased())"
        let a = try copyBinary("/bin/bash", to: root.appendingPathComponent("a"), name: name)
        let b = try copyBinary("/bin/sleep", to: root.appendingPathComponent("b"), name: name)
        let marker = root.appendingPathComponent("go")
        let child = try Child(a.path, ["-c", "while [ ! -e '\(marker.path)' ]; do /bin/sleep 0.1; done; exec '\(b.path)' 60"])
        defer { child.kill() }
        let directory = ProcessDirectory()
        #expect(eventually { directory.scan()?.first { $0.pid == child.pid }?.path == a.path })
        try "".write(to: marker, atomically: true, encoding: .utf8)
        #expect(eventually { Proc.path(child.pid) == b.path })
        // Same pid, start time and short name: only the path changed.
        let selector = ProcessSelector.path(b.path, glob: false)
        let row = directory.scan(refreshPath: selector.pathRefreshFilter)?.first { $0.pid == child.pid }
        #expect(row?.path == b.path)
        let found = ProcessFinder.find(selector, directory: directory)
        #expect(found.processes.contains { $0.pid == child.pid })
    }

    /// Review MEDIUM 8: descendants of a path-matched process got absolute paths in the report and on disk.
    @Test func onlySelectorMatchesCarryPaths() throws {
        let root = tempDir()
        let name = "aistats-p\(UUID().uuidString.prefix(4).lowercased())"
        let parent = try copyBinary("/bin/bash", to: root, name: name)
        let child = try Child(parent.path, ["-c", "while :; do /bin/sleep 0.5; done"])
        defer { child.kill() }
        let home = tempDir()
        let m = manager(home)
        let t = try m.start(TrackOptions(selector: .path(parent.path, glob: false), includeChildren: true, durationSeconds: 120, intervalSeconds: 1))
        #expect(eventually(60) { (m.status(t.trackId)?.aggregate.membersSeen ?? 0) >= 3 })
        let r = try m.stop(t.trackId)
        for member in r.members {
            #expect(member.path == (member.name == name ? parent.path : nil), "\(member.name) has \(member.path ?? "no path")")
        }
        let stored = try String(contentsOf: home.appendingPathComponent("tracks/\(t.trackId).json"), encoding: .utf8)
        #expect(!stored.contains("/bin/sleep"))
        // Read back from disk, the matched path survives (it was checked); nothing else has one.
        let loaded = try #require(TrackManager.load(t.trackId, home: home))
        #expect(loaded.members.contains { $0.name == name && $0.path == parent.path })
        #expect(loaded.members.allSatisfy { $0.path == nil || $0.name == name })
    }

    /// Review MEDIUM 9: phantom roots past the member limit, totals shrinking on eviction, and every new
    /// instance counted as a restart while the original still ran.
    @Test func memberLimitCountsAndRestartSemantics() throws {
        let dir = tempDir()
        let sleeper = try uniqueSleeper(in: dir)
        let name = sleeper.lastPathComponent
        let m = manager()
        m.maxMembers = 2
        let a = try Child(sleeper.path, ["120"]), b = try Child(sleeper.path, ["120"]), c = try Child(sleeper.path, ["120"])
        defer { [a, b, c].forEach { $0.kill() } }
        #expect(eventually { [a, b, c].allSatisfy { Proc.name($0.pid) == name } })
        let t = try m.start(TrackOptions(selector: .name(name, glob: false), durationSeconds: 600, intervalSeconds: 1))
        #expect(t.aggregate.membersSeen == 3)
        #expect(t.membersDropped == 1)
        #expect(t.instances.count == 2, "the refused instance is not recorded as an instance")
        #expect(t.restartCount == 0 && t.additionalInstances == 0)

        // A measured one exits; a new one starts while others still run: an additional instance, not a restart.
        let measured = Set(t.instances.map(\.pid))
        let victim = try #require([a, b, c].first { measured.contains($0.pid) })
        victim.kill()
        #expect(eventually(60) { (m.status(t.trackId)?.aggregate.liveMembers ?? 2) == 1 })
        let d = try Child(sleeper.path, ["120"])
        defer { d.kill() }
        #expect(eventually(60) { (m.status(t.trackId)?.additionalInstances ?? 0) >= 1 })
        var r = try #require(m.status(t.trackId))
        #expect(r.restartCount == 0)
        #expect(r.aggregate.membersSeen >= 4, "evicting an exited member doesn't lower the total")

        // All gone, then a new one: that's a restart.
        [b, c, d].forEach { $0.kill() }
        #expect(eventually(60) { (m.status(t.trackId)?.aggregate.liveMembers ?? -1) == 0 })
        let e = try Child(sleeper.path, ["120"])
        defer { e.kill() }
        #expect(eventually(60) { (m.status(t.trackId)?.restartCount ?? 0) == 1 })
        r = try m.stop(t.trackId)
        #expect(r.aggregate.membersSeen >= 5)
        #expect((r.aggregate.largestProcessLifetimePeakBytes ?? 0) > 0, "the peak survives evictions")
    }

    /// Review MEDIUM 10: watch registrations are tied to an instance, not a bare pid.
    @Test func watcherRefusesAStaleInstance() throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.kill() }
        let u = try #require(Proc.usage(child.pid))
        let watcher = try #require(ProcWatcher { _ in })
        defer { watcher.stop() }
        #expect(!watcher.watch(Proc.Key(pid: child.pid, start: u.start &+ 1), forks: false), "another instance with this pid")
        #expect(watcher.watch(Proc.Key(pid: child.pid, start: u.start), forks: false))
        #expect(watcher.count == 1)
    }

    /// Review MEDIUM 12: a stop left an in-flight `sample` (and what it started) running and the saved
    /// summary pointing at a capture that never finished.
    @Test func stopReapsSampleCapturesAndFinalizesTheReport() throws {
        let dir = tempDir()
        let pids = dir.appendingPathComponent("pids")
        // A stand-in for /usr/bin/sample that hangs and leaves a grandchild holding its output.
        let tool = dir.appendingPathComponent("fake-sample")
        try "#!/bin/sh\n/bin/sleep 300 &\necho $$ $! > '\(pids.path)'\nwait\n".write(to: tool, atomically: true, encoding: .utf8)
        chmod(tool.path, 0o755)
        let busy = try Child.sh("while :; do :; done")
        defer { busy.kill() }
        let home = tempDir()
        let m = manager(home)
        m.sampleExecutable = tool.path
        let t = try m.start(TrackOptions(selector: .pid(busy.pid, startToken: nil), durationSeconds: 600, intervalSeconds: 1,
                                         spikeCpuPercent: 10, sampleOnSpike: true))
        #expect(eventually(240) { FileManager.default.fileExists(atPath: pids.path) })
        let ids = ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: " ")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(ids.count == 2)
        let begin = Proc.nowNs()
        m.stopAll(reason: "test")
        #expect(Double(Proc.nowNs() - begin) / 1e9 < 30)
        for pid in ids { #expect(eventually(30) { !Proc.exists(pid) || Proc.usage(pid) == nil }, "pid \(pid) still running") }
        let saved = try #require(TrackManager.load(t.trackId, home: home))
        let spike = try #require(saved.spikes.first)
        #expect(spike.sampleError?.contains("cancelled") == true, "\(spike)")
        #expect(spike.sampleFile == nil)
    }

    /// Review MEDIUM 13: finished tracks stayed in memory forever; pruning could delete a running track's
    /// summary; sample files had no limit.
    @Test func retentionIsBounded() throws {
        let home = tempDir()
        let child = try Child("/bin/sleep", ["120"])
        defer { child.kill() }
        let m = TrackManager(home: home)
        var ids: [String] = []
        for _ in 0..<(TrackManager.maxFinishedInMemory + 4) {
            let t = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60))
            _ = try m.stop(t.trackId)
            ids.append(t.trackId)
        }
        #expect(m.heldCount <= TrackManager.maxFinishedInMemory)
        #expect(m.status(ids[0])?.state == "stopped", "evicted tracks are read back from disk")

        // The oldest saved summary belongs to a running track of a live session: pruning keeps it.
        let running = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 600))
        let url = home.appendingPathComponent("tracks/\(running.trackId).json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        // An evicted track is no longer this session's to stop: an explicit error, not a silent status.
        #expect(throws: TrackError.self) { _ = try m.stop(ids[0]) }
        let template = try #require(TrackManager.load(ids[1], home: home))
        for i in 0..<(TrackManager.maxStoredReports + 5) {
            var copy = template
            copy.trackId = "trk-copy\(i)"
            TrackManager.save(copy, home: home)
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "a running track's summary is never pruned")
        #expect(TrackManager.storedIDs(home: home).count <= TrackManager.maxStoredReports + 1)
        m.stopAll(reason: "test")

        let samples = tempDir()
        for i in 0..<(SampleCapture.maxFiles + 5) {
            let f = samples.appendingPathComponent("trk-abc-\(i)-20260101-0000\(String(format: "%02d", i)).txt")
            try "x".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + i))], ofItemAtPath: f.path)
        }
        try "mine".write(to: samples.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        SampleCapture.prune(samples)
        let left = try FileManager.default.contentsOfDirectory(atPath: samples.path)
        #expect(left.filter { $0.hasPrefix("trk-") }.count == SampleCapture.maxFiles)
        #expect(left.contains("notes.txt"))
        #expect(!left.contains("trk-abc-0-20260101-000000.txt"), "oldest removed first")
    }

    /// Review MEDIUM 11: the ladder now also shortens long strings and frames and counts omitted threads.
    @Test func fittingPreservesIdentityAndTotals() throws {
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        let m = manager()
        let t = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60))
        var r = try m.stop(t.trackId)
        r.members[0].path = "/" + String(repeating: "x", count: 3000)
        r.spikes = [.init(t: Date(), pid: 1, name: "n", cpuPercent: 1,
                          threads: (0..<5).map { Proc.ThreadSample(name: "t\($0)", cpuPercent: 1, userSeconds: 0, systemSeconds: 0) },
                          sampleTopFrames: (0..<10).map { _ in String(repeating: "f", count: 160) })]
        let small = r.fitting(maxBytes: 900)
        let size = try JSONEncoder().encode(small).count
        #expect(size <= 1400, "\(size)") // dates encode longer with the default encoder; the server measures exactly
        #expect(small.trackId == r.trackId && small.state == r.state)
        #expect(small.aggregate.membersSeen == r.aggregate.membersSeen)
        let sp = small.spikes.first
        #expect(sp == nil || (sp!.threads?.count ?? 0) + (sp!.threadsOmitted ?? 0) == 5)
    }
}

@Suite struct SubprocessRegressionTests {
    /// Review MEDIUM 12: readers stayed blocked when a grandchild kept the pipe open.
    @Test func grandchildHoldingThePipeDoesNotBlock() throws {
        let begin = Proc.nowNs()
        let r = try Subprocess.run("/bin/sh", ["-c", "/bin/sleep 30 & echo started"], timeout: 60)
        let took = Double(Proc.nowNs() - begin) / 1e9
        #expect(r.status == 0 && r.stdout.contains("started"))
        #expect(took < 20, "returned after \(took) s")
    }

    @Test func cancelEndsTheWholeProcessGroup() throws {
        let dir = tempDir()
        let pids = dir.appendingPathComponent("pids")
        let token = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { token.cancel() }
        let r = try Subprocess.run("/bin/sh", ["-c", "/bin/sleep 300 & echo $! > '\(pids.path)'; wait"], timeout: 120, cancel: token)
        #expect(r.cancelled)
        #expect(!r.succeeded)
        let grandchild = Int32(((try? String(contentsOf: pids, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(grandchild > 0)
        #expect(eventually(30) { !Proc.exists(grandchild) || Proc.usage(grandchild) == nil })
    }

    @Test func timeoutKillsAndReportsIt() throws {
        let r = try Subprocess.run("/bin/sleep", ["60"], timeout: 1)
        #expect(r.timedOut && !r.succeeded)
    }
}

@Suite struct MetricsRegressionTests {
    private func snapshot(unavailable: [String]?) -> Snapshot {
        var s = SystemSampler().measure(interval: 0.1)
        s.unavailable = unavailable
        return s
    }

    /// Review MEDIUM 15: unavailable readings were stored and summarized as zeros.
    @Test func unavailableMetricsAreNotZeros() throws {
        let bad = HistoryPoint(snapshot: snapshot(unavailable: ["cpu", "memory", "network", "memoryPressure", "disk"]))
        #expect(bad.cpuPercent == nil && bad.memoryUsedPercent == nil && bad.receivedBytesPerSecond == nil)
        #expect(bad.memoryPressure == "unknown" && bad.diskAvailableBytes == nil)
        var good = HistoryPoint(snapshot: snapshot(unavailable: nil))
        good.cpuPercent = 40
        let summary = try #require(HistorySummary.make(from: [good, bad, good], maxPoints: 2))
        #expect(summary.cpuPercent?.min == 40, "the missing reading isn't a 0 % minimum")
        #expect(summary.unavailableSamples?["cpu"] == 1)
        let empty = try #require(HistorySummary.make(from: [bad], maxPoints: 1))
        #expect(empty.cpuPercent == nil)
        #expect(empty.text.contains("CPU not measured"))
        let text = snapshot(unavailable: ["cpu", "memory"]).summary
        #expect(text.contains("CPU usage could not be measured") && text.contains("Memory usage could not be read"))
    }

    /// Review MEDIUM 15: heavy_work said ready without pressure or disk readings.
    @Test func readyNeedsEveryReading() {
        var s = snapshot(unavailable: nil)
        s.cpu.usagePercent = 5
        s.memory.pressure = "normal"
        s.thermalState = "nominal"
        s.disk = .init(mountPath: "/", totalBytes: 1 << 40, availableBytes: 500 << 30, availableForImportantUsageBytes: 500 << 30)
        s.battery = nil
        #expect(Diagnosis.make(purpose: "heavy_work", snapshot: s, top: []).readiness == "ready")
        s.unavailable = ["memoryPressure"]
        #expect(Diagnosis.make(purpose: "heavy_work", snapshot: s, top: []).readiness == "unknown")
        s.unavailable = ["disk"]; s.disk = nil
        #expect(Diagnosis.make(purpose: "heavy_work", snapshot: s, top: []).readiness == "unknown")
    }

    /// Review LOW 17: 15 points into 11 dropped the newest (100 %) sample.
    @Test func downsampleKeepsTheNewestPoint() {
        var base = HistoryPoint(snapshot: snapshot(unavailable: nil))
        let now = Date()
        let pts = (0..<15).map { i -> HistoryPoint in
            base.t = now.addingTimeInterval(Double(i)); base.cpuPercent = i == 14 ? 100 : 0; return base
        }
        let d = HistorySummary.downsample(pts, to: 11)
        #expect(d.count == 11)
        #expect(d.last?.t == pts.last?.t)
        #expect((d.last?.cpuPercent ?? 0) > 0, "the last bucket includes the newest sample")
        for n in 1...40 {
            for k in 1...12 where n > k {
                let parts = HistorySummary.downsample(Array(pts.prefix(min(n, 15))), to: k)
                #expect(parts.count == min(k, min(n, 15)))
            }
        }
    }
}
