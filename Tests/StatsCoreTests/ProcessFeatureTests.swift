import Darwin
import Foundation
import Testing
@testable import StatsCore

// MARK: - Helpers

private func tempDir() -> URL { TestTemp.dir() }

/// A child process killed when the test ends.
final class Child {
    let process = Process()
    var pid: Int32 { process.processIdentifier }

    init(_ executable: String, _ args: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func sh(_ script: String) throws -> Child { try Child("/bin/sh", ["-c", script]) }

    func kill() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    deinit { kill() }
}

/// Polls `condition` until it holds or `timeout` passes.
@discardableResult
func eventually(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}

/// Copies /bin/sleep under a unique name (ad-hoc signed so it runs), for name/path tracking tests.
func uniqueSleeper(in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("aistats-sleeper-\(UUID().uuidString.prefix(6).lowercased())")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: url)
    let r = try Subprocess.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path], timeout: 30)
    #expect(r.succeeded, "codesign: \(r.stderr)")
    return url
}

// MARK: - find_processes

@Suite(.serialized) struct FindProcessesTests {
    @Test func findsByPidAndDetectsReuse() throws {
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        #expect(eventually { Proc.name(child.pid) == "sleep" })
        let r = ProcessFinder.find(.pid(child.pid, startToken: nil))
        let row = try #require(r.processes.first)
        #expect(row.name == "sleep")
        #expect(row.ppid == getpid())
        #expect((row.footprintBytes ?? 0) > 0)
        #expect(row.path == nil, "paths only when matched by path")
        let token = try #require(row.startToken)
        #expect(ProcessFinder.find(.pid(child.pid, startToken: token)).processes.count == 1)

        let reused = ProcessFinder.find(.pid(child.pid, startToken: "12345"))
        #expect(reused.processes.isEmpty)
        #expect(reused.note?.contains("reused") == true)
        #expect(throws: TrackError.self) {
            _ = try TrackManager(home: tempDir()).start(TrackOptions(selector: .pid(child.pid, startToken: "12345")))
        }
    }

    @Test func findsByNameGlobAndPath() throws {
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        #expect(eventually { Proc.name(child.pid) == "sleep" })
        let exact = ProcessFinder.find(.name("SLEEP", glob: false), limit: 15)
        #expect(exact.matched >= 1)
        #expect(exact.processes.allSatisfy { $0.path == nil })
        #expect(ProcessFinder.find(.name("sle*", glob: true), limit: 15).matched >= 1)
        let byPath = ProcessFinder.find(.path("/bin/sleep", glob: false), limit: 15)
        // Other tests run sleeps too, so ours may be past the limit; every row must carry the path.
        #expect(byPath.matched >= 1)
        #expect(byPath.processes.allSatisfy { $0.path == "/bin/sleep" && $0.name == "sleep" })
        #expect(ProcessFinder.find(.path("/bin/sl*", glob: true), limit: 15).matched >= 1)
        #expect(ProcessFinder.find(.name("no-such-process-\(UUID().uuidString.prefix(6))", glob: false)).processes.isEmpty)
    }

    @Test func limitTruncates() {
        let r = ProcessFinder.find(.name("*", glob: true), limit: 2)
        #expect(r.processes.count == 2)
        #expect(r.truncated)
        #expect(r.matched > 2)
    }

    @Test func unreadableProcessIsMarkedNotZero() throws {
        // launchd belongs to root: it exists but its usage can't be read.
        let r = ProcessFinder.find(.pid(1, startToken: nil))
        let row = try #require(r.processes.first)
        #expect(row.footprintBytes == nil)
        #expect(row.startToken == nil)
        #expect(row.unreadable?.contains("footprintBytes") == true)
        #expect(r.note?.contains("another user") == true)
    }

    @Test func selectorValidation() {
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: 1, startToken: nil, name: "x", path: nil, match: nil) }
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: nil, startToken: nil, name: nil, path: nil, match: nil) }
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: nil, startToken: nil, name: String(repeating: "a", count: 65), path: nil, match: nil) }
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: nil, startToken: nil, name: nil, path: "relative/x", match: nil) }
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: nil, startToken: nil, name: "x", path: nil, match: "regex") }
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: 5, startToken: "abc", name: nil, path: nil, match: nil) }
        #expect((try? ProcessSelector.parse(pid: nil, startToken: nil, name: "x*", path: nil, match: "glob")) == .name("x*", glob: true))
    }
}

// MARK: - track_processes

@Suite(.serialized) struct TrackTests {
    func manager() -> TrackManager {
        let m = TrackManager(home: tempDir())
        m.discoveryInterval = 300_000_000
        return m
    }

    @Test func firstCPUSampleIsNullAndPidTrackEndsOnExit() throws {
        let child = try Child("/bin/sleep", ["2"])
        defer { child.kill() }
        let m = manager()
        let finished = DispatchSemaphore(value: 0)
        let started = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 30, intervalSeconds: 1),
                                  onFinish: { _ in finished.signal() })
        #expect(started.aggregate.cpuPercent == nil, "first CPU sample must be null, not 0")
        #expect(started.validSamples == 0)
        #expect(started.members.first?.cpuPercent == nil)
        #expect((started.aggregate.footprintBytes?.last ?? 0) > 0)
        #expect(finished.wait(timeout: .now() + 60) == .success)
        let r = try #require(m.status(started.trackId))
        #expect(r.state == "ended")
        #expect(r.endReason == "target_exited")
        #expect(r.validSamples >= 1)
        #expect(r.aggregate.cpuPercent != nil)
        #expect((r.aggregate.largestProcessLifetimePeakBytes ?? 0) >= (r.aggregate.footprintBytes?.max ?? 0))
        #expect(r.instances.first?.exitedAt != nil)
        #expect(r.restartCount == nil)
    }

    @Test func execRenamesMember() throws {
        let child = try Child.sh("sleep 0.6; exec /bin/sleep 5")
        defer { child.kill() }
        let m = manager()
        let r0 = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 30, intervalSeconds: 1))
        #expect(r0.members.first?.name == "sh")
        #expect(eventually(30) { m.status(r0.trackId)?.members.first?.name == "sleep" })
        let r = try #require(m.status(r0.trackId))
        // macOS /bin/sh re-execs bash first, so the chain is sh → bash → sleep.
        #expect(r.events.contains { $0.kind == "exec" && $0.name == "sleep" && $0.detail?.hasPrefix("was ") == true }, "\(r.events)")
        #expect(r.state == "running", "exec keeps the pid and start time: same instance")
        _ = try m.stop(r0.trackId)
    }

    @Test func nameTrackCountsRestarts() throws {
        let dir = tempDir()
        let sleeper = try uniqueSleeper(in: dir)
        let name = sleeper.lastPathComponent
        let m = manager()
        let a = try Child(sleeper.path, ["30"])
        defer { a.kill() }
        #expect(eventually { Proc.name(a.pid) == name })
        let start = try m.start(TrackOptions(selector: .name(name, glob: false), durationSeconds: 60, intervalSeconds: 1))
        #expect(start.instances.count == 1)
        #expect(start.restartCount == 0)
        a.kill()
        let b = try Child(sleeper.path, ["30"])
        defer { b.kill() }
        // b starts after a exited (no instance running in between): a restart, not an additional instance.
        #expect(eventually(30) { (m.status(start.trackId)?.restartCount ?? 0) == 1 })
        let r = try #require(m.status(start.trackId))
        #expect(r.instances.count == 2)
        #expect(r.instances.first { $0.pid == a.pid }?.exitedAt != nil)
        #expect(r.instances.first { $0.pid == b.pid }?.exitedAt == nil)
        #expect(r.events.contains { $0.kind == "restart" && $0.pid == b.pid })
        #expect(r.additionalInstances == 0)
        #expect(r.members.allSatisfy { $0.path == nil })

        // Fitting a response into a byte budget trims lists but keeps the totals.
        let small = r.fitting(maxBytes: 300)
        #expect(small.events.count <= 2 && small.members.count <= 1 && small.instances.count <= 1)
        #expect(small.events.count + (small.eventsOmitted ?? 0) == r.events.count + (r.eventsOmitted ?? 0))
        #expect(small.instances.count + (small.instancesOmitted ?? 0) == r.instances.count + (r.instancesOmitted ?? 0))
        #expect(r.fitting(maxBytes: 100_000).events.count == r.events.count)

        // Path selector reports paths.
        let selector = try ProcessSelector.parse(pid: nil, startToken: nil, name: nil, path: sleeper.path, match: nil)
        let byPath = try m.start(TrackOptions(selector: selector, durationSeconds: 30, intervalSeconds: 1))
        let real = try #require(ProcessSelector.realPath(sleeper.path))
        #expect(byPath.members.first?.path == real)
        #expect(byPath.members.first?.pid == b.pid)
        #expect(byPath.restartCount == 0, "instances found by the first scan are not restarts")
        m.stopAll(reason: "test")
    }

    @Test func countsShortLivedChildSpawns() throws {
        let child = try Child.sh("sleep 1; i=0; while [ $i -lt 150 ]; do /usr/bin/true; i=$((i+1)); done; sleep 1")
        defer { child.kill() }
        let m = manager()
        let finished = DispatchSemaphore(value: 0)
        var final: TrackReport?
        // The track ends when the shell exits; the duration is only a backstop for a very busy Mac.
        _ = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), includeChildren: true, durationSeconds: 600, intervalSeconds: 1),
                        onFinish: { final = $0; finished.signal() })
        #expect(finished.wait(timeout: .now() + 300) == .success)
        let r = try #require(final)
        #expect(r.endReason == "target_exited")
        let spawn = try #require(r.spawn)
        #expect(spawn.method == "kqueue+polling")
        // 151 forks happen; kqueue merges events it can't deliver promptly (much more so on a saturated
        // Mac), so the count is a lower bound: it must show many short-lived spawns, never more than happened.
        #expect(spawn.forks >= 15, "forks \(spawn.forks)")
        #expect(spawn.forksLowerBound)
        #expect(spawn.forks <= 160)
        #expect(spawn.childrenAttributed >= 1)
        #expect(spawn.unattributedForks == max(0, spawn.forks - spawn.childrenAttributed))
        #expect(spawn.forksPerBucket.reduce(0, +) == spawn.forks)
        #expect(spawn.bucketSeconds == 60)
        #expect(spawn.byExecutable.reduce(0) { $0 + $1.count } == spawn.childrenAttributed)
        #expect(spawn.byExecutable.contains { $0.name == "true" || $0.name == "sleep" || $0.name == "sh" })
    }

    @Test func spikeCaptureIsRateLimited() throws {
        let busy = try Child.sh("while :; do :; done")
        defer { busy.kill() }
        let m = manager()
        // Captures are limited to one per interval; make the interval longer than the test can run.
        m.spikeCaptureInterval = 3_600_000_000_000
        // A low threshold: on a saturated machine the spinning shell gets well under a full core.
        let start = try m.start(TrackOptions(selector: .pid(busy.pid, startToken: nil), durationSeconds: 600, intervalSeconds: 1,
                                             spikeCpuPercent: 10))
        #expect(eventually(240) { (m.status(start.trackId)?.spikesRateLimited ?? 0) >= 2 })
        let r = try m.stop(start.trackId)
        #expect(r.spikes.count == 1, "one thread capture per interval")
        let spike = try #require(r.spikes.first)
        #expect(spike.cpuPercent >= 10)
        #expect(spike.threads?.isEmpty == false)
        #expect(r.events.contains { $0.kind == "spike" })
        #expect(r.state == "stopped")
    }

    @Test func persistsAndLimitsActiveTracks() throws {
        let home = tempDir()
        let m = TrackManager(home: home)
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        var ids: [String] = []
        for _ in 0..<TrackManager.maxActive {
            ids.append(try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60)).trackId)
        }
        #expect(throws: TrackError.self) { _ = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil))) }
        _ = try m.stop(ids[0])
        #expect(m.activeCount == TrackManager.maxActive - 1)
        // Another session (or after this one ends) reads the saved summary.
        let other = TrackManager(home: home)
        #expect(other.status(ids[0])?.state == "stopped")
        #expect(other.status(ids[1])?.state == "running", "owner process is alive")
        #expect(other.list().count == TrackManager.maxActive)
        m.stopAll(reason: "session_ended")
        #expect(TrackManager.load(ids[1], home: home)?.endReason == "session_ended")
        #expect(TrackManager.load("../etc/passwd", home: home) == nil)
    }

    @Test func optionValidation() {
        #expect(throws: ProcessSelector.Invalid.self) { try TrackOptions(selector: .pid(1, startToken: nil), durationSeconds: 5) }
        #expect(throws: ProcessSelector.Invalid.self) { try TrackOptions(selector: .pid(1, startToken: nil), durationSeconds: 7201) }
        #expect(throws: ProcessSelector.Invalid.self) { try TrackOptions(selector: .pid(1, startToken: nil), intervalSeconds: 0.5) }
    }

    @Test func sampleTopFramesParsing() {
        let text = """
        Call graph:
            2 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
        Total number in stack (recursive counted multiple, when >=5):

        Sort by top of stack, same collapsed (when >= 5):
                spin  (in sh) + 12  [0x1]        800
                __read_nocancel  (in libsystem_kernel.dylib) + 8  [0x2]        20

        Binary Images:
        """
        #expect(SampleCapture.topFrames(text) == ["spin  (in sh) + 12  [0x1]        800",
                                                  "__read_nocancel  (in libsystem_kernel.dylib) + 8  [0x2]        20"])
    }
}

// MARK: - wait_for

@Suite(.serialized) struct WaitTests {
    @Test func processExitIsMet() throws {
        let child = try Child("/bin/sleep", ["1"])
        defer { child.kill() }
        let token = try #require(Proc.usage(child.pid)).start
        let r = Waiter(condition: .processExit(pid: child.pid, startToken: String(token)), timeout: 55).run()
        #expect(r.state == "met")
        #expect(r.lastObservation?.processAlive == false)
    }

    @Test func processExitUnavailableWhenNotVisible() {
        let r = Waiter(condition: .processExit(pid: 99_999_999 % Int32.max, startToken: nil), timeout: 5).run()
        #expect(r.state == "unavailable")
        let root = Waiter(condition: .processExit(pid: 1, startToken: nil), timeout: 5).run()
        #expect(root.state == "unavailable")
        #expect(root.reason?.contains("another user") == true)
    }

    @Test func cpuIdleTimesOutWithCulprits() throws {
        let busy = try Child.sh("while :; do :; done")
        defer { busy.kill() }
        // Below 0 % can never hold, so the wait must time out however little CPU a saturated Mac gives
        // the spinning shell; what it reports is the shell as the culprit.
        let r = Waiter(condition: .cpuIdle(.selector(.pid(busy.pid, startToken: nil)), belowPercent: 0), timeout: 4).run()
        #expect(r.state == "timed_out")
        #expect(r.lastObservation?.valid == true)
        #expect((r.lastObservation?.cpuPercent ?? 0) > 0)
        #expect(r.culprits?.first?.pid == busy.pid)
        #expect((r.culprits?.first?.cpuPercent ?? 0) > 0)
    }

    @Test func cpuIdleMetForIdleProcess() throws {
        let idle = try Child("/bin/sleep", ["30"])
        defer { idle.kill() }
        let r = Waiter(condition: .cpuIdle(.selector(.pid(idle.pid, startToken: nil)), belowPercent: 20), timeout: 55).run()
        #expect(r.state == "met")
        #expect(r.elapsedSeconds >= 1.5, "needs two consecutive 1 s observations")
    }

    @Test func systemCPUIdleReturnsObservation() {
        let r = Waiter(condition: .cpuIdle(.system, belowPercent: 101), timeout: 55).run()
        #expect(r.state == "met")
        #expect(r.lastObservation?.cpuPercent != nil)
        let t = Waiter(condition: .cpuIdle(.system, belowPercent: 0), timeout: 1.5).run()
        #expect(t.state == "timed_out")
        #expect(t.culprits != nil)
    }

    @Test func unknownTrackIsUnavailable() {
        let r = Waiter(condition: .cpuIdle(.track("trk-nope"), belowPercent: 20), timeout: 2, tracks: TrackManager(home: tempDir())).run()
        #expect(r.state == "unavailable")
    }

    @Test func cancelSuppressesCompletion() throws {
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        let w = Waiter(condition: .processExit(pid: child.pid, startToken: nil), timeout: 3)
        let called = DispatchSemaphore(value: 0)
        w.start { _ in called.signal() }
        usleep(300_000)
        w.cancel()
        // Well past the 3 s timeout: a cancelled wait never completes.
        #expect(called.wait(timeout: .now() + 6) == .timedOut)
    }
}

// MARK: - Diagnosis, environment, sampler

@Suite struct DiagnosisTests {
    func snapshot() -> Snapshot { SystemSampler().measure(interval: 0.1) }

    @Test func busyCPUIsAnIssue() {
        var s = snapshot()
        s.cpu.usagePercent = 97
        s.memory.pressure = "normal"
        s.thermalState = "nominal"
        s.disk?.availableBytes = 500 << 30
        s.disk?.availableForImportantUsageBytes = 500 << 30
        s.battery = nil
        s.unavailable = nil
        let top = [ProcessUsage(pid: 1, name: "swift-frontend", cpuPercent: 640, memoryBytes: 1)]
        let d = Diagnosis.make(purpose: "heavy_work", snapshot: s, top: top)
        #expect(d.status == "issue_detected")
        #expect(d.readiness == "caution")
        #expect(d.evidence.map(\.metric) == ["cpu"])
        #expect(d.evidence.first?.detail.contains("swift-frontend") == true)
    }

    @Test func allClearAndInsufficientData() {
        var s = snapshot()
        s.cpu.usagePercent = 10
        s.memory.pressure = "normal"
        s.thermalState = "nominal"
        s.disk?.availableBytes = 500 << 30
        s.disk?.availableForImportantUsageBytes = 500 << 30
        s.battery = .init(percent: 80, isCharging: false, powerSource: "Battery Power", minutesRemaining: nil)
        s.unavailable = nil
        let ok = Diagnosis.make(purpose: "heavy_work", snapshot: s, top: [])
        #expect(ok.status == "no_clear_issue")
        #expect(ok.readiness == "ready")
        s.unavailable = ["cpu"]
        let unknown = Diagnosis.make(purpose: "heavy_work", snapshot: s, top: [])
        #expect(unknown.status == "insufficient_data")
        #expect(unknown.readiness == "unknown")
        s.unavailable = nil
        s.battery?.percent = 10
        s.thermalState = "critical"
        s.memory.pressure = "warning"
        s.disk?.availableForImportantUsageBytes = 1 << 30
        s.cpu.usagePercent = 99
        let many = Diagnosis.make(purpose: "slowdown", snapshot: s, top: [])
        #expect(many.evidence.count == 4, "at most 4 evidence items")
        #expect(many.readiness == nil)
        #expect(many.evidence.first?.metric == "thermal" || many.evidence.first?.metric == "diskFree")
    }

    @Test func firstSampleMarksRatesUnavailable() {
        let sampler = SystemSampler()
        let first = sampler.sample()
        #expect(first.unavailable?.contains("cpu") == true)
        #expect(first.unavailable?.contains("network") == true)
        // The kernel's CPU tick counters can stall for a moment under load; that sample is then
        // reported unavailable rather than 0%, and a later one succeeds.
        var second = sampler.sample()
        #expect(eventually(30) {
            usleep(300_000)
            second = sampler.sample()
            return second.isAvailable("cpu")
        })
        #expect(second.isAvailable("network"))
    }

    /// Review LOW 19: equal disk totals passed with caching disabled; count the actual reads instead.
    @Test func slowMetricsAreCached() {
        let cached = SystemSampler(slowMetricsInterval: 60)
        for _ in 0..<3 { _ = cached.sample() }
        #expect(cached.slowMetricReads == 1)
        let uncached = SystemSampler(slowMetricsInterval: 0)
        for _ in 0..<3 { _ = uncached.sample() }
        #expect(uncached.slowMetricReads == 3)
    }

    @Test func environmentReport() {
        let e = EnvironmentProbe.collect(includeToolchain: false)
        #expect(e.toolchain == nil)
        #expect(e.memoryBytes > 0 && e.logicalCores > 0)
        #expect(!e.macOSVersion.isEmpty)
        #expect(EnvironmentProbe.parseSwiftVersion("swift-driver version: 1.1 Apple Swift version 6.4.2 (swiftlang-6.4.2)") == "6.4.2")
    }
}
