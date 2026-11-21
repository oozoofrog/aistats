import Darwin
import Foundation
import Testing
@testable import StatsCore

private typealias Object = [String: Any]

/// A fixture process table with Start Tokens, a clock and a read counter for the Lineage Recorder.
private final class World {
    var entries: [Proc.Entry] = []
    var tokens: [Int32: String] = [:]
    var memory: [Int32: UInt64] = [:]
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var reads = 0
    var tokenReads = 0

    func add(_ pid: Int32, parent: Int32, _ comm: String, start: Int? = nil) {
        let sec = start ?? Int(pid)
        entries.removeAll { $0.pid == pid }
        entries.append(Proc.Entry(pid: pid, ppid: parent, comm: comm, startSec: sec, startUsec: 0))
        tokens[pid] = "\(sec)000"
    }

    func remove(_ pid: Int32) { entries.removeAll { $0.pid == pid }; tokens[pid] = nil }
    func token(_ pid: Int32) -> String { tokens[pid]! }
    func key(_ pid: Int32) -> LineageIdentity { .init(pid: pid, startToken: token(pid)) }
    func advance(_ seconds: TimeInterval = 1) { now = now.addingTimeInterval(seconds) }

    var probe: LineageRecorder.Probe {
        .init(table: { self.reads += 1; return self.entries }, token: { self.tokenReads += 1; return self.tokens[$0] }, name: { $0.comm },
              now: { self.now })
    }

    func usage(_ pid: Int32) -> Proc.Usage? {
        tokens[pid].map { Proc.Usage(start: UInt64($0)!, cpuNs: 1_500_000_000, footprint: memory[pid] ?? UInt64(pid) * 1000, lifetimeMaxFootprint: 0) }
    }

    func presence(_ name: String, server: Int32, agent: Int32) -> ActivityStore.Presence {
        var p = ActivityStore.Presence(name: name, pid: server, client: name, connectedAt: now, lastSeen: now, startToken: tokens[server])
        p.agentPid = agent
        p.agentStartToken = tokens[agent]
        return p
    }

    func report(_ home: URL, presences: [ActivityStore.Presence] = []) -> OrphanReport {
        OrphanReport.collect(home: home, presences: presences, table: entries, usage: usage, name: { $0.comm }, now: now)
    }
}

private func lines(_ home: URL) -> [Object] {
    let data = (try? Data(contentsOf: LineageStore(home: home).fileURL)) ?? Data()
    return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? Object }
}

private func write(_ home: URL, _ records: [any Encodable], raw: [String] = []) throws {
    let store = LineageStore(home: home)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var data = Data()
    for r in records { data.append(try JSONLinesFile.encoder.encode(r)); data.append(10) }
    for r in raw { data.append(Data(r.utf8)); data.append(10) }
    try data.write(to: store.fileURL)
    chmod(store.fileURL.path, 0o600)
}

/// Appends stale Descendant records of an exited agent until the store exceeds `bytes`.
private func pad(_ home: URL, past bytes: Int, pid: Int32, at: Date) throws {
    let store = LineageStore(home: home), agent = LineageIdentity(pid: 40, startToken: "gone")
    var total = store.size, batch: [Data] = [], i = 0
    while total <= bytes {
        let line = try JSONLinesFile.encoder.encode(descendant(pid, "stale-\(i)", agent: agent, at: at))
        total += line.count + 1
        batch.append(line)
        i += 1
    }
    try store.append(batch)
}

/// Denies or allows the creation of files in `directory` with an ACL entry. An append to an existing file still works.
private func denyCreate(_ directory: URL, _ deny: Bool) throws {
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = deny ? ["+a", "everyone deny add_file", directory.path] : ["-N", directory.path]
    try chmod.run()
    chmod.waitUntilExit()
    try #require(chmod.terminationStatus == 0)
}

private func json(_ value: some Encodable) throws -> Object {
    try #require(try JSONSerialization.jsonObject(with: MCPServer.encoder.encode(value)) as? Object)
}

private func descendant(_ pid: Int32, _ token: String, agent: LineageIdentity, name: String = "worker", at: Date) -> DescendantRecord {
    DescendantRecord(pid: pid, startToken: token, name: name, agentPid: agent.pid, agentStartToken: agent.startToken, session: "test-agent",
                     firstSeenAt: at, lastConfirmedAt: at)
}

private func session(_ agent: LineageIdentity, servers: [LineageIdentity] = [], at: Date, exited: Date? = nil) -> SessionRecord {
    SessionRecord(agentPid: agent.pid, agentStartToken: agent.startToken, servers: servers, name: "test-agent", firstSeenAt: at, lastLiveAt: at, exitedAt: exited)
}

private let reportKeys: Set<String> = ["observedAt", "coverageSince", "lastObservedAt", "coverageGaps", "evictedRecords", "unreadableRecords",
                                       "reason", "processes", "matched", "truncated", "processesOmitted"]
private let rowKeys: Set<String> = ["pid", "startToken", "name", "memoryBytes", "cpuSeconds", "startedAt", "session", "endedAt", "endedAfter", "evidence"]

// MARK: Recording

@Test func recorderWritesOneRecordPerDescendantWithOnlyTheSpecifiedFields() throws {
    let home = TestTemp.dir(), w = World()
    w.add(100, parent: 1, "agent"); w.add(101, parent: 100, "aistats"); w.add(102, parent: 100, "zsh"); w.add(103, parent: 102, "sleep")
    w.add(200, parent: 1, "Terminal"); w.add(201, parent: 200, "sleep")
    let recorder = LineageRecorder(home: home, probe: w.probe)
    let live = [w.presence("test-agent", server: 101, agent: 100)]
    #expect(recorder.start(presences: live))
    w.advance(); w.add(104, parent: 103, "child")
    recorder.tick(presences: live)
    w.advance()
    recorder.tick(presences: live)
    let records = lines(home).filter { $0["type"] as? String == "descendant" }
    #expect(records.map { $0["pid"] as? Int32 }.sorted { ($0 ?? 0) < ($1 ?? 0) } == [102, 103, 104], "ORP-001, ORP-010, ORP-013: \(records)")
    for r in records {
        #expect(Set(r.keys) == ["type", "pid", "startToken", "name", "agentPid", "agentStartToken", "session", "firstSeenAt", "lastConfirmedAt"], "ORP-002, ORP-043")
        #expect(r["agentPid"] as? Int32 == 100 && r["agentStartToken"] as? String == w.token(100) && r["session"] as? String == "test-agent")
    }
    #expect(records.first { $0["pid"] as? Int32 == 104 }?["name"] as? String == "child")
    let coverage = lines(home).filter { $0["type"] as? String == "coverage" }
    #expect(coverage.first?["event"] as? String == "start")
    let mode = try FileManager.default.attributesOfItem(atPath: LineageStore(home: home).directory.path)[.posixPermissions] as? Int
    #expect(mode == 0o700, "ORP-009")
}

@Test func sessionRecordKeepsEveryServerAndOnlyAgentExitEndsIt() throws {
    let home = TestTemp.dir(), w = World()
    w.add(100, parent: 1, "agent"); w.add(101, parent: 100, "aistats"); w.add(110, parent: 100, "worker")
    let recorder = LineageRecorder(home: home, probe: w.probe)
    #expect(recorder.start(presences: [w.presence("one", server: 101, agent: 100)]))
    w.advance(); w.remove(101); w.add(105, parent: 100, "aistats")
    recorder.tick(presences: [w.presence("one", server: 105, agent: 100)])
    w.advance(); w.add(106, parent: 100, "aistats")
    recorder.tick(presences: [w.presence("one", server: 105, agent: 100), w.presence("two", server: 106, agent: 100)])
    let last = try #require(lines(home).last { $0["type"] as? String == "session" })
    #expect((last["servers"] as? [Object])?.count == 3, "ORP-044: \(last)")
    #expect(last["exitedAt"] == nil, "the first server exit does not end the Session")
    #expect(LineageStore(home: home).read().state.sessions.count == 1)
    try LineageStore(home: home).compact(now: w.now) { w.tokens[$0.pid] == $0.startToken }
    let sessions = lines(home).filter { $0["type"] as? String == "session" }
    #expect(sessions.count == 1 && (sessions.first?["servers"] as? [Object])?.count == 3)
    #expect(lines(home).filter { $0["type"] as? String == "coverage" }.allSatisfy { $0["event"] as? String == "merged" })
}

@Test func endTimesFollowTheExitObservationOrLastLiveAt() throws {
    let home = TestTemp.dir(), w = World()
    w.add(100, parent: 1, "agent-a"); w.add(101, parent: 100, "aistats"); w.add(102, parent: 100, "zsh"); w.add(103, parent: 102, "sleep")
    let recorder = LineageRecorder(home: home, probe: w.probe)
    var live = [w.presence("a", server: 101, agent: 100)]
    #expect(recorder.start(presences: live))
    #expect(w.report(home).processes.isEmpty, "a live agent owns its Descendants")
    w.advance(); w.remove(101); w.remove(100); w.remove(102)
    w.entries = w.entries.map { var e = $0; if e.pid == 103 { e.ppid = 1 }; return e }
    live = []
    recorder.tick(presences: live)
    let exited = w.now
    let row = try #require(w.report(home).processes.first, "ORP-014: a candidate right after the agent exit")
    #expect(row.pid == 103 && row.endedAt == exited && row.endedAfter == nil, "ORP-048")
    #expect(row.cpuSeconds == 1.5 && row.memoryBytes == 103_000 && row.evidence == "lineage" && row.session == "a")

    w.add(300, parent: 1, "agent-b"); w.add(301, parent: 300, "aistats"); w.add(302, parent: 300, "server")
    w.advance()
    recorder.tick(presences: [w.presence("b", server: 301, agent: 300)])
    let stopped = w.now
    recorder.stop()
    w.advance(30); w.remove(300); w.remove(301)
    let report = w.report(home)
    let b = try #require(report.processes.first { $0.pid == 302 })
    #expect(b.endedAt == nil && b.endedAfter == stopped, "ORP-048: the app quit before the agent ended")
    #expect(LineageStore(home: home).read().state.sessions[.init(pid: 300, startToken: "300000")]?.lastLiveAt == stopped)
    #expect(report.lastObservedAt == stopped)
    for r in try #require(json(report)["processes"] as? [Object]) {
        #expect(Set(r.keys) == rowKeys, "ORP-022")
        #expect((r["endedAt"] is NSNull) != (r["endedAfter"] is NSNull), "exactly one end field")
    }
}

@Test func recorderObservesEachDescendantThatLivesTwoSeconds() throws {
    let home = TestTemp.dir(), w = World()
    w.add(100, parent: 1, "agent"); w.add(101, parent: 100, "aistats")
    let recorder = LineageRecorder(home: home, probe: w.probe)
    let live = [w.presence("test-agent", server: 101, agent: 100)]
    #expect(recorder.start(presences: live))
    var seed: UInt64 = 0x5eed
    func random() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53)
    }
    let children = (0..<20).map { (pid: Int32(200 + $0), born: random() * 40) }
    for second in 1...45 {
        w.advance()
        for child in children {
            let alive = (0..<2).contains(Double(second) - child.born)
            let listed = w.entries.contains { $0.pid == child.pid }
            if alive && !listed { w.add(child.pid, parent: 100, "child", start: 150 + Int(child.pid)) }
            if !alive && listed { w.remove(child.pid) }
        }
        recorder.tick(presences: live)
    }
    let recorded = Set(lines(home).filter { $0["type"] as? String == "descendant" }.compactMap { $0["pid"] as? Int32 })
    #expect(recorded == Set(children.map(\.pid)), "ORP-004: \(recorded.count) of 20")
}

@Test func sizeTriggeredCompactionKeepsTheSessionChangesOfItsPass() throws {
    let home = TestTemp.dir(), w = World()
    w.add(100, parent: 1, "agent-a"); w.add(101, parent: 100, "aistats")
    let recorder = LineageRecorder(home: home, probe: w.probe)
    let a = w.presence("a", server: 101, agent: 100)
    #expect(recorder.start(presences: [a]))
    try pad(home, past: Lineage.triggerBytes, pid: 50, at: w.now)
    w.advance(); w.add(300, parent: 1, "agent-b"); w.add(301, parent: 300, "aistats")
    let firstSeen = w.now
    recorder.tick(presences: [a, w.presence("b", server: 301, agent: 300)])
    #expect(LineageStore(home: home).size < Lineage.targetBytes, "the pass compacted before its append")
    w.advance(); w.remove(301); w.add(303, parent: 300, "worker")
    recorder.tick(presences: [a])
    w.advance(); w.remove(300)
    recorder.tick(presences: [a])
    let state = LineageStore(home: home).read().state
    let b = state.sessions[.init(pid: 300, startToken: "300000")]
    #expect(b?.exitedAt == w.now && b?.firstSeenAt == firstSeen, "ORP-048, ORP-044: \(String(describing: b))")
    #expect(state.descendants.values.first { $0.pid == 303 }?.session == "b")
}

@Test func failedCompactionWaitsForItsRetryAndSkipsTheAppend() throws {
    let home = TestTemp.dir(), w = World()
    w.add(50, parent: 1, "other"); w.add(100, parent: 1, "agent"); w.add(101, parent: 100, "aistats")
    let recorder = LineageRecorder(home: home, probe: w.probe)
    let live = [w.presence("a", server: 101, agent: 100)]
    #expect(recorder.start(presences: live))
    try pad(home, past: Lineage.triggerBytes, pid: 50, at: w.now)
    let store = LineageStore(home: home), padded = store.size
    try denyCreate(store.directory, true)
    defer { try? denyCreate(store.directory, false) }
    var attempts = 0
    func tick(_ child: Int32) {
        w.advance(); w.add(child, parent: 100, "worker")
        let before = w.tokenReads
        recorder.tick(presences: live)
        if w.tokenReads - before > 1000 { attempts += 1 }
    }
    for child in Int32(200)..<230 { tick(child) }
    #expect(attempts == 1, "one compaction attempt per retry wait: \(attempts)")
    #expect(store.size == padded, "ORP-008: no append past the size limit without a compaction")
    try denyCreate(store.directory, false)
    w.advance(Lineage.compactRetry)
    tick(230)
    #expect(attempts == 2 && store.size < Lineage.targetBytes)
    let recorded = Set(lines(home).filter { $0["type"] as? String == "descendant" }.compactMap { $0["pid"] as? Int32 })
    #expect(recorded == Set(Int32(200)...230), "the skipped passes are observed again: \(recorded.sorted())")

    let failing = TestTemp.dir(), v = World()
    v.add(100, parent: 1, "agent")
    let blocked = LineageRecorder(home: failing, probe: v.probe)
    try FileManager.default.createDirectory(at: blocked.store.fileURL, withIntermediateDirectories: true)
    for _ in 0..<30 { #expect(!blocked.start(presences: [])); v.advance() }
    #expect(v.reads == 1, "a failed start compaction waits before the next table read: \(v.reads)")
    try FileManager.default.removeItem(at: blocked.store.fileURL)
    v.advance(Lineage.compactRetry)
    #expect(blocked.start(presences: []) && v.reads == 2)
}

@Test func recordingReadsNoSecretsAndNeedsNoPrivileges() throws {
    let home = TestTemp.dir()
    let marker = "aistats-lineage-marker-\(UUID().uuidString.prefix(8))"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "/bin/sleep 60; : \(marker)", marker]
    process.environment = ["AISTATS_SECRET": marker, "PATH": "/usr/bin:/bin"]
    try process.run()
    defer { process.terminate(); process.waitUntilExit() }
    let me = getpid()
    let token = try #require(Proc.usage(me).map { String($0.start) })
    var presence = ActivityStore.Presence(name: "test-agent", pid: 999_999, client: nil, connectedAt: Date(), lastSeen: Date(), startToken: "1")
    presence.agentPid = me
    presence.agentStartToken = token
    let recorder = LineageRecorder(home: home)
    #expect(recorder.start(presences: [presence]), "ORP-006: a standard user records")
    defer { recorder.stop() }
    try #require(eventually(10) {
        recorder.tick(presences: [presence])
        return lines(home).contains { $0["name"] as? String == "sleep" } && lines(home).contains { $0["pid"] as? Int32 == process.processIdentifier }
    })
    let text = try String(contentsOf: LineageStore(home: home).fileURL, encoding: .utf8)
    #expect(!text.contains(marker) && !text.contains("/bin/") && !text.contains(home.path), "ORP-003")
    let names = try FileManager.default.contentsOfDirectory(atPath: LineageStore(home: home).directory.path)
    for name in names {
        let content = (try? String(contentsOf: LineageStore(home: home).directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        #expect(!content.contains(marker), "\(name)")
    }
}

@Test func detachedJobThatReparentsBeforeTheFirstObservationStaysUnreported() throws {
    let home = TestTemp.dir()
    let sleeper = try uniqueSleeper(in: TestTemp.dir())
    let launcher = try Child("/bin/sh", ["-c", "nohup '\(sleeper.path)' 60 >/dev/null 2>&1 &"])
    launcher.process.waitUntilExit()
    var job: Int32?
    try #require(eventually(10) {
        job = Proc.currentUserTable()?.first { $0.ppid == 1 && Proc.path($0.pid) == sleeper.path }?.pid
        return job != nil
    })
    defer { if let job { kill(job, SIGTERM) } }
    let me = getpid()
    var presence = ActivityStore.Presence(name: "test-agent", pid: 999_999, client: nil, connectedAt: Date(), lastSeen: Date(), startToken: "1")
    presence.agentPid = me
    presence.agentStartToken = Proc.usage(me).map { String($0.start) }
    let recorder = LineageRecorder(home: home)
    #expect(recorder.start(presences: [presence]))
    recorder.tick(presences: [presence])
    recorder.stop()
    #expect(!lines(home).contains { $0["pid"] as? Int32 == job }, "ORP-005 is not met: the job has no Lineage Record")
    #expect(!OrphanReport.collect(home: home, presences: []).processes.contains { $0.pid == job })
}

// MARK: Detection

@Test func reportUsesOnlyLineageEvidenceAndVerifiesIdentityAndAncestry() throws {
    let home = TestTemp.dir(), w = World()
    let t = w.now.addingTimeInterval(-600)
    let ended = LineageIdentity(pid: 400, startToken: "400000")
    w.add(500, parent: 1, "agent-b", start: 100)
    let liveB = w.key(500)
    w.add(300, parent: 1, "reused"); w.add(302, parent: 500, "zsh", start: 250); w.add(301, parent: 302, "under-b", start: 260)
    w.add(501, parent: 1, "nested-agent"); w.add(502, parent: 1, "aistats"); w.add(303, parent: 1, "orphan"); w.add(304, parent: 1, "unrelated")
    try write(home, [
        session(ended, servers: [w.key(502)], at: t), session(w.key(501), at: t),
        descendant(300, "1", agent: ended, at: t), descendant(301, w.token(301), agent: ended, at: t),
        descendant(501, w.token(501), agent: ended, at: t), descendant(502, w.token(502), agent: ended, at: t),
        descendant(303, w.token(303), agent: ended, at: t),
    ])
    let b = w.presence("b", server: 302, agent: 500)
    #expect(liveB == LineageIdentity(pid: b.agentPid!, startToken: b.agentStartToken!))
    let report = w.report(home, presences: [b])
    #expect(report.processes.map(\.pid) == [303], "ORP-010, ORP-011, ORP-012, ORP-013: \(report.processes.map(\.pid))")
    #expect(report.matched == 1 && !report.truncated)
}

@Test func reportNamesTheLiveProcessAfterAnExec() throws {
    let home = TestTemp.dir(), w = World()
    let ended = LineageIdentity(pid: 400, startToken: "400000")
    w.add(303, parent: 1, "java")
    try write(home, [session(ended, at: w.now), descendant(303, w.token(303), agent: ended, name: "bash", at: w.now)])
    #expect(w.report(home).processes.map(\.name) == ["java"], "the same name that find_processes returns")
}

@Test func reportFieldsCoverageAndVersionRules() throws {
    let empty = try json(OrphanReport.collect(home: TestTemp.dir(), presences: [], table: []))
    #expect(Set(empty.keys) == reportKeys, "ORP-021")
    for key in ["coverageSince", "lastObservedAt", "reason"] { #expect(empty[key] is NSNull, "\(key)") }
    #expect(empty["evictedRecords"] as? Int == 0 && empty["unreadableRecords"] as? Int == 0 && empty["coverageGaps"] as? Int == 0, "ORP-049")
    #expect((empty["processes"] as? [Any])?.isEmpty == true && empty["matched"] as? Int == 0 && empty["truncated"] as? Bool == false)

    let other = TestTemp.dir(), w = World()
    w.add(10, parent: 1, "orphan")
    try write(other, [])
    try FileManager.default.moveItem(at: LineageStore(home: other).fileURL, to: LineageStore(home: other).directory.appendingPathComponent("v2.jsonl"))
    let v2 = try json(OrphanReport.collect(home: other, presences: [], table: w.entries, usage: w.usage))
    #expect(v2["reason"] as? String == "lineage_version_unsupported" && (v2["processes"] as? [Any])?.isEmpty == true, "ORP-046")
    #expect(Set(v2.keys) == reportKeys)

    let home = TestTemp.dir(), t0 = w.now.addingTimeInterval(-3600)
    try write(home, [
        CoverageRecord(interval: "a", event: "start", at: t0), CoverageRecord(interval: "a", event: "heartbeat", at: t0 + 60),
        CoverageRecord(interval: "a", event: "stop", at: t0 + 90), CoverageRecord(interval: "b", event: "start", at: t0 + 200),
        CoverageRecord(interval: "b", event: "heartbeat", at: t0 + 260),
    ], raw: ["{not json"])
    let covered = OrphanReport.collect(home: home, presences: [], table: [])
    #expect(covered.coverageGaps == 1 && covered.coverageSince == t0 && covered.lastObservedAt == t0 + 260, "ORP-047")
    #expect(covered.unreadableRecords == 1, "ORP-046")
    #expect(covered.summaryLine.hasPrefix("No orphan candidates since "))
}

@Test func reportListsFifteenRowsByMemoryAndFitsTheResponseBudget() throws {
    let home = TestTemp.dir(), w = World()
    let agent = LineageIdentity(pid: 90, startToken: "90000")
    let name = String(repeating: "n", count: 255)
    var records: [any Encodable] = [session(agent, at: w.now)]
    for i in 0..<20 {
        let pid = Int32(1000 + i)
        w.add(pid, parent: 1, name)
        w.memory[pid] = UInt64(i + 1) * 1_000_000
        records.append(descendant(pid, w.token(pid), agent: agent, name: name, at: w.now))
    }
    try write(home, records)
    let report = w.report(home)
    #expect(report.processes.count == 15 && report.matched == 20 && report.truncated, "ORP-024")
    #expect(report.processes.map(\.memoryBytes) == report.processes.map(\.memoryBytes).sorted(by: >))
    #expect(report.processes.first?.pid == 1019)
    let h = MCPHarness()
    defer { h.close() }
    let line = MCPServer.line(try h.server.orphanResponse(report, id: 1), toolCall: true)
    #expect(line.count <= 9216)
    let result = try #require((try JSONSerialization.jsonObject(with: line) as? Object)?["result"] as? Object)
    #expect(result["isError"] as? Bool == false)
    let content = try #require(result["structuredContent"] as? Object)
    #expect(try JSONSerialization.data(withJSONObject: content).count <= MCPServer.maxResponseBytes, "ORP-025")
    let shown = (content["processes"] as? [Object])?.count ?? 0
    #expect(shown > 0 && shown + (content["processesOmitted"] as? Int ?? -1) == 15 && content["matched"] as? Int == 20, "RSZ-007")
}

@Test func reportCallsReturnQuickly() throws {
    let home = TestTemp.dir()
    let agent = LineageIdentity(pid: 90, startToken: "1")
    let now = Date()
    try write(home, [session(agent, at: now)] + (0..<500).map { descendant(Int32(50_000 + $0), "1", agent: agent, at: now) as any Encodable })
    for _ in 0..<20 {
        let start = Date()
        _ = OrphanReport.collect(home: home)
        #expect(Date().timeIntervalSince(start) < 0.3, "ORP-023")
    }
}

// MARK: Storage

@Test func compactionFollowsTheRetentionOrderAndCountsEvictions() throws {
    let home = TestTemp.dir(), now = Date(timeIntervalSince1970: 1_800_000_000)
    let deadAgent = LineageIdentity(pid: 7, startToken: "dead"), oldAgent = LineageIdentity(pid: 8, startToken: "gone")
    var live: Set<LineageIdentity> = []
    var records: [any Encodable] = [session(deadAgent, at: now - 86400), session(oldAgent, at: now - 86400 * 9)]
    for i in 0..<50 { records.append(descendant(Int32(100 + i), "x", agent: deadAgent, at: now - 3600)) }
    let eightDays = descendant(99, "old", agent: deadAgent, at: now - 8 * 86400)
    records.append(eightDays)
    live.insert(eightDays.key)
    for i in 0..<10_000 {
        let r = descendant(Int32(10_000 + i), "t\(i)", agent: deadAgent, name: String(repeating: "w", count: 40), at: now - Double(10_000 - i))
        records.append(r)
        live.insert(r.key)
    }
    for i in 0..<10 { records.append(CoverageRecord(interval: "old\(i)", event: "merged", start: now - 9 * 86400, end: now - 8 * 86400 - Double(i))) }
    for i in 0..<2100 {
        records.append(CoverageRecord(interval: "i\(i)", event: "start", at: now - 86400 + Double(i * 30)))
        records.append(CoverageRecord(interval: "i\(i)", event: "heartbeat", at: now - 86400 + Double(i * 30 + 10)))
    }
    try write(home, records)
    let store = LineageStore(home: home)
    #expect(store.size > Lineage.triggerBytes, "the fixture needs size eviction")
    let state = try store.compact(now: now) { live.contains($0) }
    #expect(store.size <= Lineage.targetBytes, "ORP-008")
    #expect(state.descendants[eightDays.key] != nil, "a live record first seen 8 days earlier stays")
    #expect(state.descendants.keys.allSatisfy { live.contains($0) }, "exited Descendant records go first")
    #expect(state.sessions[deadAgent] != nil && state.sessions[oldAgent] == nil, "only unreferenced exited Sessions go")
    let coverage = lines(home).filter { $0["type"] as? String == "coverage" }
    #expect(coverage.count == 2000 && Set(coverage.compactMap { $0["interval"] as? String }).count == 2000, "one line per interval, at most 2,000")
    #expect(!coverage.contains { ($0["interval"] as? String)?.hasPrefix("old") == true } && !coverage.contains { $0["interval"] as? String == "i0" })
    let removed = live.subtracting(state.descendants.keys)
    #expect(!removed.isEmpty)
    let newestKept = state.descendants.values.filter { $0.key != eightDays.key }.map(\.firstSeenAt).max()!
    let seen = Dictionary(records.compactMap { $0 as? DescendantRecord }.map { ($0.key, $0.firstSeenAt) }, uniquingKeysWith: { a, _ in a })
    let oldestRemoved = removed.compactMap { seen[$0] }.min()!
    #expect(newestKept <= oldestRemoved, "size eviction removes the newest first-seen records first")
    #expect(state.compactions.map(\.evicted) == [removed.count])
    #expect(OrphanReport.collect(home: home, presences: [], table: []).evictedRecords == removed.count, "ORP-049: a separate reader")
    for url in [store.fileURL] {
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600, "ORP-045")
    }
    try store.compact(now: now + 8 * 86400) { live.contains($0) }
    #expect(OrphanReport.collect(home: home, presences: [], table: []).evictedRecords == 0, "ORP-049 after 7 days")
}

@Test func readersNeverWriteAndOnlyOneWriterRecords() throws {
    let home = TestTemp.dir()
    let child = try Child("/bin/sleep", ["60"])
    defer { child.kill() }
    try #require(eventually(5) { Proc.usage(child.pid) != nil })
    let token = String(Proc.usage(child.pid)!.start)
    let agent = LineageIdentity(pid: getpid(), startToken: "1")
    try write(home, [session(agent, at: Date()), descendant(child.pid, token, agent: agent, name: "sleep", at: Date()),
                     CoverageRecord(interval: "a", event: "start", at: Date())])
    let store = LineageStore(home: home)
    func snapshot() throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: store.directory.path) {
            let path = store.directory.appendingPathComponent(name).path
            var st = stat()
            lstat(path, &st)
            out[name] = "\(st.st_mode) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) \((try? Data(contentsOf: URL(fileURLWithPath: path)))?.hashValue ?? 0)"
        }
        return out
    }
    let before = try snapshot()
    let direct = OrphanReport.collect(home: home, presences: [])
    #expect(direct.processes.map(\.pid) == [child.pid])
    let h = MCPHarness(home: home)
    h.call(1, "get_orphan_processes")
    let body = try #require((h.response(1)?["result"] as? Object)?["structuredContent"] as? Object)
    h.close()
    #expect((body["processes"] as? [Object])?.first?["pid"] as? Int32 == child.pid)
    let cli = try runCLI(["orphans", "--json"], home: home), text = try runCLI(["orphans"], home: home)
    #expect(cli.status == 0 && text.status == 0, "ORP-029")
    #expect(try snapshot() == before, "ORP-040: report paths leave the store unchanged")
    #expect(Proc.usage(child.pid).map { String($0.start) } == token, "ORP-027: the candidate still runs")

    #expect(store.claimWriter())
    let second = LineageRecorder(home: home)
    #expect(!second.start(presences: []), "a second writer does not record")
    #expect(try snapshot().filter { $0.key != ".writer.lock" } == before)
}

@Test func reportsStayReadableDuringRepeatedCompactions() throws {
    let home = TestTemp.dir(), now = Date()
    let agent = LineageIdentity(pid: 90, startToken: "1")
    try write(home, [session(agent, at: now)] + (0..<300).map { descendant(Int32(20_000 + $0), "1", agent: agent, at: now) as any Encodable }
              + [CoverageRecord(interval: "a", event: "start", at: now)])
    let store = LineageStore(home: home)
    let done = DispatchSemaphore(value: 0)
    let counts = Counts()
    DispatchQueue.global().async {
        for _ in 0..<100 { counts.add(OrphanReport.collect(home: home, presences: [], table: []).unreadableRecords) }
        done.signal()
    }
    for i in 0..<40 {
        try store.append([try JSONLinesFile.encoder.encode(CoverageRecord(interval: "a", event: "heartbeat", at: now + Double(i)))])
        try store.compact(now: now + Double(i)) { _ in true }
        #expect(try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int == 0o600)
    }
    done.wait()
    let all = counts.all
    #expect(all.count == 100 && all.allSatisfy { $0 == 0 }, "ORP-045")
}

private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ n: Int) { lock.withLock { values.append(n) } }
    var all: [Int] { lock.withLock { values } }
}

// MARK: Surface

@Test func orphanToolIsReadOnlyAndTakesNoArguments() throws {
    let h = MCPHarness()
    defer { h.close() }
    h.initialize()
    h.send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
    let tools = try #require((h.response(1)?["result"] as? Object)?["tools"] as? [Object])
    let tool = try #require(tools.first { $0["name"] as? String == "get_orphan_processes" })
    #expect(tool["annotations"] as? [String: Bool] == ["readOnlyHint": true, "openWorldHint": false], "ORP-020")
    #expect((tool["description"] as? String)?.contains("An empty list covers only the time since coverageSince") == true, "ORP-026")
    #expect(((tool["inputSchema"] as? Object)?["properties"] as? Object)?.isEmpty == true, "ORP-027: no action argument")
    h.call(2, "get_orphan_processes", ["signal": "TERM"])
    #expect((h.response(2)?["result"] as? Object)?["isError"] as? Bool == true)
    h.call(3, "get_orphan_processes")
    let body = try #require((h.response(3)?["result"] as? Object)?["structuredContent"] as? Object)
    #expect(Set(body.keys) == reportKeys && body["reason"] is NSNull && body["coverageSince"] is NSNull, "ORP-021 over stdio")
}

@Test func orphansCommandPrintsTheToolObject() throws {
    let home = TestTemp.dir()
    let empty = try runCLI(["orphans", "--json"], home: home)
    #expect(empty.status == 0, "ORP-029: \(empty.err)")
    let printed = try #require(try JSONSerialization.jsonObject(with: Data(empty.out.utf8)) as? Object)
    #expect(Set(printed.keys) == reportKeys, "ORP-028")
    let text = try runCLI(["orphans"], home: home)
    #expect(text.status == 0 && text.out.hasPrefix("No lineage recorded yet."))
    for bad in [["orphans", "--bogus"], ["orphans", "--kill"], ["orphans", "extra"]] {
        let r = try runCLI(bad, home: home)
        #expect(r.status == 1 && r.out.isEmpty && r.err.hasPrefix("aistats: "), "\(bad)")
    }
    let child = try Child("/bin/sleep", ["60"])
    defer { child.kill() }
    try #require(eventually(5) { Proc.usage(child.pid) != nil })
    let agent = LineageIdentity(pid: getpid(), startToken: "1")
    try write(home, [session(agent, at: Date()), descendant(child.pid, String(Proc.usage(child.pid)!.start), agent: agent, name: "sleep", at: Date()),
                     CoverageRecord(interval: "a", event: "start", at: Date())])
    let one = try runCLI(["orphans", "--json"], home: home)
    #expect(one.status == 0)
    let row = try #require(((try JSONSerialization.jsonObject(with: Data(one.out.utf8)) as? Object)?["processes"] as? [Object])?.first)
    #expect(Set(row.keys) == rowKeys && row["pid"] as? Int32 == child.pid && row["endedAt"] is NSNull && row["endedAfter"] is String)
    let lines = try runCLI(["orphans"], home: home).out.split(separator: "\n")
    let since = ISO8601DateFormatter().string(from: try #require(OrphanReport.collect(home: home).coverageSince))
    #expect(lines.first.map(String.init) == "1 orphan candidate since \(since).", "\(lines)")
    #expect(lines.contains { $0.hasPrefix("\(child.pid) ") && $0.hasSuffix("sleep") })
}

// MARK: Termination

@Test func terminationReverifiesAndSendsOneSigtermToThePidAlone() throws {
    var signals: [(Int32, Int32)] = []
    var tokens: [Int32: String] = [50: "5", 60: "6"]
    func system(agents: Set<LineageIdentity> = [], table: [Proc.Entry]? = [Proc.Entry(pid: 50, ppid: 1, comm: "w", startSec: 5, startUsec: 0)]) -> OrphanTermination.System {
        .init(owned: { _ in true }, token: { tokens[$0] }, table: { table }, liveAgents: { agents },
              signal: { signals.append(($0, $1)); return 0 }, wait: { _ in tokens[50] = nil })
    }
    let agent = LineageIdentity(pid: 60, startToken: "old")
    tokens[50] = "replaced"
    #expect(OrphanTermination.run(pid: 50, startToken: "5", agent: agent, system: system()) == .refused("process_replaced"), "ORP-033")
    #expect(signals.isEmpty)
    tokens[50] = "5"
    #expect(OrphanTermination.run(pid: 50, startToken: "5", agent: .init(pid: 60, startToken: "6"), system: system()) == .refused("agent_running"))
    let under = [Proc.Entry(pid: 50, ppid: 70, comm: "w", startSec: 5, startUsec: 0), Proc.Entry(pid: 70, ppid: 1, comm: "a", startSec: 1, startUsec: 0)]
    #expect(OrphanTermination.run(pid: 50, startToken: "5", agent: agent, system: system(agents: [.init(pid: 70, startToken: "7")], table: under)) == .refused("agent_ancestor"))
    #expect(signals.isEmpty)
    #expect(OrphanTermination.run(pid: 50, startToken: "5", agent: agent, system: system()) == .exited)
    #expect(signals.count == 1 && signals[0] == (50, SIGTERM), "ORP-034, ORP-036")
}

@Test func signalResistantCandidateGetsOneSigtermAndStaysRunning() throws {
    let home = TestTemp.dir()
    let stubborn = try Child("/bin/sh", ["-c", "trap '' TERM; while :; do /bin/sleep 0.2; done"])
    let parent = try Child("/bin/sh", ["-c", "/bin/sleep 60 & wait"])
    var grandchild: Int32?
    defer {
        kill(stubborn.pid, SIGKILL)
        if let grandchild { kill(grandchild, SIGTERM) }
        stubborn.kill(); parent.kill()
    }
    try #require(eventually(10) {
        grandchild = Proc.currentUserTable()?.first { $0.ppid == parent.pid && $0.comm == "sleep" }?.pid
        return grandchild != nil && Proc.usage(stubborn.pid) != nil
    })
    let agent = LineageIdentity(pid: getpid(), startToken: "1")
    var sent: [(Int32, Int32)] = []
    var system = OrphanTermination.System.live(home: home)
    let live = system.signal
    system.signal = { sent.append(($0, $1)); return live($0, $1) }
    let token = String(Proc.usage(stubborn.pid)!.start)
    #expect(OrphanTermination.run(pid: stubborn.pid, startToken: token, agent: agent, system: system) == .stillRunning, "ORP-035")
    #expect(sent.count == 1 && sent[0] == (stubborn.pid, SIGTERM), "ORP-036: one SIGTERM, no SIGKILL")
    #expect(Proc.usage(stubborn.pid).map { String($0.start) } == token)

    let childToken = String(Proc.usage(grandchild!)!.start)
    let parentToken = String(Proc.usage(parent.pid)!.start)
    #expect(OrphanTermination.run(pid: parent.pid, startToken: parentToken, agent: agent, system: system) == .exited)
    #expect(Proc.usage(grandchild!).map { String($0.start) } == childToken, "ORP-034: the child still runs")
}

private func aistatsBinary() throws -> String {
    let path = Bundle(for: MCPHarness.self).bundleURL.deletingLastPathComponent().appendingPathComponent("aistats").path
    try #require(FileManager.default.isExecutableFile(atPath: path), "build the aistats product next to the test bundle")
    return path
}

private func runCLI(_ arguments: [String], home: URL) throws -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try aistatsBinary())
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["AISTATS_HOME"] = home.path
    process.environment = environment
    let output = Pipe(), errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let out = output.fileHandleForReading.readDataToEndOfFile(), err = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
}
