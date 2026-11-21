import Darwin
import Foundation

// MARK: - Options and report

public struct TrackOptions: Sendable {
    public var selector: ProcessSelector
    public var includeChildren = false
    public var durationSeconds = 300
    public var intervalSeconds = 2.0
    public var spikeCpuPercent = 150.0
    public var sampleOnSpike = false

    public static let durationRange = 10...7200
    public static let intervalRange = 1.0...60.0
    public static let spikeRange = 10.0...10_000.0

    public init(selector: ProcessSelector, includeChildren: Bool = false, durationSeconds: Int = 300,
                intervalSeconds: Double = 2, spikeCpuPercent: Double = 150, sampleOnSpike: Bool = false) throws {
        guard Self.durationRange.contains(durationSeconds) else { throw ProcessSelector.Invalid("durationSeconds must be 10–7200") }
        guard Self.intervalRange.contains(intervalSeconds) else { throw ProcessSelector.Invalid("intervalSeconds must be 1–60") }
        guard Self.spikeRange.contains(spikeCpuPercent) else { throw ProcessSelector.Invalid("spikeCpuPercent must be 10–10000") }
        guard Double(durationSeconds) >= intervalSeconds else { throw ProcessSelector.Invalid("durationSeconds must be at least intervalSeconds") }
        self.selector = selector; self.includeChildren = includeChildren; self.durationSeconds = durationSeconds
        self.intervalSeconds = intervalSeconds; self.spikeCpuPercent = spikeCpuPercent; self.sampleOnSpike = sampleOnSpike
    }
}

public struct TrackReport: Codable, Sendable {
    public struct Range: Codable, Sendable, Equatable { public var min, avg, max, last: Double }
    public struct BytesRange: Codable, Sendable, Equatable { public var min, avg, max, last: UInt64 }

    public struct Aggregate: Codable, Sendable {
        /// Sum over members, percent of one core; time-weighted average. Nil until two readings exist.
        public var cpuPercent: Range?
        public var footprintBytes: BytesRange?
        /// The highest lifetime peak footprint (`ri_lifetime_max_phys_footprint`) of any single member
        /// seen during the track. Not comparable with `footprintBytes`, which sums all members.
        public var largestProcessLifetimePeakBytes: UInt64?
        public var liveMembers: Int
        /// Distinct process instances seen (including ones not kept because of the member limit).
        public var membersSeen: Int
    }

    public struct Member: Codable, Sendable {
        public var pid: Int32
        public var startToken: String
        public var name: String
        /// True for a matched instance; absent for its descendants.
        public var root: Bool?
        public var exited: Bool?
        public var cpuPercent: Range?
        public var footprintBytes: BytesRange?
        public var lifetimeMaxFootprintBytes: UInt64?
        /// Path tracks only, and only for processes whose executable matches the selector.
        public var path: String?
        /// Set when `path` was checked against the selector. Saved to disk (not sent to clients) so a
        /// summary read back keeps only checked paths.
        var pathMatched: Bool?

        enum CodingKeys: String, CodingKey {
            case pid, startToken, name, root, exited, cpuPercent, footprintBytes, lifetimeMaxFootprintBytes, path, pathMatched
        }

        public init(pid: Int32, startToken: String, name: String, root: Bool?, exited: Bool?, cpuPercent: Range?,
                    footprintBytes: BytesRange?, lifetimeMaxFootprintBytes: UInt64?, path: String?) {
            self.pid = pid; self.startToken = startToken; self.name = name; self.root = root; self.exited = exited
            self.cpuPercent = cpuPercent; self.footprintBytes = footprintBytes
            self.lifetimeMaxFootprintBytes = lifetimeMaxFootprintBytes; self.path = path
            self.pathMatched = path != nil ? true : nil
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = try c.decode(Int32.self, forKey: .pid)
            startToken = try c.decode(String.self, forKey: .startToken)
            name = try c.decode(String.self, forKey: .name)
            root = try c.decodeIfPresent(Bool.self, forKey: .root)
            exited = try c.decodeIfPresent(Bool.self, forKey: .exited)
            cpuPercent = try c.decodeIfPresent(Range.self, forKey: .cpuPercent)
            footprintBytes = try c.decodeIfPresent(BytesRange.self, forKey: .footprintBytes)
            lifetimeMaxFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .lifetimeMaxFootprintBytes)
            pathMatched = try c.decodeIfPresent(Bool.self, forKey: .pathMatched)
            // Summaries saved before the flag existed (or without it) may hold unchecked descendant paths.
            path = pathMatched == true ? try c.decodeIfPresent(String.self, forKey: .path) : nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pid, forKey: .pid)
            try c.encode(startToken, forKey: .startToken)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(root, forKey: .root)
            try c.encodeIfPresent(exited, forKey: .exited)
            try c.encodeIfPresent(cpuPercent, forKey: .cpuPercent)
            try c.encodeIfPresent(footprintBytes, forKey: .footprintBytes)
            try c.encodeIfPresent(lifetimeMaxFootprintBytes, forKey: .lifetimeMaxFootprintBytes)
            try c.encodeIfPresent(path, forKey: .path)
            if encoder.userInfo[TrackManager.persistingKey] as? Bool == true, path != nil {
                try c.encodeIfPresent(pathMatched, forKey: .pathMatched)
            }
        }
    }

    public struct Instance: Codable, Sendable {
        public var pid: Int32
        public var startToken: String
        public var startedAt: Date
        public var exitedAt: Date?
    }

    public struct Event: Codable, Sendable {
        public var t: Date
        public var kind: String
        public var pid: Int32
        public var name: String?
        public var detail: String?
    }

    public struct Spike: Codable, Sendable {
        public var t: Date
        public var pid: Int32
        public var name: String
        public var cpuPercent: Double
        public var threads: [Proc.ThreadSample]?
        /// Threads not listed (the process had more than shown).
        public var threadsOmitted: Int?
        public var threadsUnreadable: Bool?
        public var sampleFile: String?
        public var sampleTopFrames: [String]?
        public var sampleFramesOmitted: Int?
        public var sampleError: String?
        var id: Int = 0

        enum CodingKeys: String, CodingKey {
            case t, pid, name, cpuPercent, threads, threadsOmitted, threadsUnreadable, sampleFile, sampleTopFrames,
                 sampleFramesOmitted, sampleError
        }
    }

    public struct ExecutableCount: Codable, Sendable { public var name: String; public var count: Int }

    public struct Spawn: Codable, Sendable {
        /// "kqueue+polling", or "polling" when kqueue could not watch the processes.
        public var method: String
        /// Forks seen by kqueue on watched processes.
        public var forks: Int
        /// Always true: kqueue merges fork events that arrive faster than they are read.
        public var forksLowerBound: Bool
        /// Child instances seen and attributed to an executable (polling and fork-triggered listing).
        public var childrenAttributed: Int
        public var unattributedForks: Int
        public var byExecutable: [ExecutableCount]
        public var executablesOmitted: Int
        public var perMinuteStart: Date
        public var bucketSeconds: Int
        public var forksPerBucket: [Int]
    }

    public var trackId: String
    /// "running", "ended" (duration elapsed or pid target exited), "stopped", or "interrupted"
    /// (the session that ran it died before finishing).
    public var state: String
    public var endReason: String?
    public var selector: String
    public var match: String?
    public var includeChildren: Bool
    public var scope: String
    public var startedAt: Date
    public var endsAt: Date
    public var endedAt: Date?
    public var elapsedSeconds: Double
    public var durationSeconds: Int
    public var intervalSeconds: Double
    public var validSamples: Int
    /// Name/path tracks: a matching instance started after every earlier one had exited.
    public var restartCount: Int?
    /// Name/path tracks: matching instances that started while another one was still running.
    public var additionalInstances: Int?
    public var instances: [Instance]
    public var instancesOmitted: Int?
    public var aggregate: Aggregate
    public var members: [Member]
    public var membersOmitted: Int?
    /// Instances not tracked because the member limit (128 live) was reached.
    public var membersDropped: Int?
    public var events: [Event]
    public var eventsOmitted: Int?
    public var spikes: [Spike]
    public var spikesOmitted: Int?
    public var spikesRateLimited: Int?
    public var spawn: Spawn?
    public var notes: [String]?
    public var notesOmitted: Int?
    /// True when the selector had an argument filter (the filter itself is never stored or returned).
    public var argsFilter: Bool?
    /// With argsContain: processes that matched by name/path but whose arguments couldn't be read.
    public var argsUnreadable: Int?

    public var summaryLine: String {
        var parts = ["track \(trackId) \(state)\(endReason.map { " (\(Self.clip($0, 80)))" } ?? "") \(Int(elapsedSeconds))s/\(durationSeconds)s"]
        parts.append("\(aggregate.liveMembers) live of \(aggregate.membersSeen) seen")
        if let c = aggregate.cpuPercent {
            parts.append(String(format: "CPU avg %.1f%% max %.1f%% last %.1f%%", c.avg, c.max, c.last))
        } else {
            parts.append("CPU not measured yet")
        }
        if let f = aggregate.footprintBytes { parts.append("footprint last \(Format.bytes(f.last)) max \(Format.bytes(f.max))") }
        if let r = restartCount { parts.append("restarts \(r)") }
        if let a = additionalInstances, a > 0 { parts.append("additional instances \(a)") }
        if let s = spawn { parts.append("forks \(s.forks) (unattributed \(s.unattributedForks))") }
        let spikeCount = spikes.count + (spikesOmitted ?? 0)
        if spikeCount > 0 { parts.append("spikes \(spikeCount)") }
        return parts.joined(separator: ", ")
    }

    /// Shortens `s` to at most `n` characters, marking the cut with "…" (kept at the end, or at the
    /// start with `keepTail` so a path keeps its file name).
    static func clip(_ s: String, _ n: Int, keepTail: Bool = false) -> String {
        guard s.count > n, n > 1 else { return s }
        return keepTail ? "…" + s.suffix(n - 1) : s.prefix(n - 1) + "…"
    }
}

extension TrackReport {
    /// Trims optional detail until `measure` (by default the compact JSON size) is at most `maxBytes`:
    /// lists shrink (raising the matching `…Omitted` counts), long strings are shortened, sample frames and
    /// thread lists go last. Ids, state, aggregate figures and omission counts are always kept.
    public func fitting(maxBytes: Int, measure: ((TrackReport) -> Int)? = nil) -> TrackReport {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let size = measure ?? { r in (try? encoder.encode(r).count) ?? 0 }
        func add(_ n: Int, to v: Int?) -> Int? { (v ?? 0) + n > 0 ? (v ?? 0) + n : nil }
        func keepEvents(_ r: inout TrackReport, _ n: Int) {
            guard r.events.count > n else { return }
            r.eventsOmitted = add(r.events.count - n, to: r.eventsOmitted); r.events = Array(r.events.suffix(n))
        }
        func keepMembers(_ r: inout TrackReport, _ n: Int) {
            guard r.members.count > n else { return }
            r.membersOmitted = add(r.members.count - n, to: r.membersOmitted); r.members = Array(r.members.prefix(n))
        }
        func keepInstances(_ r: inout TrackReport, _ n: Int) {
            guard r.instances.count > n else { return }
            r.instancesOmitted = add(r.instances.count - n, to: r.instancesOmitted); r.instances = Array(r.instances.suffix(n))
        }
        func keepSpikes(_ r: inout TrackReport, _ n: Int) {
            guard r.spikes.count > n else { return }
            r.spikesOmitted = add(r.spikes.count - n, to: r.spikesOmitted); r.spikes = Array(r.spikes.suffix(n))
        }
        func keepExecutables(_ r: inout TrackReport, _ n: Int) {
            guard var sp = r.spawn, sp.byExecutable.count > n else { return }
            sp.executablesOmitted += sp.byExecutable.count - n
            sp.byExecutable = Array(sp.byExecutable.prefix(n)); r.spawn = sp
        }
        func trimSpikes(_ r: inout TrackReport, threads: Int, frames: Int, frameChars: Int) {
            for i in r.spikes.indices {
                if let t = r.spikes[i].threads, t.count > threads {
                    r.spikes[i].threadsOmitted = add(t.count - threads, to: r.spikes[i].threadsOmitted)
                    r.spikes[i].threads = threads > 0 ? Array(t.prefix(threads)) : nil
                }
                if let f = r.spikes[i].sampleTopFrames {
                    if f.count > frames {
                        r.spikes[i].sampleFramesOmitted = add(f.count - frames, to: r.spikes[i].sampleFramesOmitted)
                    }
                    let kept = f.prefix(frames).map { Self.clip($0, frameChars) }
                    r.spikes[i].sampleTopFrames = kept.isEmpty ? nil : kept
                }
            }
        }
        func clipStrings(_ r: inout TrackReport, _ n: Int) {
            for i in r.members.indices {
                r.members[i].name = Self.clip(r.members[i].name, n)
                r.members[i].path = r.members[i].path.map { Self.clip($0, n + 32, keepTail: true) }
            }
            for i in r.events.indices {
                r.events[i].name = r.events[i].name.map { Self.clip($0, n) }
                r.events[i].detail = r.events[i].detail.map { Self.clip($0, n) }
            }
            for i in r.spikes.indices {
                r.spikes[i].name = Self.clip(r.spikes[i].name, n)
                r.spikes[i].sampleFile = r.spikes[i].sampleFile.map { Self.clip($0, n + 32, keepTail: true) }
                r.spikes[i].sampleError = r.spikes[i].sampleError.map { Self.clip($0, n + 32) }
                r.spikes[i].threads = r.spikes[i].threads?.map { var t = $0; t.name = Self.clip(t.name, 24); return t }
            }
            if var sp = r.spawn {
                sp.byExecutable = sp.byExecutable.map { .init(name: Self.clip($0.name, n), count: $0.count) }
                r.spawn = sp
            }
            r.notes = r.notes?.map { Self.clip($0, n + 72) }
            r.endReason = r.endReason.map { Self.clip($0, n + 72) }
        }
        let steps: [(inout TrackReport) -> Void] = [
            { trimSpikes(&$0, threads: 3, frames: 3, frameChars: 100) },
            { keepEvents(&$0, 4) },
            { keepMembers(&$0, 3) },
            { keepInstances(&$0, 1) },
            { keepSpikes(&$0, 1) },
            { keepExecutables(&$0, 4) },
            { clipStrings(&$0, 48) },
            { trimSpikes(&$0, threads: 1, frames: 1, frameChars: 60); keepEvents(&$0, 2); keepMembers(&$0, 1) },
            { trimSpikes(&$0, threads: 0, frames: 0, frameChars: 0); clipStrings(&$0, 24) },
            { r in
                keepEvents(&r, 0); keepMembers(&r, 0); keepInstances(&r, 0); keepSpikes(&r, 0); keepExecutables(&r, 0)
                if let notes = r.notes, notes.count > 1 {
                    r.notesOmitted = add(notes.count - 1, to: r.notesOmitted)
                    r.notes = Array(notes.prefix(1))
                }
            },
        ]
        var r = self
        for step in steps {
            if size(r) <= maxBytes { break }
            step(&r)
        }
        return r
    }
}

public struct TrackListRow: Codable, Sendable {
    public var trackId: String
    public var state: String
    public var selector: String
    public var startedAt: Date
    public var endedAt: Date?
    public var inThisSession: Bool
}

/// One periodic row for `aistats track --jsonl`.
public struct TrackTickRow: Codable, Sendable {
    public var t: Date
    public var cpuPercent: Double?
    public var footprintBytes: UInt64?
    public var liveMembers: Int
    public var forks: Int?
}

public enum TrackError: Error, CustomStringConvertible {
    case tooManyActive
    case notFound(String)
    case targetNotVisible(String)
    case notInSession(id: String, state: String)

    public var description: String {
        switch self {
        case .tooManyActive: return "at most \(TrackManager.maxActive) tracks can run at once in a session; stop one first"
        case .notFound(let id): return "no track with id \(id)"
        case .targetNotVisible(let why): return why
        case .notInSession(let id, let state):
            return state == "running"
                ? "track \(id) is running in another session; only that session can stop it (status works from any session)"
                : "track \(id) is not part of this session and is already \(state); nothing to stop (status shows its summary)"
        }
    }
}

// MARK: - Statistics

struct Stat {
    private(set) var min = Double.infinity
    private(set) var max = -Double.infinity
    private var weightedSum = 0.0
    private var weight = 0.0
    private(set) var last: Double?

    mutating func add(_ value: Double, weight w: Double = 1) {
        min = Swift.min(min, value); max = Swift.max(max, value)
        weightedSum += value * w; weight += w; last = value
    }

    var isEmpty: Bool { last == nil }

    var range: TrackReport.Range? {
        guard let last else { return nil }
        let avg = weight > 0 ? weightedSum / weight : last
        return .init(min: Proc.round1(min), avg: Proc.round1(avg), max: Proc.round1(max), last: Proc.round1(last))
    }

    var bytes: TrackReport.BytesRange? {
        guard let last else { return nil }
        let avg = weight > 0 ? weightedSum / weight : last
        return .init(min: UInt64(Swift.max(0, min)), avg: UInt64(Swift.max(0, avg.rounded())),
                     max: UInt64(Swift.max(0, max)), last: UInt64(Swift.max(0, last)))
    }
}

// MARK: - kqueue process watcher

/// Watches processes with kqueue `EVFILT_PROC` on a dedicated thread that sleeps in `kevent`
/// until something happens, so it costs nothing while watched processes are quiet. Each registration
/// carries a generation number in `udata`; an event whose generation no longer matches the instance
/// registered for that pid (the pid was reused and re-registered) is dropped.
/// The thread holds only the inner `Core`, so releasing the watcher (or `stop()`) ends the thread and
/// closes the kqueue.
final class ProcWatcher: @unchecked Sendable {
    typealias Handler = ([(key: Proc.Key, flags: UInt32)]) -> Void
    static let maxWatched = 512

    private final class Core: @unchecked Sendable {
        let kq: Int32
        let lock = NSLock()
        var stopped = false
        var registered: [Int32: (key: Proc.Key, generation: UInt)] = [:]
        var nextGeneration: UInt = 1
        let handler: Handler
        init(kq: Int32, handler: @escaping Handler) { self.kq = kq; self.handler = handler }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            var ev = Darwin.kevent(ident: 1, filter: Int16(EVFILT_USER), flags: 0,
                                   fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
            _ = kevent(kq, &ev, 1, nil, 0, nil)
        }

        func loop() {
            var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 128)
            outer: while true {
                let n = kevent(kq, nil, 0, &events, Int32(events.count), nil)
                if n < 0 { if errno == EINTR { continue }; break }
                var batch: [(key: Proc.Key, flags: UInt32)] = []
                lock.lock()
                for e in events.prefix(Int(n)) {
                    if e.filter == Int16(EVFILT_USER) { lock.unlock(); break outer }
                    guard e.filter == Int16(EVFILT_PROC) else { continue }
                    let pid = Int32(truncatingIfNeeded: e.ident)
                    let generation = UInt(bitPattern: e.udata)
                    guard let r = registered[pid], r.generation == generation else { continue }
                    if e.fflags & UInt32(NOTE_EXIT) != 0 { registered[pid] = nil }
                    batch.append((r.key, e.fflags))
                }
                lock.unlock()
                if !batch.isEmpty { handler(batch) }
            }
            close(kq)
        }
    }

    private let core: Core

    init?(handler: @escaping Handler) {
        let kq = kqueue()
        guard kq >= 0 else { return nil }
        var wake = Darwin.kevent(ident: 1, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR),
                                 fflags: 0, data: 0, udata: nil)
        guard kevent(kq, &wake, 1, nil, 0, nil) == 0 else { close(kq); return nil }
        let core = Core(kq: kq, handler: handler)
        self.core = core
        let thread = Thread { core.loop() }
        thread.name = "aistats.kqueue"
        // Prompt wakeups keep fork notifications from coalescing; the thread only runs on events.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { core.stop() }

    var count: Int { core.lock.lock(); defer { core.lock.unlock() }; return core.registered.count }

    /// False if the process is gone, can't be watched, or the watch limit is reached.
    func watch(_ key: Proc.Key, forks: Bool) -> Bool {
        let c = core
        c.lock.lock(); defer { c.lock.unlock() }
        guard !c.stopped else { return false }
        if c.registered[key.pid]?.key == key { return true }
        guard c.registered[key.pid] != nil || c.registered.count < Self.maxWatched else { return false }
        var flags = UInt32(NOTE_EXIT) | UInt32(NOTE_EXEC)
        if forks { flags |= UInt32(NOTE_FORK) }
        let generation = c.nextGeneration
        c.nextGeneration &+= 1
        if c.nextGeneration == 0 { c.nextGeneration = 1 }
        var ev = Darwin.kevent(ident: UInt(key.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_CLEAR),
                               fflags: flags, data: 0, udata: UnsafeMutableRawPointer(bitPattern: generation))
        guard kevent(c.kq, &ev, 1, nil, 0, nil) == 0 else { return false }
        // The registration is for the process that has this pid now; confirm it is the instance we mean.
        guard Proc.isAlive(key) else {
            var del = Darwin.kevent(ident: UInt(key.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_DELETE),
                                    fflags: 0, data: 0, udata: nil)
            _ = kevent(c.kq, &del, 1, nil, 0, nil)
            c.registered[key.pid] = nil
            return false
        }
        c.registered[key.pid] = (key, generation)
        return true
    }

    func unwatch(_ key: Proc.Key) {
        let c = core
        c.lock.lock(); defer { c.lock.unlock() }
        guard c.registered[key.pid]?.key == key, !c.stopped else { return }
        c.registered[key.pid] = nil
        var ev = Darwin.kevent(ident: UInt(key.pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_DELETE),
                               fflags: 0, data: 0, udata: nil)
        _ = kevent(c.kq, &ev, 1, nil, 0, nil)
    }

    func stop() { core.stop() }

    /// The object the kqueue thread holds; it is released when the thread has ended (tests).
    var threadState: AnyObject { core }
}

// MARK: - One track

final class ProcessTrack {
    final class Member {
        let key: Proc.Key
        var name: String
        var path: String?
        let isRoot: Bool
        var exitedAt: Date?
        var prevCpuNs: UInt64?
        var prevNs: UInt64?
        var cpu = Stat()
        var footprint = Stat()
        var lifetimeMax: UInt64 = 0
        let order: Int
        init(key: Proc.Key, name: String, path: String?, isRoot: Bool, order: Int) {
            self.key = key; self.name = name; self.path = path; self.isRoot = isRoot; self.order = order
        }
    }

    struct Root {
        var startedAt: Date
        var exitedAt: Date?
        var order: Int
        /// Uptime ns of the start and of the moment the exit was seen (an upper bound of the real exit).
        var startNs: UInt64
        var exitedNs: UInt64?
    }

    static let discoveryInterval: UInt64 = 5_000_000_000
    static let maxMembers = 128
    /// Instances kept for the report; older exited ones only count.
    static let maxRoots = 64
    static let spikeCaptureInterval: UInt64 = 30_000_000_000
    static let sampleInterval: UInt64 = 300_000_000_000
    static let persistInterval: UInt64 = 15_000_000_000
    static let childPollInterval: UInt64 = 250_000_000
    static let maxForkListingsPerRun = 4
    /// A reading taken this long after the end of the track is not counted.
    static let endSlack: UInt64 = 500_000_000

    /// Name/path rescans happen at most this often (tests shorten it).
    var discoveryInterval = ProcessTrack.discoveryInterval
    var spikeCaptureInterval = ProcessTrack.spikeCaptureInterval
    var maxMembers = ProcessTrack.maxMembers

    let id: String
    let options: TrackOptions
    let startedAt = Date()
    let startNs = Proc.nowNs()
    var endNs: UInt64 { startNs + UInt64(options.durationSeconds) * 1_000_000_000 }
    let queue: DispatchQueue
    let directory: ProcessDirectory
    let home: URL
    let sampleExecutable: String
    var onTick: ((TrackTickRow) -> Void)?
    var onFinish: ((TrackReport) -> Void)?

    private(set) var state = "running"
    private(set) var endReason: String?
    private(set) var endedAt: Date?

    private var roots: [Proc.Key: Root] = [:]
    private var rootsSeen = 0
    private var discoveredOnce = false
    private var restarts = 0
    private var additionalInstances = 0
    private(set) var members: [Proc.Key: Member] = [:]
    private var memberOrder = 0
    /// Distinct instances admitted as members, and refused because of the member limit.
    private var membersAdmitted = 0
    private var membersDropped = 0
    private var refused = Set<Proc.Key>()
    /// argsContain: pids that matched by name/path but whose arguments couldn't be read (capped).
    private var argsUnreadable = Set<Int32>()
    private var lifetimePeak: UInt64 = 0
    private var lastTickNs: UInt64?
    private var lastDiscoveryNs: UInt64?
    private var lastPersistNs: UInt64 = 0
    private var aggCPU = Stat()
    private var aggFootprint = Stat()
    private var validSamples = 0
    private var events: [TrackReport.Event] = []
    private var eventsTotal = 0
    private var spikes: [TrackReport.Spike] = []
    private var spikesTotal = 0
    private var spikesRateLimited = 0
    private var lastThreadCaptureNs: UInt64?
    private var lastSampleNs: UInt64?
    private var notes: [String] = []

    // `sample` captures in flight, by spike id: cancelled and accounted for when the track ends.
    private var captures: [Int: CancelToken] = [:]
    let captureGroup = DispatchGroup()

    // Child spawn accounting.
    private var watcher: ProcWatcher?
    private var kqueueWorks = false
    private var forks = 0
    private var forkBuckets: [Int] = []
    private var attributed = 0
    private var byExecutable: [String: Int] = [:]
    /// Children seen but not yet exited; attributed to their executable when they exit or exec.
    private var inflight: [Proc.Key: String] = [:]
    private var knownChildren = Set<Proc.Key>()
    private var forkedParents: [Proc.Key] = []
    private var forkedParentSet = Set<Proc.Key>()
    private var lastRootPollNs: UInt64 = 0
    private var candidates = Set<Proc.Key>()

    private var timer: DispatchSourceTimer?
    private var endTimer: DispatchSourceTimer?
    private var childTimer: DispatchSourceTimer?

    init(id: String, options: TrackOptions, queue: DispatchQueue, directory: ProcessDirectory, home: URL, sampleExecutable: String) {
        self.id = id; self.options = options; self.queue = queue; self.directory = directory
        self.home = home; self.sampleExecutable = sampleExecutable
    }

    var isRunning: Bool { state == "running" }
    var watcherThreadState: AnyObject? { watcher?.threadState }

    /// A track released without `finish` (its manager went away) still stops its timers, kqueue thread
    /// and captures.
    deinit {
        timer?.cancel(); endTimer?.cancel(); childTimer?.cancel()
        watcher?.stop()
        captures.values.forEach { $0.cancel() }
    }

    // MARK: Lifecycle (call on `queue`)

    func begin(rootUsage: Proc.Usage?) {
        watcher = ProcWatcher { [weak self] batch in
            guard let self else { return }
            self.queue.async { self.handle(batch) }
        }
        if case .pid(let pid, _) = options.selector, let u = rootUsage {
            addRoot(Proc.Key(pid: pid, start: u.start), name: Proc.name(pid) ?? "pid \(pid)", path: nil, usage: u)
            discoveredOnce = true
        }
        tick()
        guard isRunning else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(options.intervalSeconds * 1000))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(options.intervalSeconds * 100)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        // The end does not wait for the next sampling tick.
        let e = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        e.schedule(deadline: DispatchTime(uptimeNanoseconds: endNs), leeway: .milliseconds(20))
        e.setEventHandler { [weak self] in self?.tick() }
        e.resume()
        endTimer = e
        if options.includeChildren {
            let c = DispatchSource.makeTimerSource(queue: queue)
            c.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
            c.setEventHandler { [weak self] in self?.pollChildren() }
            c.resume()
            childTimer = c
        }
    }

    func finish(state newState: String, reason: String) {
        guard isRunning else { return }
        state = newState
        endReason = reason
        endedAt = Date()
        timer?.cancel(); timer = nil
        endTimer?.cancel(); endTimer = nil
        childTimer?.cancel(); childTimer = nil
        watcher?.stop(); watcher = nil
        // Children still running are attributed to what they run now.
        for (_, name) in inflight { byExecutable[name, default: 0] += 1 }
        inflight.removeAll()
        // Captures still running are stopped; their result (if any) arrives later and is saved then.
        for (spikeID, token) in captures {
            token.cancel()
            if let i = spikes.firstIndex(where: { $0.id == spikeID }), spikes[i].sampleTopFrames == nil, spikes[i].sampleError == nil {
                spikes[i].sampleError = "sample capture cancelled: the track ended"
                spikes[i].sampleFile = nil
            }
        }
        let report = self.report()
        persist(report)
        onFinish?(report)
        onFinish = nil
        onTick = nil
    }

    // MARK: Sampling

    func tick() {
        guard isRunning else { return }
        let now = Proc.nowNs()
        if now > endNs &+ Self.endSlack {
            // Late (the Mac was busy): readings from after the end don't belong to this track.
            finish(state: "ended", reason: "duration_elapsed")
            return
        }
        discover(now: now)

        let dt = lastTickNs.map { Double(now &- $0) / 1e9 }
        var cpuSum = 0.0, anyCPU = false, footprintSum: UInt64 = 0, anyRead = false
        for m in members.values where m.exitedAt == nil {
            guard let u = Proc.usage(m.key.pid), u.start == m.key.start else {
                memberExited(m, at: Date())
                continue
            }
            // Time the reading itself: if this thread is preempted mid-tick, a timestamp taken at
            // the start of the tick would make the CPU delta look too large.
            let t = Proc.nowNs()
            anyRead = true
            refreshIdentity(m)
            var cpu: Double?
            if let pc = m.prevCpuNs, let pn = m.prevNs, t > pn, u.cpuNs >= pc {
                cpu = Double(u.cpuNs - pc) / Double(t - pn) * 100
            } else if m.prevNs == nil, let last = lastTickNs, u.startNs >= last, t > last {
                // Born since the previous tick: all of its CPU time falls inside this interval.
                cpu = Double(u.cpuNs) / Double(t - last) * 100
            }
            let weight = m.prevNs.map { Double(t &- $0) / 1e9 } ?? dt ?? 0
            m.prevCpuNs = u.cpuNs
            m.prevNs = t
            if let cpu {
                m.cpu.add(cpu, weight: weight)
                cpuSum += cpu
                anyCPU = true
                if cpu >= options.spikeCpuPercent { spike(m, cpu: cpu, now: now) }
            }
            m.footprint.add(Double(u.footprint))
            m.lifetimeMax = max(m.lifetimeMax, u.lifetimeMaxFootprint)
            lifetimePeak = max(lifetimePeak, u.lifetimeMaxFootprint)
            footprintSum &+= u.footprint
        }
        if anyCPU, let dt, dt > 0 {
            aggCPU.add(cpuSum, weight: dt)
            validSamples += 1
        }
        if anyRead { aggFootprint.add(Double(footprintSum)) }
        lastTickNs = now
        pruneKnownChildren()

        if let onTick {
            onTick(TrackTickRow(t: Date(), cpuPercent: anyCPU ? Proc.round1(cpuSum) : nil,
                                footprintBytes: anyRead ? footprintSum : nil,
                                liveMembers: members.values.filter { $0.exitedAt == nil }.count,
                                forks: options.includeChildren ? forks : nil))
        }

        if case .pid = options.selector, !roots.isEmpty, roots.values.allSatisfy({ $0.exitedAt != nil }) {
            finish(state: "ended", reason: "target_exited")
            return
        }
        if Proc.nowNs() >= endNs {
            finish(state: "ended", reason: "duration_elapsed")
            return
        }
        if now &- lastPersistNs >= Self.persistInterval {
            lastPersistNs = now
            persist(report())
        }
    }

    /// Picks up an exec the watcher may have missed: a new name, or (path tracks) a new path.
    private func refreshIdentity(_ m: Member) {
        if let name = Proc.name(m.key.pid), name != m.name {
            execed(m, newName: name)
        } else if options.selector.isPath {
            let path = Proc.path(m.key.pid)
            let allowed = path.flatMap { options.selector.matches(name: m.name, path: $0) ? $0 : nil }
            if allowed != m.path { execed(m, newName: m.name) }
        }
    }

    /// The member ran exec: same instance, maybe another program. Only a process whose executable still
    /// matches a path selector may carry a path.
    private func execed(_ m: Member, newName: String) {
        directory.invalidate(m.key.pid)
        if newName != m.name {
            addEvent("exec", pid: m.key.pid, name: newName, detail: "was \(m.name)")
            m.name = newName
        }
        if options.selector.isPath {
            let path = Proc.path(m.key.pid)
            m.path = path.flatMap { options.selector.matches(name: newName, path: $0) ? $0 : nil }
        }
    }

    private func discover(now: UInt64) {
        let needScan: Bool
        switch options.selector {
        case .pid: needScan = options.includeChildren
        case .name, .path: needScan = true
        }
        if needScan, lastDiscoveryNs.map({ now &- $0 >= discoveryInterval }) ?? true {
            lastDiscoveryNs = now
            if let rows = directory.scan(refreshPath: options.selector.pathRefreshFilter) {
                scanTable(rows)
            } else {
                note("process table could not be read; discovery skipped")
            }
        }
        if !candidates.isEmpty {
            for key in candidates where members[key] == nil {
                // Admit only the instance that was listed, not whatever has that pid now.
                guard Proc.isAlive(key), let name = Proc.name(key.pid) else { continue }
                addMember(key, name: name, isRoot: false, path: Proc.path(key.pid))
            }
            candidates.removeAll()
        }
    }

    private func scanTable(_ rows: [ProcessDirectory.Row]) {
        let parentOf = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        // Ancestry only counts live, verified instances (a stale root must not adopt a reused pid).
        for (key, r) in roots where r.exitedAt == nil && !Proc.isAlive(key) {
            if let m = members[key] { memberExited(m, at: Date()) } else { roots[key]?.exitedAt = Date(); roots[key]?.exitedNs = Proc.nowNs() }
        }
        var livePids = Set(members.values.filter { $0.exitedAt == nil }.map(\.key.pid))
        let rootPids = Set(roots.filter { $0.value.exitedAt == nil }.map(\.key.pid))

        if case .pid = options.selector {} else {
            let picked = directory.select(rows, options.selector)
            for r in picked.argsUnreadable where argsUnreadable.count < 4096 { argsUnreadable.insert(r.pid) }
            let matched = picked.rows
            let matchedPids = Set(matched.map(\.pid))
            for r in matched {
                guard let u = Proc.usage(r.pid) else { continue }
                let key = Proc.Key(pid: r.pid, start: u.start)
                if roots[key] != nil || members[key] != nil || refused.contains(key) { continue }
                // A match that descends from another match is part of that instance, not a new one.
                var ancestor = parentOf[r.pid], steps = 0, nested = false
                while let a = ancestor, a > 1, steps < 64 {
                    if rootPids.contains(a) || matchedPids.contains(a) { nested = true; break }
                    ancestor = parentOf[a]; steps += 1
                }
                let admitted = nested ? addMember(key, name: r.name, isRoot: false, path: r.path)
                                      : addRoot(key, name: r.name, path: r.path, usage: u)
                if admitted { livePids.insert(r.pid) }
            }
            discoveredOnce = true
        }

        guard options.includeChildren else { return }
        // Descendants of live members, breadth-first over the parent links.
        var childrenOf: [Int32: [Int32]] = [:]
        for r in rows { childrenOf[r.ppid, default: []].append(r.pid) }
        var frontier = Array(livePids), seen = livePids
        while let p = frontier.popLast() {
            for c in childrenOf[p] ?? [] where !seen.contains(c) {
                seen.insert(c)
                frontier.append(c)
                if let u = Proc.usage(c) { candidates.insert(Proc.Key(pid: c, start: u.start)) }
            }
        }
    }

    /// Records a matched instance. Returns false (and records nothing but the drop) at the member limit.
    @discardableResult
    private func addRoot(_ key: Proc.Key, name: String, path: String?, usage: Proc.Usage) -> Bool {
        guard makeRoom(for: key) else { return false }
        let started = Date(timeIntervalSinceNow: -Double(Proc.nowNs() &- usage.startNs) / 1e9)
        // Judged by when the new instance started, not when we noticed it: it overlapped an earlier
        // instance if that one was still running (or not yet seen to exit) at its start.
        let overlapped = roots.values.contains { r in r.exitedNs.map { $0 > usage.startNs } ?? true }
        let kind: String
        if !discoveredOnce || rootsSeen == 0 {
            kind = "start"
        } else if overlapped {
            additionalInstances += 1
            kind = "instance_start"
        } else {
            restarts += 1
            kind = "restart"
        }
        rootsSeen += 1
        roots[key] = Root(startedAt: started, exitedAt: nil, order: rootsSeen, startNs: usage.startNs, exitedNs: nil)
        if roots.count > Self.maxRoots,
           let oldest = roots.filter({ $0.value.exitedAt != nil }).min(by: { $0.value.order < $1.value.order }) {
            roots[oldest.key] = nil
        }
        addEvent(kind, pid: key.pid, name: name)
        return addMember(key, name: name, isRoot: true, path: path)
    }

    /// At the member limit, forgets the oldest exited member (its figures stay in the totals); false if
    /// every member is live, counting the refused instance once.
    private func makeRoom(for key: Proc.Key) -> Bool {
        guard members[key] == nil, members.count >= maxMembers else { return true }
        if let victim = members.values.filter({ $0.exitedAt != nil }).min(by: { $0.order < $1.order }) {
            members[victim.key] = nil
            return true
        }
        if refused.count < 4096, refused.insert(key).inserted { membersDropped += 1 }
        note("member limit (\(maxMembers) live processes) reached; further instances are counted but not measured")
        return false
    }

    @discardableResult
    private func addMember(_ key: Proc.Key, name: String, isRoot: Bool, path: String? = nil) -> Bool {
        guard members[key] == nil else { return true }
        guard makeRoom(for: key) else { return false }
        memberOrder += 1
        membersAdmitted += 1
        // A path is reported only for a process whose executable matches the path selector.
        var shownPath: String?
        if options.selector.isPath, let p = path ?? Proc.path(key.pid), options.selector.matches(name: name, path: p) { shownPath = p }
        let m = Member(key: key, name: name, path: shownPath, isRoot: isRoot, order: memberOrder)
        members[key] = m
        if !isRoot {
            addEvent("child_start", pid: key.pid, name: name)
            noteChild(key, name: name)
        }
        if let watcher, watcher.watch(key, forks: options.includeChildren) { kqueueWorks = true }
        return true
    }

    private func memberExited(_ m: Member, at date: Date) {
        guard m.exitedAt == nil else { return }
        m.exitedAt = date
        if m.isRoot, var r = roots[m.key] {
            r.exitedAt = date
            r.exitedNs = Proc.nowNs()
            roots[m.key] = r
            addEvent("exit", pid: m.key.pid, name: m.name)
        } else if !m.isRoot {
            addEvent("child_exit", pid: m.key.pid, name: m.name)
        }
        watcher?.unwatch(m.key)
    }

    // MARK: Child spawn accounting

    private func handle(_ batch: [(key: Proc.Key, flags: UInt32)]) {
        guard isRunning else { return }
        var rootExited = false
        for (key, flags) in batch {
            if flags & UInt32(NOTE_FORK) != 0 {
                forks += 1
                bumpBucket()
                if forkedParentSet.insert(key).inserted { forkedParents.append(key) }
            }
            if flags & UInt32(NOTE_EXEC) != 0 {
                directory.invalidate(key.pid)
                if inflight[key] != nil, Proc.isAlive(key), let name = Proc.name(key.pid) { inflight[key] = name }
                if let m = members[key], m.exitedAt == nil, Proc.isAlive(key) {
                    execed(m, newName: Proc.name(key.pid) ?? m.name)
                }
            }
            if flags & UInt32(NOTE_EXIT) != 0 {
                if let name = inflight.removeValue(forKey: key) { byExecutable[name, default: 0] += 1 }
                if let m = members[key], m.exitedAt == nil {
                    memberExited(m, at: Date())
                    if m.isRoot { rootExited = true }
                }
            }
        }
        if rootExited, case .pid = options.selector { tick() }
    }

    private func bumpBucket() {
        let minute = Int((Proc.nowNs() &- startNs) / 60_000_000_000)
        if forkBuckets.count <= minute { forkBuckets.append(contentsOf: repeatElement(0, count: minute - forkBuckets.count + 1)) }
        forkBuckets[minute] += 1
    }

    /// Lists children of processes that just forked (a few per run, since each listing walks the
    /// kernel process table) and of the roots every 250 ms, to attribute children to executables.
    private func pollChildren() {
        guard isRunning else { return }
        var parents: [Proc.Key] = []
        let take = min(Self.maxForkListingsPerRun, forkedParents.count)
        if take > 0 {
            parents = Array(forkedParents.prefix(take))
            forkedParents.removeFirst(take)
            parents.forEach { forkedParentSet.remove($0) }
        }
        let now = Proc.nowNs()
        if now &- lastRootPollNs >= Self.childPollInterval {
            lastRootPollNs = now
            for (key, r) in roots where r.exitedAt == nil && !parents.contains(key) { parents.append(key) }
        }
        for parent in parents.prefix(Self.maxForkListingsPerRun + 8) {
            // The parent must still be the instance that forked, or its children aren't ours.
            guard Proc.isAlive(parent) else { continue }
            let listed = Proc.children(of: parent.pid)
            // Listed by pid: the parent must still be the same instance after the listing.
            guard Proc.isAlive(parent) else { continue }
            for child in listed {
                // A child of this instance points at its pid and started after it.
                guard let u = Proc.usage(child), u.start >= parent.start, Proc.parent(child) == parent.pid,
                      Proc.isAlive(parent) else { continue }
                let key = Proc.Key(pid: child, start: u.start)
                if knownChildren.contains(key) || members[key] != nil { continue }
                // Watch first, then read the name: an exec after this point still reaches us.
                let watched = watcher?.watch(key, forks: true) ?? false
                if watched { kqueueWorks = true }
                let name = Proc.name(child) ?? "(exited)"
                noteChild(key, name: name, watched: watched)
                candidates.insert(key)
            }
        }
    }

    private func noteChild(_ key: Proc.Key, name: String, watched: Bool = true) {
        guard options.includeChildren, knownChildren.insert(key).inserted else { return }
        guard Proc.ns(key.start) >= startNs else { return } // existed before the track: not a spawn
        attributed += 1
        if watched, inflight.count < 1024 {
            inflight[key] = name
        } else {
            byExecutable[name, default: 0] += 1
        }
    }

    private func pruneKnownChildren() {
        guard knownChildren.count > 2048 else { return }
        knownChildren = knownChildren.filter { Proc.isAlive($0) }
    }

    // MARK: Spikes

    private func spike(_ m: Member, cpu: Double, now: UInt64) {
        spikesTotal += 1
        if let last = lastThreadCaptureNs, now &- last < spikeCaptureInterval {
            spikesRateLimited += 1
            return
        }
        // Capture only the instance that spiked, never a process that reused its pid.
        guard Proc.isAlive(m.key) else { return }
        lastThreadCaptureNs = now
        var threads = Proc.threads(m.key.pid)
        if threads != nil, !Proc.isAlive(m.key) { threads = nil }
        let omitted = threads.map { $0.total - $0.busiest.count }.flatMap { $0 > 0 ? $0 : nil }
        var s = TrackReport.Spike(t: Date(), pid: m.key.pid, name: m.name, cpuPercent: Proc.round1(cpu),
                                  threads: threads?.busiest, threadsOmitted: omitted,
                                  threadsUnreadable: threads == nil ? true : nil, id: spikesTotal)
        addEvent("spike", pid: m.key.pid, name: m.name, detail: String(format: "%.0f%% CPU", cpu))
        if options.sampleOnSpike, lastSampleNs.map({ now &- $0 >= Self.sampleInterval }) ?? true {
            lastSampleNs = now
            let dir = home.appendingPathComponent("samples", isDirectory: true)
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            let file = dir.appendingPathComponent("\(id)-\(m.key.pid)-\(f.string(from: Date())).txt")
            s.sampleFile = file.path
            let key = m.key, spikeID = s.id, tool = sampleExecutable
            let token = CancelToken()
            captures[spikeID] = token
            captureGroup.enter()
            let group = captureGroup
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let (frames, error) = SampleCapture.capture(key: key, file: file, tool: tool, cancel: token)
                group.leave()
                guard let self else { return }
                self.queue.async { self.captureFinished(spikeID, frames: frames, error: error) }
            }
        }
        spikes.append(s)
        if spikes.count > 3 { spikes.removeFirst(spikes.count - 3) }
    }

    private func captureFinished(_ spikeID: Int, frames: [String]?, error: String?) {
        captures[spikeID] = nil
        guard let i = spikes.firstIndex(where: { $0.id == spikeID }) else { return }
        spikes[i].sampleTopFrames = frames
        spikes[i].sampleError = error
        if error != nil { spikes[i].sampleFile = nil }
        // A track that already ended saved its summary before the capture finished: save it again.
        if !isRunning { persist(report()) }
    }

    // MARK: Report

    private func addEvent(_ kind: String, pid: Int32, name: String?, detail: String? = nil) {
        eventsTotal += 1
        events.append(.init(t: Date(), kind: kind, pid: pid, name: name, detail: detail))
        if events.count > 32 { events.removeFirst(events.count - 32) }
    }

    private func note(_ s: String) {
        if !notes.contains(s) { notes.append(s) }
    }

    func memberKeys() -> [Proc.Key] {
        members.values.filter { $0.exitedAt == nil }.map(\.key)
    }

    func report() -> TrackReport {
        let now = Proc.nowNs()
        let live = members.values.filter { $0.exitedAt == nil }
        let ordered = members.values.sorted {
            ($0.cpu.range?.avg ?? -1, $0.footprint.bytes?.max ?? 0, -$0.order) > ($1.cpu.range?.avg ?? -1, $1.footprint.bytes?.max ?? 0, -$1.order)
        }
        let shownMembers = ordered.prefix(5).map { m in
            // The lifetime peak only adds information when it is above what the track saw.
            TrackReport.Member(pid: m.key.pid, startToken: m.key.token, name: m.name, root: m.isRoot ? true : nil,
                               exited: m.exitedAt != nil ? true : nil, cpuPercent: m.cpu.range,
                               footprintBytes: m.footprint.bytes,
                               lifetimeMaxFootprintBytes: m.lifetimeMax > (m.footprint.bytes?.max ?? 0) ? m.lifetimeMax : nil,
                               path: m.path)
        }
        let rootList = roots.sorted { $0.value.order < $1.value.order }
        let shownRoots = rootList.suffix(3).map { k, r in
            TrackReport.Instance(pid: k.pid, startToken: k.token, startedAt: r.startedAt, exitedAt: r.exitedAt)
        }

        var spawn: TrackReport.Spawn?
        if options.includeChildren {
            var counts = byExecutable
            for (_, name) in inflight { counts[name, default: 0] += 1 }
            let sorted = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            var buckets = forkBuckets
            let elapsedMinutes = Int((min(now, endNs) &- startNs) / 60_000_000_000)
            if buckets.count <= elapsedMinutes { buckets.append(contentsOf: repeatElement(0, count: elapsedMinutes - buckets.count + 1)) }
            var bucketSeconds = 60
            while buckets.count > 60 {
                buckets = stride(from: 0, to: buckets.count, by: 2).map { buckets[$0] + ($0 + 1 < buckets.count ? buckets[$0 + 1] : 0) }
                bucketSeconds *= 2
            }
            spawn = .init(method: kqueueWorks || watcher != nil ? "kqueue+polling" : "polling", forks: forks, forksLowerBound: true,
                          childrenAttributed: attributed, unattributedForks: max(0, forks - attributed),
                          byExecutable: sorted.prefix(8).map { .init(name: $0.key, count: $0.value) },
                          executablesOmitted: max(0, sorted.count - 8), perMinuteStart: startedAt,
                          bucketSeconds: bucketSeconds, forksPerBucket: buckets)
        }

        var notes = self.notes
        if roots.isEmpty, isRunning { notes.append("no matching process yet; the track keeps looking every 5 s") }
        if options.includeChildren, watcher == nil, isRunning { notes.append("kqueue unavailable: fork counts are from polling only") }

        let elapsedEnd = endedAt.map { $0.timeIntervalSince(startedAt) } ?? Double(now &- startNs) / 1e9
        var restart: Int?, additional: Int?
        if case .pid = options.selector {} else { restart = restarts; additional = additionalInstances }
        let seen = membersAdmitted + membersDropped
        return TrackReport(
            trackId: id, state: state, endReason: endReason, selector: options.selector.kind,
            match: options.selector.matchMode, includeChildren: options.includeChildren, scope: "current_user",
            startedAt: startedAt, endsAt: startedAt.addingTimeInterval(Double(options.durationSeconds)), endedAt: endedAt,
            elapsedSeconds: Proc.round1(min(elapsedEnd, Double(options.durationSeconds) + Double(Self.endSlack) / 1e9)),
            durationSeconds: options.durationSeconds,
            intervalSeconds: options.intervalSeconds, validSamples: validSamples, restartCount: restart,
            additionalInstances: additional,
            instances: Array(shownRoots), instancesOmitted: nonZero(rootsSeen - shownRoots.count),
            aggregate: .init(cpuPercent: aggCPU.range, footprintBytes: aggFootprint.bytes,
                             largestProcessLifetimePeakBytes: lifetimePeak > 0 ? lifetimePeak : nil,
                             liveMembers: live.count, membersSeen: seen),
            members: Array(shownMembers), membersOmitted: nonZero(membersAdmitted - shownMembers.count),
            membersDropped: nonZero(membersDropped),
            events: Array(events.suffix(8)), eventsOmitted: nonZero(eventsTotal - min(8, events.count)),
            spikes: spikes, spikesOmitted: nonZero(spikesTotal - spikesRateLimited - spikes.count),
            spikesRateLimited: nonZero(spikesRateLimited),
            spawn: spawn, notes: notes.isEmpty ? nil : notes,
            argsFilter: options.selector.argsContain != nil ? true : nil,
            argsUnreadable: options.selector.argsContain != nil ? argsUnreadable.count : nil)
    }

    private func nonZero(_ n: Int) -> Int? { n > 0 ? n : nil }

    func persist(_ report: TrackReport) {
        TrackManager.save(report, home: home)
    }
}

// MARK: - `sample` capture

enum SampleCapture {
    static let maxFiles = 20

    /// Runs `sample <pid> 1 -file <file>` and returns up to 10 top-of-stack lines. The result is dropped
    /// if the process is no longer the instance `key` names (its pid was reused) or the run was cancelled.
    static func capture(key: Proc.Key, file: URL, tool: String, cancel: CancelToken? = nil) -> ([String]?, String?) {
        do {
            let dir = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard Proc.isAlive(key) else { return (nil, "process exited before the capture") }
            let r = try Subprocess.run(tool, [String(key.pid), "1", "-file", file.path], timeout: 20, cancel: cancel)
            defer { prune(dir) }
            if r.cancelled {
                try? FileManager.default.removeItem(at: file)
                return (nil, "sample capture cancelled: the track ended")
            }
            guard r.succeeded, let text = try? String(contentsOf: file, encoding: .utf8) else {
                try? FileManager.default.removeItem(at: file)
                let reason = r.timedOut ? "sample timed out" : (r.stderr.split(separator: "\n").first.map(String.init) ?? "sample failed (status \(r.status))")
                return (nil, String(reason.prefix(200)))
            }
            guard Proc.isAlive(key) else {
                try? FileManager.default.removeItem(at: file)
                return (nil, "process exited during the capture")
            }
            chmod(file.path, 0o600)
            return (topFrames(text), nil)
        } catch {
            return (nil, "\(error)")
        }
    }

    /// Keeps the newest `maxFiles` capture files (ours only: `trk-…-<pid>-<stamp>.txt`).
    static func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let ours = names.filter { $0.hasPrefix("trk-") && $0.hasSuffix(".txt") }.compactMap { name -> (String, Date)? in
            let url = dir.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
            return (name, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
        }
        for (name, _) in ours.sorted(by: { ($0.1, $0.0) > ($1.1, $1.0) }).dropFirst(maxFiles) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func topFrames(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) {
            let frames = lines[(i + 1)...].prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return frames.prefix(10).map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
        }
        if let i = lines.firstIndex(where: { $0.hasPrefix("Call graph:") }) {
            return lines[(i + 1)...].prefix(10).map { String($0.trimmingCharacters(in: .whitespaces).prefix(160)) }
        }
        return []
    }
}

// MARK: - Manager

/// Runs process tracks for one MCP session or CLI run. Timers only exist while a track runs,
/// so an idle manager does no work.
public final class TrackManager: @unchecked Sendable {
    public static let maxActive = 4
    public static let maxStoredReports = 50
    /// Finished tracks kept in memory; older ones are read back from disk.
    public static let maxFinishedInMemory = 16

    public let home: URL
    public var sampleExecutable = "/usr/bin/sample"
    /// How often name/path tracks rescan the process list.
    var discoveryInterval: UInt64 = ProcessTrack.discoveryInterval
    var spikeCaptureInterval: UInt64 = ProcessTrack.spikeCaptureInterval
    var maxMembers = ProcessTrack.maxMembers
    /// userInitiated, not utility: on a saturated Mac (exactly when tracking matters) utility work was
    /// starved for seconds, leaving gaps in the samples. Each tick is a few syscalls.
    let queue = DispatchQueue(label: "aistats.tracker", qos: .userInitiated)
    private var tracks: [String: ProcessTrack] = [:]
    private var finishedOrder: [String] = []
    private let directory = ProcessDirectory()

    public init(home: URL = AIStatsPaths.home) {
        self.home = home
    }

    /// Running tracks end (saved as stopped) when their manager goes away; their kqueue threads, timers
    /// and captures stop with them.
    deinit {
        let held = Array(tracks.values)
        queue.async {
            for t in held where t.isRunning { t.finish(state: "stopped", reason: "tracker_released") }
        }
    }

    /// Encoder userInfo flag: encoding for the summary file (keeps internal fields).
    static let persistingKey = CodingUserInfoKey(rawValue: "aistats.persisting")!

    static let fileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.userInfo[persistingKey] = true
        return e
    }()

    public func start(_ options: TrackOptions, onTick: ((TrackTickRow) -> Void)? = nil,
                      onFinish: ((TrackReport) -> Void)? = nil) throws -> TrackReport {
        try queue.sync {
            guard tracks.values.filter(\.isRunning).count < Self.maxActive else { throw TrackError.tooManyActive }
            var rootUsage: Proc.Usage?
            if case .pid(let pid, let token) = options.selector {
                guard let u = Proc.usage(pid) else {
                    throw TrackError.targetNotVisible(Proc.exists(pid)
                        ? "pid \(pid) is owned by another user; its usage can't be read without root"
                        : "no process with pid \(pid)")
                }
                if let token, token != String(u.start) {
                    throw TrackError.targetNotVisible("pid \(pid) was reused: startToken differs, the original process exited")
                }
                rootUsage = u
            }
            let id = "trk-" + UUID().uuidString.prefix(8).lowercased()
            let track = ProcessTrack(id: id, options: options, queue: queue, directory: directory, home: home,
                                     sampleExecutable: sampleExecutable)
            track.onTick = onTick
            track.onFinish = { [weak self] r in
                self?.trackFinished(id)
                onFinish?(r)
            }
            track.discoveryInterval = discoveryInterval
            track.spikeCaptureInterval = spikeCaptureInterval
            track.maxMembers = maxMembers
            tracks[id] = track
            track.begin(rootUsage: rootUsage)
            let report = track.report()
            if track.isRunning { track.persist(report) }
            return report
        }
    }

    /// On `queue`: remembers finish order and drops the oldest finished tracks from memory.
    private func trackFinished(_ id: String) {
        finishedOrder.append(id)
        while finishedOrder.count > Self.maxFinishedInMemory {
            let old = finishedOrder.removeFirst()
            tracks[old] = nil
        }
    }

    /// In-session tracks first; otherwise the summary saved by whichever session ran it.
    public func status(_ id: String) -> TrackReport? {
        if let r = queue.sync(execute: { tracks[id]?.report() }) { return r }
        return Self.load(id, home: home)
    }

    /// Stops a track of this session. Throws for a track that exists only on disk (another session's,
    /// or one this session no longer holds), so the caller isn't told a stop happened when it didn't.
    public func stop(_ id: String) throws -> TrackReport {
        if let r = queue.sync(execute: { () -> TrackReport? in
            guard let t = tracks[id] else { return nil }
            t.finish(state: "stopped", reason: "stopped_by_caller")
            return t.report()
        }) {
            return r
        }
        if let stored = Self.load(id, home: home) { throw TrackError.notInSession(id: id, state: stored.state) }
        throw TrackError.notFound(id)
    }

    /// Ends every running track and waits (up to `captureWait`) for `sample` captures to be reaped, so the
    /// saved summaries are final before the process exits.
    public func stopAll(reason: String, captureWait: TimeInterval = 3) {
        let groups = queue.sync { () -> [DispatchGroup] in
            var groups: [DispatchGroup] = []
            for t in tracks.values {
                if t.isRunning { t.finish(state: "stopped", reason: reason) }
                groups.append(t.captureGroup)
            }
            return groups
        }
        let end = DispatchTime.now() + captureWait
        for g in groups { _ = g.wait(timeout: end) }
        queue.sync {}
    }

    public var activeCount: Int { queue.sync { tracks.values.filter(\.isRunning).count } }

    /// What each held track's kqueue thread holds (tests check these are released).
    func watcherThreadStates() -> [AnyObject] { queue.sync { tracks.values.compactMap { $0.watcherThreadState } } }

    /// Tracks held in memory (running and recently finished).
    var heldCount: Int { queue.sync { tracks.count } }

    /// Live member instances of a running track in this session, for `wait_for`. Nil if the track is not
    /// running in this session.
    public func memberKeys(_ id: String) -> [Proc.Key]? {
        queue.sync { tracks[id].flatMap { $0.isRunning ? $0.memberKeys() : nil } }
    }

    public func list(limit: Int = 10) -> [TrackListRow] {
        let session = queue.sync {
            tracks.values.map { t -> TrackListRow in
                let r = t.report()
                return TrackListRow(trackId: r.trackId, state: r.state, selector: r.selector, startedAt: r.startedAt,
                                    endedAt: r.endedAt, inThisSession: true)
            }
        }
        let ids = Set(session.map(\.trackId))
        let stored = Self.storedIDs(home: home).filter { !ids.contains($0) }.prefix(limit).compactMap { id -> TrackListRow? in
            guard let r = Self.load(id, home: home) else { return nil }
            return TrackListRow(trackId: r.trackId, state: r.state, selector: r.selector, startedAt: r.startedAt,
                                endedAt: r.endedAt, inThisSession: false)
        }
        return Array((session.sorted { $0.startedAt > $1.startedAt } + stored).prefix(limit))
    }

    // MARK: Persistence

    static func tracksDir(_ home: URL) -> URL { home.appendingPathComponent("tracks", isDirectory: true) }

    static func isValidID(_ id: String) -> Bool {
        id.count <= 32 && id.hasPrefix("trk-") && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }

    /// On disk the report carries the pid of the session that runs it, to spot tracks whose session died.
    struct Stored: Codable { var sessionPid: Int32; var report: TrackReport }

    static func save(_ report: TrackReport, home: URL) {
        let dir = tracksDir(home)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? fileEncoder.encode(Stored(sessionPid: getpid(), report: report)) else { return }
        let url = dir.appendingPathComponent(report.trackId + ".json")
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        if report.state != "running" { pruneStored(home: home) }
    }

    public static func load(_ id: String, home: URL = AIStatsPaths.home) -> TrackReport? {
        guard isValidID(id), let stored = loadStored(id, home: home) else { return nil }
        var r = stored.report
        if r.state == "running", !ActivityStore.isAlive(stored.sessionPid) {
            r.state = "interrupted"
            r.endReason = "the session running this track ended before it finished"
        }
        return r
    }

    static func loadStored(_ id: String, home: URL) -> Stored? {
        guard let data = try? Data(contentsOf: tracksDir(home).appendingPathComponent(id + ".json")) else { return nil }
        return try? JSONLinesFile.decoder.decode(Stored.self, from: data)
    }

    static func storedIDs(home: URL) -> [String] {
        let dir = tracksDir(home)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" && isValidID($0.deletingPathExtension().lastPathComponent) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0.deletingPathExtension().lastPathComponent }
    }

    /// Keeps the newest `maxStoredReports` summaries, never removing one that a live session is still running.
    static func pruneStored(home: URL) {
        let ids = storedIDs(home: home)
        guard ids.count > maxStoredReports else { return }
        for id in ids.dropFirst(maxStoredReports) {
            try? TrackDelta.withStoreLock(home, exclusive: true) {
                if let s = loadStored(id, home: home), s.report.state == "running", ActivityStore.isAlive(s.sessionPid) { return }
                try FileManager.default.removeItem(at: tracksDir(home).appendingPathComponent(id + ".json"))
                let index = TrackDelta.directory(id, home: home)
                try? FileManager.default.removeItem(at: index.appendingPathComponent("index.json"))
                rmdir(index.path)
            }
        }
    }
}
