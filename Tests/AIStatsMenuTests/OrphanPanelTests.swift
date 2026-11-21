import Foundation
import os
@testable import StatsCore
import Testing
@testable import AIStatsMenu

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func row(endedAt: Date?, endedAfter: Date?) -> OrphanReport.Row {
    OrphanReport.Row(pid: 4321, startToken: "77", name: "node", memoryBytes: 1 << 20, cpuSeconds: 1, startedAt: Date(timeIntervalSince1970: 0),
                     session: "claude-code", endedAt: endedAt, endedAfter: endedAfter, agent: .init(pid: 99, startToken: "9"))
}

@Test func lineageRecorderReadsTheTableOnlyDuringActiveRecording() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let table = try #require(Proc.currentUserTable())
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let timeline = VirtualTimeline(t0)
    var reads: [Date] = []
    let me = getpid()
    var presence = ActivityStore.Presence(name: "test-agent", pid: 999_999, client: nil, connectedAt: t0, lastSeen: t0, startToken: "1")
    presence.agentPid = me
    presence.agentStartToken = Proc.usage(me).map { String($0.start) }
    var live = [presence]
    let probe = LineageRecorder.Probe(table: { reads.append(timeline.now()); return table }, token: { Proc.usage($0).map { String($0.start) } },
                                      name: { $0.comm }, now: { timeline.now() })
    let controller = LineageController(timeline: timeline, recorder: LineageRecorder(home: home, probe: probe), presences: { live }, closedPanel: false)
    func readsAfter(_ date: Date) -> Int { reads.filter { $0 > date }.count }

    controller.sessionsChanged()
    timeline.run(until: t0 + 10)
    #expect(reads.isEmpty, "ORP-042: Closed-Panel Recording is off without a stored setting")

    controller.update { $0.exposed = true }
    timeline.run(until: t0 + 20)
    #expect((10...11).contains(reads.count), "one read per second: \(reads.count)")
    #expect(zip(reads, reads.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 1 }, "ORP-041")

    controller.update { $0.exposed = false }
    let closed = timeline.now()
    timeline.run(until: t0 + 40)
    #expect(readsAfter(closed) == 0, "ORP-041: no read after the last Host closes")

    controller.update { $0.closedPanel = true }
    timeline.run(until: t0 + 50)
    #expect(readsAfter(t0 + 40) >= 9, "Closed-Panel Recording reads with both Hosts closed")
    controller.update { $0.closedPanel = false }
    let off = timeline.now()
    timeline.run(until: t0 + 60)
    #expect(readsAfter(off) == 0, "ORP-042: turning the setting off stops the reads")

    controller.update { $0.exposed = true }
    timeline.run(until: t0 + 65)
    live = []
    let ended = timeline.now()
    timeline.run(until: t0 + 160)
    #expect(readsAfter(ended + 50) > 0 && readsAfter(ended + 62) == 0, "ORP-041: the 60 s grace ends the reads")
    #expect(!controller.isRecording)
    #expect(OrphanReport.collect(home: home, presences: [], table: []).coverageGaps == 2, "three coverage intervals")
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("settings.json").path))
    controller.shutdown()
}

@Test func recorderObservesTwoSecondDescendantsWithAHostExposedAndWithBothHostsClosed() throws {
    for exposed in [true, false] {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let timeline = VirtualTimeline(t0)
        var seed: UInt64 = exposed ? 0x5eed : 0xc105ed
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let children = (0..<20).map { (pid: Int32(200 + $0), born: 5 + random() * 40) }
        let fixed = [Proc.Entry(pid: 100, ppid: 1, comm: "agent", startSec: 100, startUsec: 0),
                     Proc.Entry(pid: 101, ppid: 100, comm: "aistats", startSec: 101, startUsec: 0)]
        var reads: [Date] = []
        let probe = LineageRecorder.Probe(table: {
            let now = timeline.now()
            reads.append(now)
            let age = now.timeIntervalSince(t0)
            let live = children.filter { (0..<2).contains(age - $0.born) }
            // Each pass takes 0.4 s. The wait to the next read must absorb it.
            timeline.current += 0.4
            return fixed + live.map { Proc.Entry(pid: $0.pid, ppid: 100, comm: "child", startSec: 150 + Int($0.pid), startUsec: 0) }
        }, token: { pid in pid == 100 || pid == 101 ? "\(pid)000" : children.contains { $0.pid == pid } ? "\(150 + Int(pid))000" : nil },
           name: { $0.comm }, now: { timeline.now() })
        var presence = ActivityStore.Presence(name: "test-agent", pid: 101, client: nil, connectedAt: t0, lastSeen: t0, startToken: "101000")
        presence.agentPid = 100
        presence.agentStartToken = "100000"
        let controller = LineageController(timeline: timeline, recorder: LineageRecorder(home: home, probe: probe), presences: { [presence] },
                                           closedPanel: !exposed)
        controller.update { $0.exposed = exposed }
        timeline.run(until: t0 + 50)
        controller.shutdown()
        let intervals = zip(reads, reads.dropFirst()).map { $1.timeIntervalSince($0) }
        #expect(intervals.allSatisfy { abs($0 - 1) < 1e-6 }, "reads start 1 s apart: \(Set(intervals))")
        let text = try String(contentsOf: Lineage.directory(home: home).appendingPathComponent("v1.jsonl"), encoding: .utf8)
        let recorded = children.filter { text.contains("\"pid\":\($0.pid),") }.count
        #expect(recorded == 20, "ORP-004 \(exposed ? "Exposed" : "Closed") run: \(recorded) of 20")
    }
}

@Test func graceCountsFromTheLastSessionAlsoWithoutRecording() throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let timeline = VirtualTimeline(t0)
    var reads: [Date] = []
    let probe = LineageRecorder.Probe(table: { reads.append(timeline.now()); return [] }, token: { _ in nil }, name: { $0.comm },
                                      now: { timeline.now() })
    var presence = ActivityStore.Presence(name: "test-agent", pid: 999_999, client: nil, connectedAt: t0, lastSeen: t0, startToken: "1")
    presence.agentPid = 99
    presence.agentStartToken = "9"
    var live = [presence]
    let controller = LineageController(timeline: timeline, recorder: LineageRecorder(home: home, probe: probe), presences: { live }, closedPanel: false)
    controller.sessionsChanged()
    timeline.run(until: t0 + 3600)
    live = []
    controller.sessionsChanged()
    let ended = timeline.now()
    timeline.run(until: ended + 10)
    #expect(reads.isEmpty)
    controller.update { $0.exposed = true }
    timeline.run(until: ended + 120)
    #expect(reads.first.map { $0 <= ended + 11 } == true, "the grace starts when the last Session disappears, not at the last change before")
    #expect(reads.last.map { $0 < ended + 61 } == true, "and still ends 60 s later")
    controller.shutdown()
}

@Test @MainActor func confirmationDialogsRestoreFocusToTheInitiatingRow() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let candidate = row(endedAt: nil, endedAfter: Date())
    let consent = TerminationConsent(row: candidate)
    #expect(consent.focus == .orphan(4321, "77"))
    let model = AppModel(directory: directory)
    let host = PanelHost(id: "window", model: model, clock: AnimationClock(time: { 0 }), theme: Theme()) { _, _ in }
    host.open(on: nil)
    host.restoreFocus(consent.focus, presentation: host.presentation)
    host.attachExposedContent()
    defer { host.close() }
    #expect(host.appliedFocusRequest?.target == .orphan(4321, "77"), "ADR 0007: the request reaches the Host")

    var screen = ScreenSnapshot()
    var report = OrphanReport.collect(home: directory, presences: [], table: [])
    report.processes = [candidate]
    screen.orphans = report
    #expect(PanelFocus.restored(consent.focus, in: screen) == .orphan(4321, "77"), "the 종료… action of the same row")
    screen.orphans?.processes = []
    #expect(PanelFocus.restored(consent.focus, in: screen) == nil, "no focus target after the row is gone")
    let replacement = AppModel.AgentRow(state: .nameConflict(registered: "명령"), fingerprint: "0123456789ab")
    let replace = try #require(ReplacementConsent(target: .codex, row: replacement))
    screen.registrations[.codex] = replacement
    #expect(PanelFocus.restored(replace.focus, in: screen) == .action(.codex, "덮어쓰기…"))
}

@Test func terminationDialogShowsTheCapturedCandidateAndEndTime() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let known = TerminationConsent(row: row(endedAt: now - 720, endedAfter: nil), now: now).dialog
    #expect(known.destructiveLabel == "프로세스 종료", "ORP-037")
    #expect(known.title.contains("node"))
    let values = known.details.map { $0.label + $0.value }
    #expect(values == ["프로세스: node (PID 4321)", "세션: claude-code", "세션 종료: 12분 전"], "ORP-032: \(values)")
    #expect(known.message.contains("SIGTERM을 한 번") && known.note.contains("SIGKILL"))

    let unknown = TerminationConsent(row: row(endedAt: nil, endedAfter: now - 3 * 3600 - 300), now: now).dialog
    #expect(unknown.details.last?.value == "종료 시각을 알 수 없음 · 마지막 확인 후 3시간 5분 지남", "ORP-032")
    #expect(TerminationConsent.elapsed(59) == "59초" && TerminationConsent.elapsed(2 * 86400 + 3600) == "2일 1시간")
}

@Test func replacementDialogKeepsItsText() throws {
    let row = AppModel.AgentRow(state: .nameConflict(registered: "명령"), fingerprint: "0123456789ab")
    let dialog = try #require(ReplacementConsent(target: .codex, row: row)).dialog
    #expect(dialog.destructiveLabel == "덮어쓰기")
    #expect(dialog.details == [.init(label: "현재 항목: ", value: "명령"), .init(label: "항목 지문: ", value: "0123456789ab")])
    #expect(dialog.message == "이미 등록된 명령을 이 앱의 aistats로 덮어씁니다.")
}

@Test @MainActor func confirmedTerminationSignalsOnceAndShowsTheResult() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let signals = OSAllocatedUnfairLock(initialState: [Int32]())
    let system = OrphanTermination.System(owned: { _ in true }, token: { $0 == 4321 ? "77" : nil }, table: { [] }, liveAgents: { [] },
                                          signal: { pid, signal in signals.withLock { $0.append(signal) }; return pid == 4321 ? 0 : ESRCH },
                                          wait: { _ in })
    let model = AppModel(directory: directory, termination: system)
    let consent = TerminationConsent(row: row(endedAt: nil, endedAfter: Date()))
    consent.confirm(model)
    let deadline = ContinuousClock.now + .seconds(3)
    while model.screen.terminations.first?.message == "SIGTERM을 보내는 중…" || model.screen.terminations.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let result = try #require(model.screen.terminations.first)
    #expect(result.pid == 4321 && result.isError && result.message == "SIGTERM을 보냈지만 2초 뒤에도 실행 중입니다", "ORP-035")
    #expect(signals.withLock { $0 } == [SIGTERM], "ORP-036")
}
