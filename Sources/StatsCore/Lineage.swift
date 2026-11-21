import Darwin
import Foundation

/// The Lineage store of SDD 0013 and ADR 0009: `lineage/v1.jsonl` under the AIStats data directory. The menu bar app is
/// its only writer. The MCP server and the CLI only read it.
public enum Lineage {
    public static let version = "v1"
    /// The app's user defaults key of Closed-Panel Recording. A missing key means off.
    public static let closedPanelKey = "lineageClosedPanelRecording"
    public static let interval: TimeInterval = 1
    public static let grace: TimeInterval = 60
    static let heartbeat: TimeInterval = 60
    static let compactEvery: TimeInterval = 600
    /// The wait after a failed compaction before the writer tries another one.
    static let compactRetry: TimeInterval = 60
    static let triggerBytes = 2 * 1024 * 1024
    static let targetBytes = 1536 * 1024
    static let retention: TimeInterval = 7 * 86400
    static let maxIntervals = 2000
    static let unsupported = "lineage_version_unsupported"

    public static func directory(home: URL) -> URL { home.appendingPathComponent("lineage", isDirectory: true) }

    /// Active Recording conditions 2 and 3. Condition 1, the writer lock, belongs to the recorder.
    public static func shouldRecord(exposed: Bool, closedPanel: Bool, liveSessions: Int, lastLiveAt: Date?, now: Date) -> Bool {
        guard exposed || closedPanel else { return false }
        if liveSessions > 0 { return true }
        return lastLiveAt.map { now.timeIntervalSince($0) < grace } ?? false
    }

    struct Stamp: Hashable, Comparable {
        var sec: Int, usec: Int32
        init(_ e: Proc.Entry) { sec = e.startSec; usec = e.startUsec }
        static func < (a: Stamp, b: Stamp) -> Bool { (a.sec, a.usec) < (b.sec, b.usec) }
    }

    /// The Ancestor Walk over one table read. A parent that started after its child is a reused pid and ends the walk.
    static func walk(from pid: Int32, entries: [Int32: Proc.Entry], isAgent: (Proc.Entry) -> Bool) -> (agent: Int32?, reason: String?) {
        AgentSessions.walk(from: pid) { next in
            guard let node = entries[next] else { return nil }
            if isAgent(node) { return (node.ppid, true) }
            if let parent = entries[node.ppid], Stamp(parent) > Stamp(node) { return nil }
            return (node.ppid, false)
        }
    }

    /// The executable name: the last path component, or the kernel command name when the path is unreadable or empty.
    /// The path stays in memory only for this derivation.
    public static func executableName(_ e: Proc.Entry) -> String {
        Proc.path(e.pid).map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? e.comm
    }

    static func index(_ table: [Proc.Entry]) -> [Int32: Proc.Entry] {
        Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

public struct LineageIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startToken: String
    public init(pid: Int32, startToken: String) { self.pid = pid; self.startToken = startToken }
}

struct DescendantRecord: Codable, Equatable {
    var type = "descendant"
    var pid: Int32
    var startToken: String
    var name: String
    var agentPid: Int32
    var agentStartToken: String
    var session: String
    var firstSeenAt: Date
    var lastConfirmedAt: Date
    var key: LineageIdentity { .init(pid: pid, startToken: startToken) }
    var agent: LineageIdentity { .init(pid: agentPid, startToken: agentStartToken) }
}

struct SessionRecord: Codable, Equatable {
    var type = "session"
    var agentPid: Int32
    var agentStartToken: String
    var servers: [LineageIdentity]
    var name: String
    var firstSeenAt: Date
    var lastLiveAt: Date
    var exitedAt: Date?
    var agent: LineageIdentity { .init(pid: agentPid, startToken: agentStartToken) }
}

struct CoverageRecord: Codable {
    var type = "coverage"
    var interval: String
    /// start, heartbeat, stop, or merged.
    var event: String
    var at: Date?
    var start: Date?
    var end: Date?
}

struct CompactionRecord: Codable, Equatable {
    var type = "compaction"
    var at: Date
    var evicted: Int
}

/// The store resolved in file order (ADR 0009 Record updates).
struct LineageState {
    struct Interval { var id: String; var start: Date; var end: Date }
    private struct Peek: Decodable { var type: String }

    var sessions: [LineageIdentity: SessionRecord] = [:]
    var descendants: [LineageIdentity: DescendantRecord] = [:]
    var intervals: [String: Interval] = [:]
    var compactions: [CompactionRecord] = []
    var unreadable = 0

    init() {}

    init(parsing data: Data) {
        let decoder = JSONLinesFile.decoder
        for raw in data.split(separator: 10) {
            let line = Data(raw)
            guard let peek = try? decoder.decode(Peek.self, from: line) else { unreadable += 1; continue }
            switch peek.type {
            case "descendant":
                guard let r = try? decoder.decode(DescendantRecord.self, from: line) else { unreadable += 1; continue }
                descendants[r.key] = r
            case "session":
                guard let r = try? decoder.decode(SessionRecord.self, from: line) else { unreadable += 1; continue }
                sessions[r.agent] = r
            case "compaction":
                guard let r = try? decoder.decode(CompactionRecord.self, from: line) else { unreadable += 1; continue }
                compactions.append(r)
            case "coverage":
                guard let r = try? decoder.decode(CoverageRecord.self, from: line),
                      let end = r.event == "merged" ? r.end : r.at,
                      ["start", "heartbeat", "stop", "merged"].contains(r.event) else { unreadable += 1; continue }
                let start = r.event == "merged" ? r.start : r.event == "start" ? r.at : nil
                if r.event == "merged" && start == nil { unreadable += 1; continue }
                var interval = intervals[r.interval] ?? Interval(id: r.interval, start: start ?? end, end: end)
                if let start { interval.start = start }
                interval.end = end
                intervals[r.interval] = interval
            default:
                unreadable += 1
            }
        }
    }

    var orderedIntervals: [Interval] { intervals.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) } }

    /// One line per record: Session, Descendant, merged Coverage, then Compaction lines.
    func lines() -> [Data] {
        let e = JSONLinesFile.encoder
        let s = sessions.values.sorted { ($0.firstSeenAt, $0.agentPid) < ($1.firstSeenAt, $1.agentPid) }
        let d = descendants.values.sorted { ($0.firstSeenAt, $0.pid) < ($1.firstSeenAt, $1.pid) }
        let c = orderedIntervals.map { CoverageRecord(interval: $0.id, event: "merged", start: $0.start, end: $0.end) }
        return s.compactMap { try? e.encode($0) } + d.compactMap { try? e.encode($0) } + c.compactMap { try? e.encode($0) }
            + compactions.compactMap { try? e.encode($0) }
    }
}

public final class LineageStore: @unchecked Sendable {
    public let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Lineage.version + ".jsonl") }
    var lockURL: URL { directory.appendingPathComponent("." + Lineage.version + ".jsonl.lock") }
    var writerURL: URL { directory.appendingPathComponent(".writer.lock") }
    private var writer: Int32 = -1

    public init(home: URL = AIStatsPaths.home) { directory = Lineage.directory(home: home) }

    deinit { if writer >= 0 { close(writer) } }

    /// The resolved store and the reason it has none. Takes only a shared lock. Never creates, changes or removes a file.
    func read() -> (state: LineageState, reason: String?) {
        if let data = readFile(locked: true) { return (LineageState(parsing: data), nil) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let other = names.contains { $0.hasPrefix("v") && $0.hasSuffix(".jsonl") && $0 != fileURL.lastPathComponent }
        return (LineageState(), other ? Lineage.unsupported : nil)
    }

    private func readFile(locked: Bool) -> Data? {
        let lock = locked ? open(lockURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) : -1
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        if lock >= 0 { while flock(lock, LOCK_SH) != 0 && errno == EINTR {} }
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return (try? handle.readToEnd()) ?? Data()
    }

    /// Takes the writer lock without blocking. False while another app instance holds it.
    func claimWriter() -> Bool {
        if writer >= 0 { return true }
        guard (try? ensureDirectory()) != nil else { return false }
        let fd = open(writerURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        writer = fd
        return true
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid(),
              chmod(directory.path, 0o700) == 0 else { throw StoreError.io("lineage directory is not usable") }
    }

    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        try ensureDirectory()
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("open lineage lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        while flock(fd, LOCK_EX) != 0 { guard errno == EINTR else { throw StoreError.io("flock: \(String(cString: strerror(errno)))") } }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    var size: Int {
        var st = stat()
        return lstat(fileURL.path, &st) == 0 ? Int(st.st_size) : 0
    }

    func append(_ lines: [Data]) throws {
        guard !lines.isEmpty else { return }
        try exclusive {
            let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw StoreError.io("open lineage: \(String(cString: strerror(errno)))") }
            defer { close(fd) }
            fchmod(fd, 0o600)
            var data = Data()
            for line in lines { data.append(line); data.append(10) }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == data.count else { throw StoreError.io("short write to lineage") }
        }
    }

    /// ADR 0009 Retention steps 1 to 7. `alive` tells whether a process runs with its Start Token.
    @discardableResult
    func compact(now: Date, alive: (LineageIdentity) -> Bool) throws -> LineageState {
        try exclusive {
            var state = LineageState(parsing: readFile(locked: false) ?? Data())
            state.unreadable = 0
            for key in Array(state.descendants.keys) {
                if alive(key) { state.descendants[key]?.lastConfirmedAt = now } else { state.descendants[key] = nil }
            }
            let referenced = Set(state.descendants.values.map(\.agent))
            for key in Array(state.sessions.keys) {
                if alive(key) { state.sessions[key]?.lastLiveAt = now } else if !referenced.contains(key) { state.sessions[key] = nil }
            }
            let cutoff = now.addingTimeInterval(-Lineage.retention)
            state.intervals = state.intervals.filter { $0.value.end >= cutoff }
            for old in state.orderedIntervals.dropLast(Lineage.maxIntervals) { state.intervals[old.id] = nil }
            state.compactions.removeAll { $0.at < cutoff }
            var total = state.lines().reduce(0) { $0 + $1.count + 1 }
            var evicted = 0
            if total > Lineage.triggerBytes {
                let note = (try? JSONLinesFile.encoder.encode(CompactionRecord(at: now, evicted: Int(Int32.max))).count) ?? 80
                let newest = state.descendants.values.sorted { ($0.firstSeenAt, $0.pid) > ($1.firstSeenAt, $1.pid) }
                for record in newest where total + note + 1 > Lineage.targetBytes {
                    total -= ((try? JSONLinesFile.encoder.encode(record).count) ?? 0) + 1
                    state.descendants[record.key] = nil
                    evicted += 1
                }
            }
            if evicted > 0 { state.compactions.append(CompactionRecord(at: now, evicted: evicted)) }
            var data = Data()
            for line in state.lines() { data.append(line); data.append(10) }
            try replace(with: data)
            return state
        }
    }

    private func replace(with data: Data) throws {
        let tmp = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("create lineage: \(String(cString: strerror(errno)))") }
        fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(tmp.path, fileURL.path) == 0 else {
            unlink(tmp.path)
            throw StoreError.io("replace lineage")
        }
    }
}

/// The Lineage Recorder of ADR 0009. The app calls it from one queue, once per interval during Active Recording.
public final class LineageRecorder {
    public struct Probe {
        public var table: () -> [Proc.Entry]?
        public var token: (Int32) -> String?
        /// The executable name. The path stays in memory only for this derivation.
        public var name: (Proc.Entry) -> String
        public var now: () -> Date

        public init(table: @escaping () -> [Proc.Entry]?, token: @escaping (Int32) -> String?,
                    name: @escaping (Proc.Entry) -> String, now: @escaping () -> Date) {
            self.table = table; self.token = token; self.name = name; self.now = now
        }

        public static let live = Probe(table: Proc.currentUserTable, token: { Proc.usage($0).map { String($0.start) } },
                                       name: Lineage.executableName, now: Date.init)
    }

    let store: LineageStore
    private let probe: Probe
    public private(set) var recording = false
    private var interval = ""
    private var lastTick = Date.distantPast, lastHeartbeat = Date.distantPast, lastCompaction = Date.distantPast
    /// After a failed compaction, no table read for a start and no compaction happens before this time.
    private var retryAt = Date.distantPast
    private var previous: [Int32: Lineage.Stamp] = [:]
    private var known: Set<LineageIdentity> = []
    private var sessions: [LineageIdentity: SessionRecord] = [:]
    /// Agent Processes observed live in this interval, with their verified table start time.
    private var agents: [LineageIdentity: Lineage.Stamp] = [:]
    private var lastAgents: Set<LineageIdentity> = []

    public init(home: URL = AIStatsPaths.home, probe: Probe = .live) {
        store = LineageStore(home: home)
        self.probe = probe
    }

    /// Starts a coverage interval: writer lock, one table read, a compaction, the start line and a first pass.
    /// False without the writer lock or a table, so nothing is written. After a failed compaction or start line, the next
    /// attempt waits `Lineage.compactRetry` without a table read.
    @discardableResult
    public func start(presences: [ActivityStore.Presence]) -> Bool {
        guard !recording else { return true }
        guard probe.now() >= retryAt, store.claimWriter(), let table = probe.table() else { return false }
        let now = probe.now(), entries = Lineage.index(table)
        guard let state = try? store.compact(now: now, alive: { alive($0, entries) }) else {
            retryAt = now.addingTimeInterval(Lineage.compactRetry)
            return false
        }
        interval = String(UUID().uuidString.prefix(8)).lowercased()
        guard (try? store.append([encode(CoverageRecord(interval: interval, event: "start", at: now))])) != nil else {
            retryAt = now.addingTimeInterval(Lineage.compactRetry)
            return false
        }
        sessions = state.sessions
        known = Set(state.descendants.keys)
        agents = [:]
        for key in sessions.keys where alive(key, entries) { agents[key] = entries[key.pid].map(Lineage.Stamp.init) }
        lastAgents = []
        previous = [:]
        recording = true
        lastTick = now; lastHeartbeat = now; lastCompaction = now
        pass(table, entries, presences, now)
        return true
    }

    public func tick(presences: [ActivityStore.Presence]) {
        guard recording, let table = probe.table() else { return }
        let now = probe.now(), entries = Lineage.index(table)
        if now.timeIntervalSince(lastCompaction) >= Lineage.compactEvery { compact(entries, now) }
        pass(table, entries, presences, now)
    }

    /// Ends the coverage interval at the last pass without a table read.
    public func stop() {
        guard recording else { return }
        recording = false
        var lines: [Data] = []
        for key in agents.keys.sorted(by: { $0.pid < $1.pid }) {
            guard var record = sessions[key] else { continue }
            record.lastLiveAt = lastTick
            sessions[key] = record
            lines.append(encode(record))
        }
        lines.append(encode(CoverageRecord(interval: interval, event: "stop", at: lastTick)))
        try? store.append(lines)
        agents = [:]
        previous = [:]
    }

    private func alive(_ key: LineageIdentity, _ entries: [Int32: Proc.Entry]) -> Bool {
        entries[key.pid] != nil && probe.token(key.pid) == key.startToken
    }

    private func encode<T: Encodable>(_ value: T) -> Data { (try? JSONLinesFile.encoder.encode(value)) ?? Data() }

    /// False when the compaction fails or waits for its retry time. A failure starts that wait.
    @discardableResult
    private func compact(_ entries: [Int32: Proc.Entry], _ now: Date) -> Bool {
        guard now >= retryAt else { return false }
        guard let state = try? store.compact(now: now, alive: { alive($0, entries) }) else {
            retryAt = now.addingTimeInterval(Lineage.compactRetry)
            return false
        }
        sessions = state.sessions
        known = known.filter { entries[$0.pid] != nil }
        lastCompaction = now
        return true
    }

    /// A pass whose append is skipped leaves its state unchanged, so the next pass observes the same changes again.
    private func pass(_ table: [Proc.Entry], _ entries: [Int32: Proc.Entry], _ presences: [ActivityStore.Presence], _ now: Date) {
        let saved = (agents, sessions, known, previous, lastAgents, lastHeartbeat, lastTick)
        var lines: [Data] = []
        // The Session records this pass changes. A compaction before the append reads the file without them.
        var changed: [LineageIdentity: SessionRecord] = [:]
        for (key, stamp) in agents.sorted(by: { $0.key.pid < $1.key.pid }) where entries[key.pid].map(Lineage.Stamp.init) != stamp {
            agents[key] = nil
            guard var record = sessions[key] else { continue }
            record.exitedAt = now
            record.lastLiveAt = lastTick
            sessions[key] = record
            changed[key] = record
            lines.append(encode(record))
        }
        var observed: [LineageIdentity: (name: String, servers: [LineageIdentity])] = [:]
        for p in presences.sorted(by: { $0.connectedAt < $1.connectedAt }) {
            guard let pid = p.agentPid, let token = p.agentStartToken, let entry = entries[pid] else { continue }
            let key = LineageIdentity(pid: pid, startToken: token)
            if agents[key] != Lineage.Stamp(entry) {
                guard agents[key] == nil, probe.token(pid) == token else { continue }
                agents[key] = Lineage.Stamp(entry)
            }
            var info = observed[key] ?? (p.name, [])
            info.name = p.name
            if let server = p.startToken { info.servers.append(.init(pid: p.pid, startToken: server)) }
            observed[key] = info
        }
        for (key, info) in observed.sorted(by: { $0.key.pid < $1.key.pid }) {
            let before = sessions[key]
            var record = before ?? SessionRecord(agentPid: key.pid, agentStartToken: key.startToken, servers: [], name: info.name,
                                                 firstSeenAt: now, lastLiveAt: now)
            for server in info.servers where !record.servers.contains(server) { record.servers.append(server) }
            record.name = info.name
            guard record != before else { continue }
            record.lastLiveAt = now
            sessions[key] = record
            changed[key] = record
            lines.append(encode(record))
        }
        let agentPids = Dictionary(agents.map { ($0.key.pid, ($0.key, $0.value)) }, uniquingKeysWith: { a, _ in a })
        let servers = Set(presences.map(\.pid))
        let rescan = !Set(agents.keys).isSubset(of: lastAgents)
        for e in table where e.pid > 1 && agentPids[e.pid] == nil && !servers.contains(e.pid) {
            guard rescan || previous[e.pid] != Lineage.Stamp(e) else { continue }
            let walk = Lineage.walk(from: e.pid, entries: entries) { node in agentPids[node.pid]?.1 == Lineage.Stamp(node) }
            guard let pid = walk.agent, let agent = agentPids[pid]?.0, let token = probe.token(e.pid) else { continue }
            let key = LineageIdentity(pid: e.pid, startToken: token)
            guard known.insert(key).inserted else { continue }
            lines.append(encode(DescendantRecord(pid: e.pid, startToken: token, name: probe.name(e), agentPid: agent.pid,
                                                 agentStartToken: agent.startToken, session: sessions[agent]?.name ?? "agent",
                                                 firstSeenAt: now, lastConfirmedAt: now)))
        }
        previous = Dictionary(table.map { ($0.pid, Lineage.Stamp($0)) }, uniquingKeysWith: { a, _ in a })
        lastAgents = Set(agents.keys)
        if now.timeIntervalSince(lastHeartbeat) >= Lineage.heartbeat {
            lines.append(encode(CoverageRecord(interval: interval, event: "heartbeat", at: now)))
            lastHeartbeat = now
        }
        lastTick = now
        guard !lines.isEmpty else { return }
        if store.size + lines.reduce(0, { $0 + $1.count + 1 }) > Lineage.triggerBytes {
            // Without a compaction the append would break the size limit (ORP-008), so the pass skips it.
            guard compact(entries, now) else {
                (agents, sessions, known, previous, lastAgents, lastHeartbeat, lastTick) = saved
                return
            }
            sessions.merge(changed) { $1 }
        }
        try? store.append(lines)
    }
}

/// The orphan report of SDD 0013. Reading it never writes the store and never signals a process.
public struct OrphanReport: Encodable, Sendable {
    public struct Row: Encodable, Sendable, Equatable {
        public var pid: Int32
        public var startToken: String
        public var name: String
        public var memoryBytes: UInt64
        public var cpuSeconds: Double
        public var startedAt: Date
        public var session: String
        public var endedAt: Date?
        public var endedAfter: Date?
        public var evidence = "lineage"
        /// The Agent Identity of the Session record, for the app's re-verification. Not reported.
        public var agent: LineageIdentity

        public init(pid: Int32, startToken: String, name: String, memoryBytes: UInt64, cpuSeconds: Double, startedAt: Date,
                    session: String, endedAt: Date?, endedAfter: Date?, agent: LineageIdentity) {
            self.pid = pid; self.startToken = startToken; self.name = name; self.memoryBytes = memoryBytes; self.cpuSeconds = cpuSeconds
            self.startedAt = startedAt; self.session = session; self.endedAt = endedAt; self.endedAfter = endedAfter; self.agent = agent
        }

        enum CodingKeys: String, CodingKey { case pid, startToken, name, memoryBytes, cpuSeconds, startedAt, session, endedAt, endedAfter, evidence }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pid, forKey: .pid)
            try c.encode(startToken, forKey: .startToken)
            try c.encode(name, forKey: .name)
            try c.encode(memoryBytes, forKey: .memoryBytes)
            try c.encode(cpuSeconds, forKey: .cpuSeconds)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(session, forKey: .session)
            try c.encode(endedAt, forKey: .endedAt)
            try c.encode(endedAfter, forKey: .endedAfter)
            try c.encode(evidence, forKey: .evidence)
        }
    }

    public static let maxRows = 15

    public var observedAt: Date
    public var coverageSince: Date?
    public var lastObservedAt: Date?
    public var coverageGaps = 0
    public var evictedRecords = 0
    public var unreadableRecords = 0
    public var reason: String?
    public var processes: [Row] = []
    public var matched = 0
    public var truncated = false
    public var processesOmitted = 0

    enum CodingKeys: String, CodingKey {
        case observedAt, coverageSince, lastObservedAt, coverageGaps, evictedRecords, unreadableRecords, reason, processes, matched, truncated, processesOmitted
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(coverageSince, forKey: .coverageSince)
        try c.encode(lastObservedAt, forKey: .lastObservedAt)
        try c.encode(coverageGaps, forKey: .coverageGaps)
        try c.encode(evictedRecords, forKey: .evictedRecords)
        try c.encode(unreadableRecords, forKey: .unreadableRecords)
        try c.encode(reason, forKey: .reason)
        try c.encode(processes, forKey: .processes)
        try c.encode(matched, forKey: .matched)
        try c.encode(truncated, forKey: .truncated)
        try c.encode(processesOmitted, forKey: .processesOmitted)
    }

    /// One table read and one store read. `presences` and `table` default to live reads.
    /// A row takes its name from the live process, because an exec keeps the pid and Start Token but changes the name.
    public static func collect(home: URL = AIStatsPaths.home, presences: [ActivityStore.Presence]? = nil, table: [Proc.Entry]? = nil,
                               usage: (Int32) -> Proc.Usage? = Proc.usage, name: (Proc.Entry) -> String = Lineage.executableName,
                               now: Date = Date()) -> OrphanReport {
        let (state, reason) = LineageStore(home: home).read()
        var report = OrphanReport(observedAt: now, reason: reason)
        let intervals = state.orderedIntervals
        report.coverageSince = intervals.first?.start
        report.lastObservedAt = intervals.last?.end
        report.coverageGaps = zip(intervals, intervals.dropFirst()).filter { $1.start > $0.end }.count
        report.evictedRecords = state.compactions.reduce(0) { $0 + $1.evicted }
        report.unreadableRecords = state.unreadable
        guard reason == nil, !state.descendants.isEmpty, let table = table ?? Proc.currentUserTable() else { return report }
        let entries = Lineage.index(table)
        var cache: [Int32: Proc.Usage?] = [:]
        func read(_ pid: Int32) -> Proc.Usage? {
            if let hit = cache[pid] { return hit }
            let value = usage(pid)
            cache[pid] = value
            return value
        }
        func alive(_ key: LineageIdentity) -> Bool { entries[key.pid] != nil && read(key.pid).map { String($0.start) } == key.startToken }
        var agentKeys = Set(state.sessions.keys), serverKeys = Set(state.sessions.values.flatMap(\.servers))
        for p in presences ?? ActivityStore(directory: home).connectedAgents() {
            if let pid = p.agentPid, let token = p.agentStartToken { agentKeys.insert(.init(pid: pid, startToken: token)) }
            if let token = p.startToken { serverKeys.insert(.init(pid: p.pid, startToken: token)) }
        }
        let liveAgents = Set(agentKeys.filter(alive).map(\.pid))
        var rows: [Row] = []
        for d in state.descendants.values {
            guard !agentKeys.contains(d.key), !serverKeys.contains(d.key), !alive(d.agent), let entry = entries[d.pid],
                  let use = read(d.pid), String(use.start) == d.startToken,
                  Lineage.walk(from: d.pid, entries: entries, isAgent: { liveAgents.contains($0.pid) }).agent == nil else { continue }
            let session = state.sessions[d.agent]
            let ended = session?.exitedAt
            rows.append(Row(pid: d.pid, startToken: d.startToken, name: name(entry), memoryBytes: use.footprint,
                            cpuSeconds: (Double(use.cpuNs) / 1e7).rounded() / 100,
                            startedAt: Date(timeIntervalSince1970: Double(entry.startSec) + Double(entry.startUsec) / 1e6),
                            session: d.session, endedAt: ended, endedAfter: ended == nil ? session?.lastLiveAt ?? d.firstSeenAt : nil,
                            agent: d.agent))
        }
        rows.sort { $0.memoryBytes == $1.memoryBytes ? $0.pid < $1.pid : $0.memoryBytes > $1.memoryBytes }
        report.matched = rows.count
        report.processes = Array(rows.prefix(maxRows))
        report.truncated = rows.count > maxRows
        return report
    }

    /// Removes the row with the least memory. False when no row is left.
    mutating func trim() -> Bool {
        guard !processes.isEmpty else { return false }
        processes.removeLast()
        processesOmitted += 1
        truncated = true
        return true
    }

    public var summaryLine: String {
        if reason != nil { return "The lineage store has a format this version cannot read." }
        guard let since = coverageSince else { return "No lineage recorded yet. The AIStats app records it while an agent session is live." }
        let start = ISO8601DateFormatter().string(from: since)
        return matched == 0 ? "No orphan candidates since \(start)." : "\(matched) orphan candidate\(matched == 1 ? "" : "s") since \(start)."
    }

    public func text() -> String {
        var lines = [summaryLine]
        if coverageSince != nil {
            lines.append("Coverage gaps: \(coverageGaps)" + (lastObservedAt.map { ", last observed \(ISO8601DateFormatter().string(from: $0))" } ?? ""))
        }
        if !processes.isEmpty {
            func pad(_ s: String, _ width: Int) -> String { s + String(repeating: " ", count: max(1, width - s.count)) }
            let f = ISO8601DateFormatter()
            lines.append(pad("PID", 8) + pad("START TOKEN", 22) + pad("MEMORY", 10) + pad("SESSION", 16) + pad("ENDED", 23) + "NAME")
            for r in processes {
                let ended = r.endedAt.map(f.string) ?? r.endedAfter.map { "after " + f.string(from: $0) } ?? "?"
                lines.append(pad(String(r.pid), 8) + pad(r.startToken, 22) + pad(Format.bytes(r.memoryBytes), 10) + pad(r.session, 16) + pad(ended, 23) + r.name)
            }
        }
        if truncated { lines.append("+\(matched - processes.count) more") }
        return lines.joined(separator: "\n")
    }
}

/// The app termination action of ADR 0009: re-verification, one SIGTERM to the pid alone, and a check after 2 s.
public enum OrphanTermination {
    public enum Outcome: Equatable, Sendable { case exited, stillRunning, refused(String), failed(Int32) }

    public struct System {
        public var owned: (Int32) -> Bool
        public var token: (Int32) -> String?
        public var table: () -> [Proc.Entry]?
        public var liveAgents: () -> Set<LineageIdentity>
        /// Returns 0 or the errno value.
        public var signal: (Int32, Int32) -> Int32
        public var wait: (TimeInterval) -> Void

        public init(owned: @escaping (Int32) -> Bool, token: @escaping (Int32) -> String?, table: @escaping () -> [Proc.Entry]?,
                    liveAgents: @escaping () -> Set<LineageIdentity>, signal: @escaping (Int32, Int32) -> Int32,
                    wait: @escaping (TimeInterval) -> Void) {
            self.owned = owned; self.token = token; self.table = table; self.liveAgents = liveAgents; self.signal = signal; self.wait = wait
        }

        public static func live(home: URL) -> System {
            let token: (Int32) -> String? = { Proc.usage($0).map { String($0.start) } }
            return System(owned: { pid in
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout.size(ofValue: info))
                return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == geteuid()
            }, token: token, table: Proc.currentUserTable, liveAgents: {
                var keys = Set(LineageStore(home: home).read().state.sessions.keys)
                for p in ActivityStore(directory: home).connectedAgents() {
                    if let pid = p.agentPid, let t = p.agentStartToken { keys.insert(.init(pid: pid, startToken: t)) }
                }
                return keys.filter { token($0.pid) == $0.startToken }
            }, signal: { kill($0, $1) == 0 ? 0 : errno }, wait: { Thread.sleep(forTimeInterval: $0) })
        }
    }

    public static func run(pid: Int32, startToken: String, agent: LineageIdentity, system: System, delay: TimeInterval = 2) -> Outcome {
        guard pid > 1 else { return .refused("invalid_pid") }
        guard system.owned(pid) else { return .refused("not_current_user") }
        guard system.token(agent.pid) != agent.startToken else { return .refused("agent_running") }
        guard let table = system.table() else { return .refused("table_unreadable") }
        let agents = Set(system.liveAgents().map(\.pid))
        guard Lineage.walk(from: pid, entries: Lineage.index(table), isAgent: { agents.contains($0.pid) }).agent == nil else {
            return .refused("agent_ancestor")
        }
        guard system.token(pid) == startToken else { return .refused("process_replaced") }
        let code = system.signal(pid, SIGTERM)
        guard code == 0 else { return code == ESRCH ? .exited : .failed(code) }
        system.wait(delay)
        return system.token(pid) == startToken ? .stillRunning : .exited
    }
}
