import AppKit
import Combine
import UserNotifications
import StatsCore

struct CPUPoint: Equatable, Sendable {
    let id: UInt64
    let value: Double
}

struct ScreenSnapshot {
    var revision: UInt64 = 0
    var sample: Snapshot?
    var cpuHistory: [CPUPoint] = []
    var topProcesses: [ProcessUsage] = []
    var tree: ProcessTree?
    var orphans: OrphanReport?
    var terminations: [AppModel.TerminationResult] = []
    var agents: [ActivityStore.Presence] = []
    var recentCalls: [ActivityStore.Call] = []
    var recordingError: String?
    var quietEvent: TimeInterval?
    var warningGeneration: UInt64 = 0
    var registrations: [AgentTarget: AppModel.AgentRow] = [:]

    func sessionCount(_ target: AgentTarget) -> Int {
        agents.filter { AppModel.target(of: $0) == target }.count
    }

    var otherClients: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in agents where AppModel.target(of: p) == nil { counts[p.client ?? p.name, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }
}

@MainActor
final class AppModel {
    nonisolated static let refreshInterval: TimeInterval = 2
    nonisolated static let slowMetricsInterval: TimeInterval = 30
    nonisolated static let agentRecheckInterval: TimeInterval = 30
    nonisolated static let sparklineLength = 60
    nonisolated static let visibleCallLimit = 6

    private(set) var screen = ScreenSnapshot()
    private var activeWarnings: [PanelWarning] = []
    var hasWarning: Bool { !activeWarnings.isEmpty }
    let screenUpdates = PassthroughSubject<ScreenSnapshot, Never>()
    let statusUpdates = PassthroughSubject<Void, Never>()

    struct AgentRow: Equatable {
        var state: RegistrationState?
        /// The agent CLI used to check or change the entry.
        var cliPath: String?
        /// Fingerprint of the existing entry; a confirmed replace names it.
        var fingerprint: String?
        var operation: String?
        var busy: Bool { operation != nil }
        var resultID: UInt64 = 0
        var busyGeneration: UInt64 = 0
        var message: String?
        var messageIsError = false
        /// The registrar's own (English) wording, shown on hover; also what `aistats install` prints.
        var messageDetail: String?
    }

    private let sampler = SystemSampler(slowMetricsInterval: AppModel.slowMetricsInterval)
    private let history: HistoryStore
    private let activity: ActivityStore
    private let samplerQueue = DispatchQueue(label: "aistats.sampler", qos: .utility)
    private let storeQueue = DispatchQueue(label: "aistats.store", qos: .utility)
    private let registrationQueue = DispatchQueue(label: "aistats.registration", qos: .userInitiated, attributes: .concurrent)
    private let activityPoll = ActivityPoll()
    private let crossings = OriginCrossings()
    private let processGate: ProcessGeneration
    private let orphanPoll = OrphanPoll()
    private let termination: OrphanTermination.System
    /// Called when the first Host becomes exposed (true) or the last one stops being exposed (false).
    var exposureChanged: ((Bool) -> Void)?
    /// Called when the presence poll sees a change in the live Sessions.
    var sessionsChanged: (() -> Void)?
    private var timer: Timer?
    private var pointID: UInt64 = 0
    private lazy var registration = RegistrationOperations(AgentRegistrar(binaryPath: cliPath))
    private var checking: Set<AgentTarget> = []
    private var confirmedReplacements: [AgentTarget: String] = [:]

    @discardableResult
    func setExposed(_ id: String, exposed: Bool) -> Bool {
        switch processGate.setExposed(id, exposed) {
        case .first:
            exposureChanged?(true)
            refreshRegistrations()
            refresh()
            return true
        case .last:
            exposureChanged?(false)
            orphanPoll.reset()
            if !screen.topProcesses.isEmpty || screen.tree != nil || screen.orphans != nil {
                screen.tree = nil
                screen.orphans = nil
                screen.topProcesses = []
                publishScreen()
            }
        case .unchanged:
            break
        }
        return false
    }

    private func publishScreen() {
        screen.revision += 1
        if processGate.ticket() != nil { screenUpdates.send(screen) }
    }

    init(directory: URL = AIStatsPaths.home, registration: RegistrationOperations? = nil,
         processGate: ProcessGeneration = ProcessGeneration(), termination: OrphanTermination.System? = nil) {
        history = HistoryStore(directory: directory)
        self.termination = termination ?? .live(home: directory)
        activity = ActivityStore(directory: directory)
        self.processGate = processGate
        if let registration { self.registration = registration }
        storeQueue.async { [weak self, history] in
            let recent = history.points(since: Date().addingTimeInterval(-Self.refreshInterval * Double(Self.sparklineLength)))
            DispatchQueue.main.async {
                guard let self, self.screen.cpuHistory.isEmpty else { return }
                self.screen.cpuHistory = recent.compactMap(\.cpuPercent).suffix(Self.sparklineLength).map { self.point($0) }
                if !self.screen.cpuHistory.isEmpty { self.publishScreen() }
            }
        }
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    private func point(_ value: Double) -> CPUPoint {
        pointID += 1
        return CPUPoint(id: pointID, value: value)
    }

    func refresh() {
        let generation = processGate.ticket()
        let sessions = screen.agents
        let rule = OriginAlertRule.current()
        let home = history.directory
        samplerQueue.async { [weak self, sampler, processGate, crossings, orphanPoll] in
            let before = sampler.slowMetricReads
            var entries: [Proc.Entry] = []
            var snapshot = sampler.sample { _ in
                processGate.enumerate(generation) {
                    entries = Proc.currentUserTable() ?? []
                    return entries.map(\.pid)
                }
            }
            if sampler.slowMetricReads != before { PanelTrace.marker("slow-sample") }
            let top = sampler.processCPUIsFresh
                ? sampler.topProcesses(sortedBy: .cpu, limit: 3, from: snapshot.topProcesses ?? [], includeParent: false) : []
            var tree: ProcessTree?
            var orphans: OrphanReport?
            var alerts: [AgentSessions.Busy] = []
            let processes = snapshot.topProcesses ?? []
            let fresh = sampler.processCPUIsFresh && processGate.allows(generation)
            let crossed = crossings.crossed(processes: fresh ? processes : [], rule: rule, generation: generation)
            if fresh {
                tree = ProcessTree(entries: entries, processes: processes, sessions: sessions, at: snapshot.timestamp)
                if !entries.isEmpty, orphanPoll.due() {
                    orphans = OrphanReport.collect(home: home, presences: sessions, table: entries, now: snapshot.timestamp)
                }
                if !crossed.isEmpty, let rule {
                    let origins = OriginSnapshot(processes: processes, entries: entries, sessions: sessions)
                    alerts = crossed.compactMap { origins.explain($0, metric: rule.metric) }
                }
            }
            snapshot.topProcesses = nil
            DispatchQueue.main.async {
                guard let self else { return }
                if fresh && processGate.allows(generation) {
                    self.screen.tree = tree
                    if let orphans { self.screen.orphans = orphans }
                    if !alerts.isEmpty, let rule { self.notify(alerts, rule: rule, generation: generation) }
                }
                self.apply(snapshot: snapshot, top: top, generation: generation)
            }
        }
        storeQueue.async { [weak self, activity, activityPoll] in
            guard activityPoll.due(token: activity.changeToken(), recheck: Self.agentRecheckInterval) else { return }
            let agents = activity.connectedAgents()
            let calls = Array(activity.recentCalls(limit: Self.visibleCallLimit).reversed())
            DispatchQueue.main.async {
                guard let self, self.screen.agents != agents || self.screen.recentCalls != calls else { return }
                let sessionsChanged = self.screen.agents != agents
                self.screen.agents = agents
                if sessionsChanged { self.sessionsChanged?() }
                if calls.contains(where: { !self.screen.recentCalls.contains($0) }) {
                    self.screen.quietEvent = PanelTrace.now
                }
                self.screen.recentCalls = calls
                self.publishScreen()
                self.statusUpdates.send()
            }
        }
    }

    private func notify(_ rows: [AgentSessions.Busy], rule: OriginAlertRule, generation: UInt64?) {
        guard OriginAlertRule.supportsNotifications else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            for row in rows {
                guard processGate.allows(generation), OriginAlertRule.current() == rule else { return }
                let content = UNMutableNotificationContent()
                content.title = "\(row.name) · \(rule.metric.label) \(rule.metric.reading(row))"
                content.body = row.originLabel
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    private func apply(snapshot: Snapshot, top: [ProcessUsage], generation: UInt64?) {
        guard snapshot.sampleIntervalSeconds > 0 else { return }
        let previousWarnings = activeWarnings
        let currentWarnings = PanelWarning.active(in: snapshot)
        activeWarnings = currentWarnings
        if currentWarnings.contains(where: { !previousWarnings.contains($0) }) { screen.quietEvent = PanelTrace.now }
        if previousWarnings.isEmpty, !currentWarnings.isEmpty { screen.warningGeneration += 1 }
        screen.sample = snapshot
        if snapshot.isAvailable("cpu") {
            screen.cpuHistory.append(point(snapshot.cpu.usagePercent))
            if screen.cpuHistory.count > Self.sparklineLength { screen.cpuHistory.removeFirst() }
        }
        if !top.isEmpty, processGate.allows(generation) { screen.topProcesses = top }
        PanelTrace.event("Sample published")
        publishScreen()
        statusUpdates.send()

        let point = HistoryPoint(snapshot: snapshot)
        storeQueue.async { [weak self, history] in
            var message: String?
            do { try history.record(point) } catch { message = "\(error)" }
            DispatchQueue.main.async { [message] in
                guard let self, self.screen.recordingError != message else { return }
                self.screen.recordingError = message
                self.publishScreen()
            }
        }
    }

    // MARK: Orphans

    struct TerminationResult: Equatable {
        let pid: Int32
        let name: String
        let message: String
        let isError: Bool
    }

    /// Runs the confirmed termination off the main thread and shows its result (ORP-035).
    func terminate(_ row: OrphanReport.Row) {
        showTermination(.init(pid: row.pid, name: row.name, message: "SIGTERM을 보내는 중…", isError: false))
        registrationQueue.async { [weak self, termination] in
            let outcome = OrphanTermination.run(pid: row.pid, startToken: row.startToken, agent: row.agent, system: termination)
            DispatchQueue.main.async {
                guard let self else { return }
                self.orphanPoll.reset()
                self.showTermination(.init(pid: row.pid, name: row.name, message: outcome.message, isError: outcome.isError))
            }
        }
    }

    private func showTermination(_ result: TerminationResult) {
        screen.terminations.removeAll { $0.pid == result.pid && $0.name == result.name }
        screen.terminations.insert(result, at: 0)
        screen.terminations = Array(screen.terminations.prefix(3))
        publishScreen()
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
        guard let last = screen.recentCalls.first else { return false }
        return Date().timeIntervalSince(last.date) < 6
    }

    var cliPath: String {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        return dir.appendingPathComponent("aistats").path
    }

    // MARK: Agent registration

    func refreshRegistrations() {
        let targets = AgentTarget.allCases.filter { screen.registrations[$0]?.busy != true }
        for t in targets {
            var row = screen.registrations[t] ?? AgentRow()
            if row.state != nil { row.busyGeneration += 1 }
            row.operation = "확인 중…"
            screen.registrations[t] = row
            checking.insert(t)
            registrationQueue.async { [weak self, registration] in
                let status = registration.status(t)
                DispatchQueue.main.async {
                    guard let self else { return }
                    var row = self.screen.registrations[t] ?? AgentRow()
                    row.state = status.state
                    row.cliPath = status.cliPath
                    row.fingerprint = status.entryFingerprint
                    row.operation = nil
                    self.screen.registrations[t] = row
                    self.checking.remove(t)
                    if let fingerprint = self.confirmedReplacements.removeValue(forKey: t) {
                        self.perform(.replace(fingerprint: fingerprint), t)
                    } else {
                        self.publishScreen()
                    }
                }
            }
        }
        if !targets.isEmpty { publishScreen() }
    }

    enum Action: Equatable {
        case connect, disconnect
        /// Overwrite another server named aistats; `fingerprint` names the entry the user confirmed.
        case replace(fingerprint: String)
    }

    struct RegistrationOperations {
        let status: @Sendable (AgentTarget) -> RegistrationStatus
        let perform: @Sendable (Action, AgentTarget) -> RegistrationOutcome

        init(status: @escaping @Sendable (AgentTarget) -> RegistrationStatus,
             perform: @escaping @Sendable (Action, AgentTarget) -> RegistrationOutcome) {
            self.status = status
            self.perform = perform
        }

        init(_ registrar: AgentRegistrar) {
            self.init(status: { registrar.status($0) }, perform: { action, target in
                switch action {
                case .connect: return registrar.install(target)
                case .disconnect: return registrar.uninstall(target)
                case .replace(let fingerprint): return registrar.replaceConfirmedConflict(target, fingerprint: fingerprint)
                }
            })
        }
    }

    func perform(_ action: Action, _ target: AgentTarget) {
        if case .replace(let fingerprint) = action, checking.contains(target) {
            if confirmedReplacements[target] == nil { confirmedReplacements[target] = fingerprint }
            return
        }
        guard screen.registrations[target]?.busy != true else { return }
        var row = screen.registrations[target] ?? AgentRow()
        if row.state != nil { row.busyGeneration += 1 }
        switch action {
        case .connect: row.operation = "연결하는 중…"
        case .disconnect: row.operation = "연결 해제 중…"
        case .replace: row.operation = "덮어쓰는 중…"
        }
        row.message = nil
        row.messageDetail = nil
        screen.registrations[target] = row
        publishScreen()
        registrationQueue.async { [weak self, registration] in
            let outcome = registration.perform(action, target)
            DispatchQueue.main.async {
                guard let self else { return }
                var row = self.screen.registrations[target] ?? AgentRow()
                row.operation = nil
                row.resultID += 1
                row.state = outcome.status.state
                row.cliPath = outcome.status.cliPath
                row.fingerprint = outcome.status.entryFingerprint
                row.messageIsError = !outcome.ok
                row.message = Self.message(for: outcome)
                row.messageDetail = outcome.ok ? nil : outcome.message
                self.screen.registrations[target] = row
                self.publishScreen()
            }
        }
    }

    nonisolated static func message(for o: RegistrationOutcome) -> String {
        guard o.ok else {
            let backup = o.backup.map { " · 백업: \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
            // A change was attempted (a backup exists) or may have been: report the state read back afterwards,
            // not a guess like "left unchanged". The registrar's exact words are in the row's tooltip.
            if o.backup == nil {
                switch o.status.state {
                case .agentNotFound: return "\(o.target.displayName)을(를) 찾지 못했습니다"
                case .nameConflict: return "다른 aistats 항목이 있어 바꾸지 않았습니다"
                case .checkFailed: return "설정을 읽지 못해 바꾸지 않았습니다"
                default: break
                }
            }
            return "실패 · 지금 상태: \(stateLabel(o.status.state))\(backup)"
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

    /// Korean label for a registration state (the row's status text and failure summaries).
    nonisolated static func stateLabel(_ state: RegistrationState) -> String {
        switch state {
        case .notInstalled: return "연결 안 됨"
        case .installed: return "등록됨"
        case .pathUpdateNeeded: return "경로 바뀜"
        case .nameConflict: return "다른 aistats 항목 있음"
        case .checkFailed: return "확인 실패"
        case .agentNotFound: return "설치 안 됨"
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

}

/// Spaces orphan report reads 10 s apart while a Host is exposed.
private final class OrphanPoll: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval?

    func due(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            if let last, now - last < 10 { return false }
            last = now
            return true
        }
    }

    func reset() { lock.withLock { last = nil } }
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
