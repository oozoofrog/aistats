import AppKit
import Combine
import StatsCore

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let refreshInterval: TimeInterval = 2
    /// Battery and disk change slowly and cost the most to read (IOKit, volume queries).
    nonisolated static let slowMetricsInterval: TimeInterval = 30
    /// Re-check connected agents at least this often even when no file changed (an agent may have died).
    nonisolated static let agentRecheckInterval: TimeInterval = 30
    /// Points shown in the CPU sparkline (2 minutes at the refresh interval).
    nonisolated static let sparklineLength = 60
    nonisolated static let visibleCallLimit = 6

    /// Published only while a panel is on screen, so a closed panel causes no SwiftUI work.
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var topProcesses: [ProcessUsage] = []
    @Published private(set) var menuTitle = "AIStats"
    @Published private(set) var agents: [ActivityStore.Presence] = []
    @Published private(set) var recentCalls: [ActivityStore.Call] = []
    /// Set when history can't be written, so agents' get_stats_history would be stale.
    @Published private(set) var recordingError: String?
    @Published private(set) var registrations: [AgentTarget: AgentRow] = [:]

    struct AgentRow: Equatable {
        var state: RegistrationState?
        /// The agent CLI used to check or change the entry.
        var cliPath: String?
        /// Fingerprint of the existing entry; a confirmed replace names it.
        var fingerprint: String?
        var busy = false
        var message: String?
        var messageIsError = false
    }

    private let sampler = SystemSampler(slowMetricsInterval: AppModel.slowMetricsInterval)
    private let history = HistoryStore()
    private let activity = ActivityStore()
    private let samplerQueue = DispatchQueue(label: "aistats.sampler", qos: .utility)
    private let storeQueue = DispatchQueue(label: "aistats.store", qos: .utility)
    private let registrationQueue = DispatchQueue(label: "aistats.registration", qos: .userInitiated, attributes: .concurrent)
    private let activityPoll = ActivityPoll()
    private var timer: Timer?
    private var latest: Snapshot?
    private var latestHistory: [Double] = []
    /// Process sampling walks every pid, so it only runs while the panel is on screen.
    private var visiblePanels = Set<String>()
    private lazy var registrar = AgentRegistrar(binaryPath: cliPath)

    var panelVisible: Bool { !visiblePanels.isEmpty }

    func setPanel(_ id: String, visible: Bool) {
        let wasVisible = panelVisible
        if visible { visiblePanels.insert(id) } else { visiblePanels.remove(id) }
        if !panelVisible {
            topProcesses = []
        } else {
            if !wasVisible {
                snapshot = latest
                cpuHistory = latestHistory
                refreshRegistrations()
            }
            refresh()
        }
    }

    init() {
        // Continue the sparkline from what an earlier run recorded.
        storeQueue.async { [weak self, history] in
            let recent = history.points(since: Date().addingTimeInterval(-Self.refreshInterval * Double(Self.sparklineLength)))
            DispatchQueue.main.async {
                guard let self, self.latestHistory.isEmpty else { return }
                self.latestHistory = recent.compactMap(\.cpuPercent)
                if self.panelVisible { self.cpuHistory = self.latestHistory }
            }
        }
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let wantProcesses = panelVisible
        samplerQueue.async { [weak self, sampler] in
            var snapshot = sampler.sample(includeProcesses: wantProcesses)
            let top = wantProcesses && sampler.processCPUIsFresh
                ? sampler.topProcesses(sortedBy: .cpu, limit: 3, from: snapshot.topProcesses ?? []) : []
            snapshot.topProcesses = nil
            DispatchQueue.main.async { self?.apply(snapshot: snapshot, top: top) }
        }
        storeQueue.async { [weak self, activity, activityPoll] in
            // Reading and decoding the activity log every tick was a large share of idle CPU;
            // only do it when the log or the agents folder changed.
            guard activityPoll.due(token: activity.changeToken(), recheck: Self.agentRecheckInterval) else { return }
            let agents = activity.connectedAgents()
            let calls = activity.recentCalls(limit: Self.visibleCallLimit)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.agents != agents { self.agents = agents }
                let reversed = Array(calls.reversed())
                if self.recentCalls != reversed { self.recentCalls = reversed }
            }
        }
    }

    private func apply(snapshot: Snapshot, top: [ProcessUsage]) {
        // The first reading only primes the rate counters; skip it so nothing shows a fake 0%.
        guard snapshot.sampleIntervalSeconds > 0 else { return }
        latest = snapshot
        if snapshot.isAvailable("cpu") {
            latestHistory.append(snapshot.cpu.usagePercent)
            if latestHistory.count > Self.sparklineLength { latestHistory.removeFirst(latestHistory.count - Self.sparklineLength) }
        }
        let title = Self.title(for: snapshot)
        if title != menuTitle { menuTitle = title }
        if panelVisible {
            self.snapshot = snapshot
            cpuHistory = latestHistory
            if !top.isEmpty { topProcesses = top }
        }

        let point = HistoryPoint(snapshot: snapshot)
        storeQueue.async { [weak self, history] in
            var message: String?
            do { try history.record(point) } catch { message = "\(error)" }
            DispatchQueue.main.async { [message] in
                if self?.recordingError != message { self?.recordingError = message }
            }
        }
    }

    // MARK: Menu bar

    /// A metric that couldn't be read shows "—", never 0%.
    nonisolated static func title(for s: Snapshot) -> String {
        let cpu = s.isAvailable("cpu") ? "\(Int(s.cpu.usagePercent.rounded()))%" : "—"
        let mem = s.isAvailable("memory") ? "\(Int(s.memory.usedPercent.rounded()))%" : "—"
        return "CPU \(cpu)  MEM \(mem)"
    }

    /// True for a few seconds after an agent called a tool, so the menu bar can show it.
    var agentActiveRecently: Bool {
        guard let last = recentCalls.first else { return false }
        return Date().timeIntervalSince(last.date) < 6
    }

    var cliPath: String {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return dir.appendingPathComponent("aistats").path
    }

    // MARK: Agent registration

    func refreshRegistrations() {
        for t in AgentTarget.allCases where registrations[t]?.busy != true {
            var row = registrations[t] ?? AgentRow()
            row.busy = true
            registrations[t] = row
            registrationQueue.async { [weak self, registrar] in
                let status = registrar.status(t)
                DispatchQueue.main.async {
                    guard let self else { return }
                    var row = self.registrations[t] ?? AgentRow()
                    row.state = status.state
                    row.cliPath = status.cliPath
                    row.fingerprint = status.entryFingerprint
                    row.busy = false
                    self.registrations[t] = row
                }
            }
        }
    }

    enum Action: Equatable {
        case connect, disconnect
        /// Overwrite another server named aistats; `fingerprint` names the entry the user confirmed.
        case replace(fingerprint: String)
    }

    /// Asks before overwriting an `aistats` entry that isn't ours; replaces it only on confirmation.
    func confirmReplace(_ target: AgentTarget) {
        guard case .nameConflict(let existing)? = registrations[target]?.state,
              let fingerprint = registrations[target]?.fingerprint else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(target.displayName)의 aistats 항목을 바꿀까요?"
        alert.informativeText = """
        이미 등록된 명령을 이 앱의 aistats로 덮어씁니다.
        현재 항목: \(existing)
        항목 지문: \(fingerprint)
        그사이 항목이 바뀌면 덮어쓰지 않습니다. 바꾸기 전 설정 파일은 AIStats 데이터 폴더(backups)에 백업합니다.
        """
        alert.addButton(withTitle: "덮어쓰기")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(.replace(fingerprint: fingerprint), target)
    }

    func perform(_ action: Action, _ target: AgentTarget) {
        guard registrations[target]?.busy != true else { return }
        var row = registrations[target] ?? AgentRow()
        row.busy = true
        row.message = nil
        registrations[target] = row
        registrationQueue.async { [weak self, registrar] in
            let outcome: RegistrationOutcome
            switch action {
            case .connect: outcome = registrar.install(target)
            case .disconnect: outcome = registrar.uninstall(target)
            case .replace(let fingerprint): outcome = registrar.install(target, replacing: fingerprint)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var row = self.registrations[target] ?? AgentRow()
                row.busy = false
                row.state = outcome.status.state
                row.cliPath = outcome.status.cliPath
                row.fingerprint = outcome.status.entryFingerprint
                row.messageIsError = !outcome.ok
                row.message = Self.message(for: outcome)
                self.registrations[target] = row
            }
        }
    }

    nonisolated static func message(for o: RegistrationOutcome) -> String {
        guard o.ok else {
            // Once a change was attempted (a backup exists), the registrar's own words say what the entry is
            // now; a summary like "left unchanged" could be wrong.
            if let backup = o.backup {
                let note = o.message.contains(backup) ? "" : " · 백업: \((backup as NSString).abbreviatingWithTildeInPath)"
                return "실패: \(o.message)\(note)"
            }
            switch o.status.state {
            case .agentNotFound: return "\(o.target.displayName)을(를) 찾지 못했습니다"
            case .nameConflict: return "다른 aistats 항목이 있어 바꾸지 않았습니다"
            default: return "실패: \(o.message)"
            }
        }
        let backup = o.backup.map { " · 백업: \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        switch o.action {
        case "replaced":
            return "덮어씀\(backup) · " + (o.target == .claudeDesktop ? "Claude Desktop을 다시 시작하세요" : "에이전트에서 새 세션을 시작하세요")
        case "registered", "updated", "already_registered":
            return o.target == .claudeDesktop ? "등록됨 · Claude Desktop을 다시 시작하세요" : "등록됨 · 에이전트에서 새 세션을 시작하세요"
        case "removed", "not_registered":
            return o.target == .claudeDesktop ? "연결 해제됨 · Claude Desktop을 다시 시작하세요" : "연결 해제됨"
        default:
            return o.message
        }
    }

    /// Which agent target a connected session belongs to (from its handshake name), if any.
    nonisolated static func target(of p: ActivityStore.Presence) -> AgentTarget? {
        let c = (p.client ?? p.name).lowercased()
        if c.contains("claude-code") || c == "claude code" { return .claudeCode }
        if c.contains("codex") { return .codex }
        if c.contains("gemini") { return .gemini }
        if c.contains("claude-ai") || c.contains("claude desktop") { return .claudeDesktop }
        if c.contains("cursor") { return .cursor }
        return nil
    }

    /// Running sessions of this agent talking to AIStats right now (handshake records).
    func sessionCount(_ target: AgentTarget) -> Int {
        agents.filter { Self.target(of: $0) == target }.count
    }

    /// Sessions of clients that aren't one of the five agents, grouped by client name.
    var otherClients: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in agents where Self.target(of: p) == nil { counts[p.client ?? p.name, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }
}

/// Remembers the last activity change token; confined to the store queue.
private final class ActivityPoll: @unchecked Sendable {
    private var token: String?
    private var lastRead = Date.distantPast

    func due(token new: String, recheck: TimeInterval) -> Bool {
        let now = Date()
        guard new != token || now.timeIntervalSince(lastRead) >= recheck else { return false }
        token = new
        lastRead = now
        return true
    }
}
