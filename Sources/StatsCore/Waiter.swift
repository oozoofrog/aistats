import Darwin
import Foundation

/// `wait_for`: block (asynchronously) until a condition holds or a timeout passes.
public enum WaitCondition: Sendable {
    public enum Scope: Sendable {
        case system
        case track(String)
        case selector(ProcessSelector)
    }
    case cpuIdle(Scope, belowPercent: Double)
    case processExit(pid: Int32, startToken: String?)
    case portListening(UInt16)
    case memoryPressureNormal

    public var name: String {
        switch self {
        case .cpuIdle: return "cpu_idle"
        case .processExit: return "process_exit"
        case .portListening: return "port_listening"
        case .memoryPressureNormal: return "memory_pressure_normal"
        }
    }
}

public struct WaitResult: Codable, Sendable {
    public struct Observation: Codable, Sendable {
        public var at: Date
        /// cpu_idle: system-wide percent of all cores, or percent of one core summed over the processes.
        public var cpuPercent: Double?
        public var memoryPressure: String?
        public var portListening: Bool?
        public var processAlive: Bool?
        public var valid: Bool
    }

    public struct Culprit: Codable, Sendable {
        public var startToken: String?
        public var ppid: Int32?
        public var pid: Int32
        public var name: String
        /// Average over the wait, percent of one core.
        public var cpuPercent: Double
    }

    /// "met", "timed_out" or "unavailable".
    public var state: String
    public var condition: String
    public var scope: String?
    public var thresholdPercent: Double?
    public var elapsedSeconds: Double
    public var timeoutSeconds: Double
    public var lastObservation: Observation?
    public var processes: [FindResult.Row]?
    public var matched: Int?
    public var culprits: [Culprit]?
    public var reason: String?
    /// cpu_idle with argsContain: processes that matched by name/path but whose arguments couldn't be read
    /// (not counted as matches).
    public var argsUnreadable: Int?

    public var summaryLine: String {
        var s = "\(condition) \(state.replacingOccurrences(of: "_", with: " ")) after \(String(format: "%.1f", elapsedSeconds))s"
        if let o = lastObservation {
            if let c = o.cpuPercent { s += String(format: ", last CPU %.1f%%", c) }
            if let p = o.memoryPressure { s += ", pressure \(p)" }
            if let a = o.processAlive { s += a ? ", process still running" : ", process exited" }
        }
        if let c = culprits, !c.isEmpty {
            s += "; busiest: " + c.map { String(format: "%@ (pid %d) %.0f%%", $0.name, $0.pid, $0.cpuPercent) }.joined(separator: ", ")
        }
        if let r = reason { s += " — \(r)" }
        return s
    }
}

public final class Waiter: @unchecked Sendable {
    public static let timeoutRange = 1.0...55.0
    public static let requiredConsecutive = 2

    public let condition: WaitCondition
    public let timeout: TimeInterval
    private let tracks: TrackManager?
    private let queue = DispatchQueue(label: "aistats.wait", qos: .userInitiated)
    /// Sampling period override (tests: a period far past the timeout shows the deadline timer ends the wait).
    var tickPeriod: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var deadlineTimer: DispatchSourceTimer?
    private var completion: ((WaitResult) -> Void)?
    private var startNs: UInt64 = 0
    private var deadlineNs: UInt64 = 0
    private var startDate = Date()
    private var consecutive = 0
    private var last: WaitResult.Observation?
    /// Why the latest observation was not valid, reported if the wait ends without a valid one.
    private var invalidReason: String?

    // CPU state.
    private var prevTicks: SystemSampler.CPUTicks?
    private var prevGroup: [Proc.Key: (cpuNs: UInt64, at: UInt64)] = [:]
    private var prevGroupNs: UInt64?
    private var baseline: [Proc.Key: UInt64] = [:]
    private let directory = ProcessDirectory()
    private var selectorKeys: [Proc.Key] = []
    /// Pids that matched by name/path but whose arguments couldn't be read (argsContain only).
    private var argsUnreadable = Set<Int32>()
    private var lastSelectorScanNs: UInt64?
    /// cpu_idle on a pid: the one instance (pid + start time) being watched.
    private var pidKey: Proc.Key?
    /// cpu_idle on a group: whether any process ever matched.
    private var everMatched = false
    private var portResult: FindResult?
    private var exitKey: Proc.Key?

    public init(condition: WaitCondition, timeout: TimeInterval, tracks: TrackManager? = nil) {
        self.condition = condition
        self.timeout = min(Self.timeoutRange.upperBound, max(Self.timeoutRange.lowerBound, timeout))
        self.tracks = tracks
    }

    /// Calls `completion` once on a background queue, unless `cancel()` comes first. The timeout is a
    /// timer of its own, so the result never waits for the next sampling tick.
    public func start(completion: @escaping (WaitResult) -> Void) {
        queue.async { [self] in
            self.completion = completion
            startNs = Proc.nowNs()
            deadlineNs = startNs + UInt64(timeout * 1e9)
            startDate = Date()
            if let why = prepare() {
                finish("unavailable", reason: why)
                return
            }
            if case .portListening = condition {
                tick()
                guard self.completion != nil else { return }
            }
            let period: DispatchTimeInterval
            if let p = tickPeriod { period = .milliseconds(Int(p * 1000)) }
            else if case .portListening = condition { period = .milliseconds(450) }
            else if case .processExit = condition { period = .milliseconds(250) } else { period = .seconds(1) }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            let d = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            d.schedule(deadline: DispatchTime(uptimeNanoseconds: deadlineNs), leeway: .milliseconds(10))
            d.setEventHandler { [weak self] in self?.timedOut() }
            d.resume()
            deadlineTimer = d
        }
    }

    public func cancel() {
        queue.async { [self] in
            completion = nil
            stopTimers()
        }
    }

    /// Blocking variant for the CLI and tests.
    public func run() -> WaitResult {
        let done = DispatchSemaphore(value: 0)
        var result: WaitResult?
        start { result = $0; done.signal() }
        done.wait()
        return result!
    }

    private func stopTimers() {
        timer?.cancel(); timer = nil
        deadlineTimer?.cancel(); deadlineTimer = nil
    }

    // MARK: Steps

    private var scopeName: String? {
        guard case .cpuIdle(let scope, _) = condition else { return nil }
        switch scope {
        case .system: return "system"
        case .track: return "track"
        case .selector(let s): return s.kind
        }
    }

    private func prepare() -> String? {
        switch condition {
        case .processExit(let pid, let token):
            guard let u = Proc.usage(pid) else {
                return Proc.exists(pid) ? "pid \(pid) is owned by another user and can't be watched without root"
                                        : "no process with pid \(pid) at the start of the wait"
            }
            if let token, token != String(u.start) { return "pid \(pid) was reused: startToken differs, the original process already exited" }
            exitKey = Proc.Key(pid: pid, start: u.start)
            return nil
        case .memoryPressureNormal, .portListening:
            return nil
        case .cpuIdle(let scope, _):
            switch scope {
            case .system:
                prevTicks = SystemSampler.readCPUTicks()
                guard prevTicks != nil else { return "CPU counters could not be read" }
                baseline = Self.userProcessCPU()
            case .track(let id):
                guard let keys = tracks?.memberKeys(id) else { return "no running track \(id) in this session" }
                primeGroup(keys)
            case .selector(let selector):
                if case .pid(let pid, let token) = selector {
                    guard let u = Proc.usage(pid) else {
                        return Proc.exists(pid) ? "pid \(pid) is owned by another user; its CPU can't be read without root"
                                                : "no process with pid \(pid) at the start of the wait"
                    }
                    if let token, token != String(u.start) { return "pid \(pid) was reused: startToken differs, the original process already exited" }
                    pidKey = Proc.Key(pid: pid, start: u.start)
                }
                primeGroup(groupKeys(now: startNs))
            }
            return nil
        }
    }

    private func tick() {
        guard completion != nil else { return }
        let obs = observe(now: Proc.nowNs())
        // An observation finished after the deadline doesn't count: the wait already ran out.
        if Proc.nowNs() > deadlineNs { timedOut(); return }
        last = obs.observation
        if obs.satisfied && obs.observation.valid { consecutive += 1 } else { consecutive = 0 }
        let needed: Int
        switch condition {
        case .processExit, .portListening: needed = 1
        default: needed = Self.requiredConsecutive
        }
        if consecutive >= needed {
            finish("met")
        } else if let gone = obs.ended {
            finish("unavailable", reason: gone)
        }
    }

    private func timedOut() {
        guard completion != nil else { return }
        if case .cpuIdle(let scope, _) = condition, !everMatched {
            if case .system = scope {} else {
                finish("unavailable", reason: invalidReason ?? "no matching process was found during the wait")
                return
            }
        }
        if case .portListening = condition {
            finish("timed_out", reason: portResult?.note ?? PortLookup.visibilityNote)
            return
        }
        finish("timed_out", reason: last?.valid == false ? invalidReason : nil)
    }

    private struct Observed {
        var observation: WaitResult.Observation
        var satisfied: Bool
        /// Set when no valid observation can happen any more (the watched instance or track is gone).
        var ended: String?
    }

    private func observe(now: UInt64) -> Observed {
        switch condition {
        case .portListening(let port):
            let result = PortLookup.find(port, limit: ProcessFinder.maxLimit)
            portResult = result
            let listening = result.matched > 0
            return Observed(observation: .init(at: Date(), portListening: listening, valid: result.scanAvailable == true), satisfied: listening)
        case .processExit:
            let alive = exitKey.map(Proc.isAlive) ?? false
            return Observed(observation: .init(at: Date(), processAlive: alive, valid: true), satisfied: !alive)

        case .memoryPressureNormal:
            let p = SystemSampler.memoryPressure()
            return Observed(observation: .init(at: Date(), memoryPressure: p, valid: p != "unknown"), satisfied: p == "normal")

        case .cpuIdle(let scope, let below):
            switch scope {
            case .system:
                guard let ticks = SystemSampler.readCPUTicks(), let prev = prevTicks else {
                    invalidReason = "CPU counters could not be read"
                    return Observed(observation: .init(at: Date(), valid: false), satisfied: false)
                }
                prevTicks = ticks
                let user = Double(ticks.user &- prev.user) + Double(ticks.nice &- prev.nice)
                let busy = user + Double(ticks.system &- prev.system)
                let total = busy + Double(ticks.idle &- prev.idle)
                guard total > 0 else {
                    invalidReason = "CPU counters did not advance"
                    return Observed(observation: .init(at: Date(), valid: false), satisfied: false)
                }
                everMatched = true
                let pct = Proc.round1(busy / total * 100)
                return Observed(observation: .init(at: Date(), cpuPercent: pct, valid: true), satisfied: pct < below)
            case .track(let id):
                guard let keys = tracks?.memberKeys(id) else {
                    return Observed(observation: .init(at: Date(), valid: false), satisfied: false,
                                    ended: "track \(id) is no longer running")
                }
                return groupObservation(keys: keys, now: now, below: below, ended: nil)
            case .selector:
                let keys = groupKeys(now: now)
                var ended: String?
                if let k = pidKey, !Proc.isAlive(k) { ended = "pid \(k.pid) exited during the wait (use process_exit to wait for an exit)" }
                return groupObservation(keys: keys, now: now, below: below, ended: ended)
            }
        }
    }

    private func groupObservation(keys: [Proc.Key], now: UInt64, below: Double, ended: String?) -> Observed {
        if let ended { return Observed(observation: .init(at: Date(), valid: false), satisfied: false, ended: ended) }
        let pct = groupCPU(keys: keys, now: now)
        return Observed(observation: .init(at: Date(), cpuPercent: pct.map(Proc.round1), valid: pct != nil),
                        satisfied: (pct ?? .infinity) < below)
    }

    private func groupKeys(now: UInt64) -> [Proc.Key] {
        guard case .cpuIdle(let scope, _) = condition else { return [] }
        switch scope {
        case .system: return []
        case .track(let id): return tracks?.memberKeys(id) ?? []
        case .selector(let selector):
            if case .pid = selector { return pidKey.map { [$0] } ?? [] }
            if lastSelectorScanNs.map({ now &- $0 >= ProcessTrack.discoveryInterval }) ?? true {
                lastSelectorScanNs = now
                if let rows = directory.scan(refreshPath: selector.pathRefreshFilter) {
                    let picked = directory.select(rows, selector)
                    for r in picked.argsUnreadable { argsUnreadable.insert(r.pid) }
                    selectorKeys = picked.rows.compactMap { r in
                        Proc.usage(r.pid).map { Proc.Key(pid: r.pid, start: $0.start) }
                    }
                }
            }
            return selectorKeys
        }
    }

    private func primeGroup(_ keys: [Proc.Key]) {
        prevGroupNs = Proc.nowNs()
        prevGroup = [:]
        for k in keys { if let u = Proc.usage(k.pid), u.start == k.start { prevGroup[k] = (u.cpuNs, Proc.nowNs()) } }
        baseline = prevGroup.mapValues(\.cpuNs)
    }

    /// Summed CPU of the processes since the previous observation (percent of one core, each process
    /// over its own read-to-read interval). Nil (not a valid observation) when no process could be read,
    /// or when a live member has no previous reading yet: an unmeasured process can't be called idle.
    private func groupCPU(keys: [Proc.Key], now: UInt64) -> Double? {
        guard let prevNs = prevGroupNs, now > prevNs else { return nil }
        var sum = 0.0, measured = 0, unmeasured = 0
        var next: [Proc.Key: (cpuNs: UInt64, at: UInt64)] = [:]
        for k in keys {
            guard let u = Proc.usage(k.pid), u.start == k.start else { continue }
            let t = Proc.nowNs()
            next[k] = (u.cpuNs, t)
            if baseline[k] == nil { baseline[k] = u.startNs >= startNs ? 0 : u.cpuNs }
            if let p = prevGroup[k], u.cpuNs >= p.cpuNs, t > p.at {
                sum += Double(u.cpuNs - p.cpuNs) / Double(t - p.at) * 100
                measured += 1
            } else if u.startNs >= prevNs, t > prevNs {
                sum += Double(u.cpuNs) / Double(t - prevNs) * 100
                measured += 1
            } else {
                unmeasured += 1
            }
        }
        prevGroup = next
        prevGroupNs = now
        if !next.isEmpty { everMatched = true }
        guard measured > 0 else {
            invalidReason = next.isEmpty ? "no matching process is running" : "matching processes have no CPU reading yet"
            return nil
        }
        guard unmeasured == 0 else {
            invalidReason = "new matching processes have no CPU reading yet"
            return nil
        }
        return sum
    }

    private func finish(_ state: String, reason: String? = nil) {
        guard let completion else { return }
        stopTimers()
        self.completion = nil
        let elapsed = Double(Proc.nowNs() &- startNs) / 1e9
        var below: Double?
        if case .cpuIdle(_, let b) = condition { below = b }
        var result = WaitResult(state: state, condition: condition.name, scope: scopeName, thresholdPercent: below,
                                elapsedSeconds: Proc.round1(state == "timed_out" ? min(elapsed, timeout) : elapsed),
                                timeoutSeconds: timeout, lastObservation: last, culprits: nil, reason: reason)
        if state == "timed_out", case .cpuIdle(let scope, _) = condition {
            result.culprits = culprits(scope: scope, elapsed: elapsed)
        }
        if case .cpuIdle(.selector(let selector), _) = condition, selector.argsContain != nil { result.argsUnreadable = argsUnreadable.count }
        if state == "met", let portResult {
            result.processes = portResult.processes
            result.matched = portResult.matched
        }
        completion(result)
    }

    private func culprits(scope: WaitCondition.Scope, elapsed: Double) -> [WaitResult.Culprit] {
        guard elapsed > 0 else { return [] }
        let now: [Proc.Key: UInt64]
        switch scope {
        case .system: now = Self.userProcessCPU()
        case .track, .selector:
            var m: [Proc.Key: UInt64] = [:]
            for k in baseline.keys { if let u = Proc.usage(k.pid), u.start == k.start { m[k] = u.cpuNs } }
            for (k, v) in prevGroup where m[k] == nil { m[k] = v.cpuNs }
            now = m
        }
        var rows: [(Proc.Key, Double)] = []
        for (k, cpu) in now {
            let base: UInt64
            if let b = baseline[k] { base = b } else if Proc.ns(k.start) >= startNs { base = 0 } else { continue }
            guard cpu >= base else { continue }
            rows.append((k, Double(cpu - base) / (elapsed * 1e9) * 100))
        }
        return rows.sorted { $0.1 > $1.1 }.prefix(3).map { k, pct in
            let name = Proc.name(k.pid)
            let parent = Proc.parent(k.pid)
            let live = Proc.isAlive(k)
            return WaitResult.Culprit(startToken: k.token, ppid: live ? parent.flatMap { $0 > 0 ? $0 : nil } : nil,
                                      pid: k.pid, name: (live ? name : nil) ?? "pid \(k.pid)", cpuPercent: Proc.round1(pct))
        }
    }

    /// CPU time of every readable (current-user) process.
    static func userProcessCPU() -> [Proc.Key: UInt64] {
        var result: [Proc.Key: UInt64] = [:]
        for pid in Proc.allPids() {
            if let u = Proc.usage(pid) { result[Proc.Key(pid: pid, start: u.start)] = u.cpuNs }
        }
        return result
    }
}
