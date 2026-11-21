import Foundation
import StatsCore
import SwiftUI

/// Runs the Lineage Recorder only during Active Recording (ADR 0009), on its own queue and 1 s interval.
/// All state lives on the timeline's queue.
final class LineageController: @unchecked Sendable {
    struct Inputs { var exposed = false; var closedPanel = false }

    private let timeline: StorageTimeline
    private let recorder: LineageRecorder
    private let presences: () -> [ActivityStore.Presence]
    private let drain: (() -> Void) -> Void
    /// Keeps the recorder's timer on time while recording, for example with both Hosts closed (ORP-004). Returns the release.
    private let keepTimely: () -> () -> Void
    private var inputs = Inputs()
    private var lastLiveAt: Date?
    private var hadLive = false
    private var cancel: (() -> Void)?
    private var release: (() -> Void)?

    init(timeline: StorageTimeline, recorder: LineageRecorder, presences: @escaping () -> [ActivityStore.Presence],
         closedPanel: Bool, drain: @escaping (() -> Void) -> Void = { $0() }, keepTimely: @escaping () -> () -> Void = { {} }) {
        self.timeline = timeline
        self.recorder = recorder
        self.presences = presences
        self.drain = drain
        self.keepTimely = keepTimely
        inputs.closedPanel = closedPanel
    }

    static func live(home: URL = AIStatsPaths.home, defaults: UserDefaults = .standard) -> LineageController {
        let timeline = DispatchTimeline(label: "aistats.lineage")
        let activity = ActivityStore(directory: home)
        return LineageController(timeline: timeline, recorder: LineageRecorder(home: home), presences: { activity.connectedAgents() },
                                 closedPanel: defaults.bool(forKey: Lineage.closedPanelKey), drain: timeline.sync, keepTimely: {
            // App Nap can delay the timers of an accessory app without a visible window.
            let token = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Lineage recording")
            return { ProcessInfo.processInfo.endActivity(token) }
        })
    }

    var isRecording: Bool { recorder.recording }

    func update(_ change: @escaping (inout Inputs) -> Void) {
        _ = timeline.after(0) { [self] in
            change(&inputs)
            evaluate()
        }
    }

    /// The app's presence poll saw a change.
    func sessionsChanged() { _ = timeline.after(0) { [self] in evaluate() } }

    /// Ends the coverage interval before the app quits.
    func shutdown() { drain { [self] in halt() } }

    /// The 60 s grace counts from the first presence read without a live Session, also when recording did not run.
    private func wanted(_ live: [ActivityStore.Presence]) -> Bool {
        let now = timeline.now()
        if !live.isEmpty || hadLive { lastLiveAt = now }
        hadLive = !live.isEmpty
        return Lineage.shouldRecord(exposed: inputs.exposed, closedPanel: inputs.closedPanel, liveSessions: live.count,
                                    lastLiveAt: lastLiveAt, now: now)
    }

    private func evaluate() {
        if wanted(presences()) {
            if cancel == nil { schedule(0) }
        } else {
            halt()
        }
    }

    private func schedule(_ delay: TimeInterval) {
        if release == nil { release = keepTimely() }
        cancel = timeline.after(delay) { [self] in tick() }
    }

    private func halt() {
        cancel?()
        cancel = nil
        recorder.stop()
        release?()
        release = nil
    }

    /// Reads start 1 s apart. The pass time, including a compaction, shortens the wait to the next read.
    private func tick() {
        cancel = nil
        let started = timeline.now()
        let live = presences()
        guard wanted(live) else { return halt() }
        if recorder.recording { recorder.tick(presences: live) } else { recorder.start(presences: live) }
        schedule(max(0, Lineage.interval - timeline.now().timeIntervalSince(started)))
    }
}

/// The termination consent of ADR 0009, captured at presentation.
struct TerminationConsent: Consent {
    let row: OrphanReport.Row
    let capturedAt: Date

    init(row: OrphanReport.Row, now: Date = Date()) {
        self.row = row
        capturedAt = now
    }

    var ended: String {
        if let at = row.endedAt { return "\(Self.elapsed(capturedAt.timeIntervalSince(at))) 전" }
        let after = row.endedAfter.map { Self.elapsed(capturedAt.timeIntervalSince($0)) } ?? "?"
        return "종료 시각을 알 수 없음 · 마지막 확인 후 \(after) 지남"
    }

    var dialog: DialogContent {
        DialogContent(title: "\(row.name) 프로세스를 종료할까요?",
                      message: "종료된 에이전트 세션이 남긴 프로세스입니다. 이 프로세스에만 SIGTERM을 한 번 보냅니다.",
                      details: [.init(label: "프로세스: ", value: "\(row.name) (PID \(row.pid))"), .init(label: "세션: ", value: row.session),
                                .init(label: "세션 종료: ", value: ended)],
                      note: "보내기 직전에 PID와 시작 토큰, 에이전트 종료를 다시 확인합니다. 하위 프로세스와 프로세스 그룹에는 보내지 않고, 강제 종료(SIGKILL)는 하지 않습니다.",
                      destructiveLabel: "프로세스 종료")
    }

    var focus: FocusTarget { .orphan(row.pid, row.startToken) }

    @MainActor func confirm(_ model: AppModel) { model.terminate(row) }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)초" }
        if s < 3600 { return "\(s / 60)분" }
        if s < 86400 { return "\(s / 3600)시간 \(s % 3600 / 60)분" }
        return "\(s / 86400)일 \(s % 86400 / 3600)시간"
    }
}

extension OrphanTermination.Outcome {
    var message: String {
        switch self {
        case .exited: return "종료됨"
        case .stillRunning: return "SIGTERM을 보냈지만 2초 뒤에도 실행 중입니다"
        case .refused("process_replaced"): return "PID가 다른 프로세스로 바뀌어 보내지 않았습니다"
        case .refused("agent_running"): return "에이전트가 실행 중이어서 보내지 않았습니다"
        case .refused("agent_ancestor"): return "실행 중인 에이전트 아래에 있어 보내지 않았습니다"
        case .refused("not_current_user"): return "현재 사용자의 프로세스가 아니어서 보내지 않았습니다"
        case .refused: return "다시 확인하지 못해 보내지 않았습니다"
        case .failed(let code): return "신호를 보내지 못했습니다: \(String(cString: strerror(code)))"
        }
    }
    var isError: Bool { self != .exited }
}

struct OrphanPanel: View {
    let report: OrphanReport
    let results: [AppModel.TerminationResult]
    let terminate: (OrphanReport.Row) -> Void
    @FocusState.Binding var focus: PanelFocus?
    @AppStorage(Lineage.closedPanelKey) private var closedPanel = false
    @State private var expanded = true

    var body: some View {
        DisclosureGroup("남은 프로세스", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: S.xxs) {
                Text(Self.coverage(report)).foregroundStyle(Ink.muted.color).fixedSize(horizontal: false, vertical: true)
                ForEach(report.processes, id: \.startToken) { row in
                    HStack(spacing: S.xs) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(row.name) · PID \(row.pid)").font(Theme.TypeRole.data.font).lineLimit(1)
                            Text("\(row.session) · \(Format.bytes(row.memoryBytes))").foregroundStyle(Ink.muted.color).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        let id = PanelFocus.orphan(row.pid, row.startToken)
                        Button("종료…") { terminate(row) }
                            .buttonStyle(PanelButtonStyle(kind: .secondary, focused: focus == id))
                            .focusable().focusEffectDisabled().focused($focus, equals: id)
                            .onKeyPress(keys: [.space, .return]) { _ in terminate(row); return .handled }
                            .accessibilityLabel("\(row.name) PID \(row.pid) 종료")
                    }
                }
                ForEach(results.indices, id: \.self) { i in
                    Text("\(results[i].name) (PID \(results[i].pid)): \(results[i].message)")
                        .foregroundStyle(results[i].isError ? Ink.amber.color : Ink.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                KeyToggle(title: "패널을 닫아도 계보 기록", isOn: $closedPanel)
            }.padding(.leading, 6)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Ink.text.color)
    }

    static func coverage(_ r: OrphanReport) -> String {
        guard r.reason == nil else { return "이 버전에서 읽을 수 없는 계보 기록 형식입니다." }
        guard let since = r.coverageSince else { return "계보 기록이 아직 없습니다. 에이전트 세션이 연결된 동안 기록합니다." }
        let f = DateFormatter()
        f.dateFormat = "M월 d일 HH:mm"
        let head = r.matched == 0 ? "남은 프로세스 없음" : "남은 프로세스 \(r.matched)개"
        return "\(head) · \(f.string(from: since)) 이후 기록 기준 · 기록 공백 \(r.coverageGaps)회"
    }
}
