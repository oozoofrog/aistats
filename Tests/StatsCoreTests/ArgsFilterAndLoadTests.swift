import Darwin
import Foundation
import Testing
@testable import StatsCore

// B1: argument filter on selectors; B2: load average evidence in diagnose_system.

@Suite(.serialized) struct ArgsFilterTests {
    @Test func argumentsAreReadAndValidated() throws {
        let child = try Child("/bin/sleep", ["7777.101"])
        defer { child.kill() }
        #expect(eventually { Proc.arguments(child.pid) == ["7777.101"] }, "argv after argv[0]")
        #expect(Proc.arguments(1) == nil || Proc.arguments(1) != nil, "launchd: unreadable for a normal user, never a crash")
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: 5, startToken: nil, name: nil, path: nil, match: nil, argsContain: "x") }
        #expect(throws: ProcessSelector.Invalid.self) { try ProcessSelector.parse(pid: nil, startToken: nil, name: "x", path: nil, match: nil, argsContain: "") }
        #expect(throws: ProcessSelector.Invalid.self) {
            try ProcessSelector.parse(pid: nil, startToken: nil, name: "x", path: nil, match: nil, argsContain: String(repeating: "a", count: 129))
        }
        #expect(try ProcessSelector.parse(pid: nil, startToken: nil, name: "x", path: nil, match: nil, argsContain: "--daemon")
                == .name("x", glob: false, args: "--daemon"))
    }

    @Test func findTrackAndWaitMatchOnlyProcessesWithTheArgument() throws {
        let daemon = try Child("/bin/sleep", ["7777.202"])
        let client = try Child("/bin/sleep", ["7777.203"])
        defer { daemon.kill(); client.kill() }
        #expect(eventually { Proc.arguments(daemon.pid) != nil && Proc.arguments(client.pid) != nil })

        let both = ProcessFinder.find(.path("/bin/sleep", glob: false, args: "7777.20"), limit: 15)
        #expect(Set(both.processes.map(\.pid)).isSuperset(of: [daemon.pid, client.pid]))
        #expect(both.argsUnreadable != nil, "counted when a filter is used")
        let one = ProcessFinder.find(.path("/bin/sleep", glob: false, args: "7777.202"), limit: 15)
        #expect(one.processes.map(\.pid) == [daemon.pid])
        #expect(ProcessFinder.find(.name("sleep", glob: false, args: "7777.2029")).processes.isEmpty, "substring of an argument, not of argv joined")
        #expect(ProcessFinder.find(.name("sleep", glob: false, args: "sleep")).processes.allSatisfy { $0.pid != daemon.pid }, "argv[0] is not searched")
        #expect(ProcessFinder.find(.name("sleep", glob: false)).argsUnreadable == nil)

        // A shared directory keeps working across calls with different filters (cached argv per instance).
        let directory = ProcessDirectory()
        #expect(ProcessFinder.find(.name("sleep", glob: false, args: "7777.203"), directory: directory).processes.map(\.pid) == [client.pid])
        #expect(ProcessFinder.find(.name("sleep", glob: false, args: "7777.202"), directory: directory).processes.map(\.pid) == [daemon.pid])

        let m = TrackManager(home: TestTemp.dir())
        let t = try m.start(TrackOptions(selector: .path("/bin/sleep", glob: false, args: "7777.202"), durationSeconds: 60, intervalSeconds: 1))
        defer { _ = try? m.stop(t.trackId) }
        #expect(eventually { (m.status(t.trackId)?.instances.count ?? 0) >= 1 })
        let report = try #require(m.status(t.trackId))
        #expect(report.instances.map(\.pid) == [daemon.pid], "the client with the same executable is not mixed in")
        #expect(report.argsFilter == true && report.argsUnreadable != nil)
        let saved = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!saved.contains("7777.202"), "the filter is never stored or returned")

        let result = Waiter(condition: .cpuIdle(.selector(.name("sleep", glob: false, args: "7777.203")), belowPercent: 50), timeout: 10).run()
        #expect(result.state == "met", "\(result)")
        #expect(result.argsUnreadable != nil)
        let none = Waiter(condition: .cpuIdle(.selector(.name("sleep", glob: false, args: "7777.209")), belowPercent: 50), timeout: 3).run()
        #expect(none.state == "unavailable", "no process with the argument is never idle")
    }

    @Test func mcpAcceptsArgsContainAndNeverEchoesIt() throws {
        let home = TestTemp.dir()
        let daemon = try Child("/bin/sleep", ["7777.304"])
        defer { daemon.kill() }
        #expect(eventually { Proc.arguments(daemon.pid) != nil })
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "find_processes", ["name": "sleep", "argsContain": "7777.304"])
        let found = try #require((h.response(1)?["result"] as? [String: Any])?["structuredContent"] as? [String: Any])
        #expect((found["processes"] as? [[String: Any]])?.compactMap { $0["pid"] as? Int } == [Int(daemon.pid)])
        #expect(found["argsUnreadable"] as? Int == 0)
        h.call(2, "find_processes", ["pid": 1, "argsContain": "x"])
        #expect((h.response(2)?["result"] as? [String: Any])?["isError"] as? Bool == true)
        h.call(3, "wait_for", ["condition": "process_exit", "pid": Int(daemon.pid), "argsContain": "x", "timeoutSeconds": 1])
        #expect((h.response(3)?["result"] as? [String: Any])?["isError"] as? Bool == true)
        h.call(4, "find_processes", ["name": "sleep", "argsContain": String(repeating: "a", count: 129)])
        #expect((h.response(4)?["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(!(h.line(1) ?? "").contains("7777.304"), "the filter is not echoed")
        h.close()
        #expect(h.finished.wait(timeout: .now() + 5) == .success)
        let log = (try? String(contentsOf: home.appendingPathComponent("activity.jsonl"), encoding: .utf8)) ?? ""
        #expect(log.contains("with args filter"))
        #expect(!log.contains("7777.304"), "the activity log records only that a filter was used")
    }
}

@Suite struct LoadAverageDiagnosisTests {
    func snapshot(load: Double, cores: Int = 10) -> Snapshot {
        var s = SystemSampler().measure(interval: 0.1)
        s.cpu.usagePercent = 60
        s.cpu.logicalCores = cores
        s.cpu.loadAverage1m = load
        s.cpu.loadAverage5m = load / 2
        s.cpu.loadAverage15m = load / 4
        s.memory.pressure = "normal"
        s.thermalState = "nominal"
        s.disk?.availableBytes = 500 << 30
        s.disk?.availableForImportantUsageBytes = 500 << 30
        s.battery = nil
        s.unavailable = nil
        return s
    }

    @Test func highLoadIsEvidenceEvenWithModerateCPU() {
        let calm = Diagnosis.make(purpose: "slowdown", snapshot: snapshot(load: 19.9), top: [])
        #expect(calm.status == "no_clear_issue")
        #expect(calm.loadAverage == [19.9, 9.95, 4.975])

        let busy = Diagnosis.make(purpose: "slowdown", snapshot: snapshot(load: 183), top: [])
        #expect(busy.status == "issue_detected")
        #expect(busy.evidence.first?.metric == "loadAverage")
        #expect(busy.evidence.first?.threshold == 20)
        #expect(busy.evidence.first?.detail.contains("18.3×") == true, "\(busy.evidence.first?.detail ?? "")")
        let heavy = Diagnosis.make(purpose: "heavy_work", snapshot: snapshot(load: 25), top: [])
        #expect(heavy.status == "issue_detected" && heavy.readiness == "caution")

        // The reported case: memory pressure warning plus load 180: load comes first, at most 4 items.
        var s = snapshot(load: 180)
        s.memory.pressure = "warning"
        s.cpu.usagePercent = 90
        s.disk?.availableForImportantUsageBytes = 5 << 30
        s.battery = .init(percent: 10, isCharging: false, powerSource: "Battery Power", minutesRemaining: nil)
        s.thermalState = "serious"
        let many = Diagnosis.make(purpose: "slowdown", snapshot: s, top: [])
        #expect(many.evidence.count == 4)
        #expect(many.evidence.contains { $0.metric == "loadAverage" })
        #expect(!many.evidence.contains { $0.metric == "memoryPressure" }, "the least severe item is dropped")
    }
}
