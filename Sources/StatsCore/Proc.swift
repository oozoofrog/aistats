import Darwin
import Foundation

/// Thin wrappers over libproc/sysctl for reading single processes. All reads return nil
/// on failure (exited, or owned by another user without root) so callers never mistake a
/// failed read for a zero value.
public enum Proc {
    static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// Converts Mach absolute time units to nanoseconds (same clock as `DispatchTime.uptimeNanoseconds`).
    @inline(__always) static func ns(_ abs: UInt64) -> UInt64 {
        timebase.numer == timebase.denom ? abs : abs &* timebase.numer / timebase.denom
    }

    public static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Identity of one process instance: a pid plus its start time, so a reused pid is a different instance.
    public struct Key: Hashable, Sendable, Comparable {
        public var pid: Int32
        public var start: UInt64
        public init(pid: Int32, start: UInt64) { self.pid = pid; self.start = start }
        public var token: String { String(start) }
        public static func < (a: Key, b: Key) -> Bool { (a.start, a.pid) < (b.start, b.pid) }
    }

    public struct Usage: Sendable {
        /// `ri_proc_start_abstime`; stable for the life of the process (also across exec).
        public var start: UInt64
        /// User + system CPU time in nanoseconds.
        public var cpuNs: UInt64
        /// `ri_phys_footprint`, the Activity Monitor "Memory" column.
        public var footprint: UInt64
        /// `ri_lifetime_max_phys_footprint` (rusage_info v4+).
        public var lifetimeMaxFootprint: UInt64
        public var key: Key { .init(pid: 0, start: start) }
        /// Process start as uptime nanoseconds.
        public var startNs: UInt64 { Proc.ns(start) }
    }

    public static func usage(_ pid: Int32) -> Usage? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok else { return nil }
        return Usage(start: info.ri_proc_start_abstime,
                     cpuNs: ns(info.ri_user_time &+ info.ri_system_time),
                     footprint: info.ri_phys_footprint,
                     lifetimeMaxFootprint: info.ri_lifetime_max_phys_footprint)
    }

    public static func path(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let s = String(cString: buffer)
        return s.isEmpty ? nil : s
    }

    /// Executable file name (basename of the path), falling back to the kernel's short name.
    public static func name(_ pid: Int32) -> String? {
        if let p = path(pid) {
            let n = (p as NSString).lastPathComponent
            if !n.isEmpty { return n }
        }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let s = String(cString: buffer)
        return s.isEmpty ? nil : s
    }

    /// Arguments after argv[0], from `KERN_PROCARGS2` (current user's processes only). Nil if unreadable.
    /// Callers must never return or log them: they can hold secrets.
    public static func arguments(_ pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        // The executable path, then NUL padding, then argc NUL-terminated strings.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        guard args.count == argc else { return nil }
        return Array(args.dropFirst())
    }

    static func matches(_ pid: Int32, startSec: Int, startUsec: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == geteuid()
            && info.pbi_start_tvsec == startSec && info.pbi_start_tvusec == startUsec
    }

    public static func parent(_ pid: Int32) -> Int32? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbsi_ppid)
    }

    /// True if `key` still names a running process (same pid and same start time).
    public static func isAlive(_ key: Key) -> Bool { usage(key.pid)?.start == key.start }

    /// True if the pid exists, including processes we may not read (other users).
    public static func exists(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Direct children of `pid`. Costs a walk of the kernel process list (~0.1 ms), so callers rate-limit it.
    public static func children(of pid: Int32) -> [Int32] {
        var buffer = [pid_t](repeating: 0, count: 256)
        while true {
            let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            guard n > 0 else { return [] }
            // Returns a count of pids on current kernels; older ones returned bytes.
            let count = Int(n) <= buffer.count ? Int(n) : Int(n) / MemoryLayout<pid_t>.size
            if count < buffer.count || buffer.count >= 8192 {
                return Array(buffer.prefix(min(count, buffer.count))).filter { $0 > 0 }
            }
            buffer = [pid_t](repeating: 0, count: buffer.count * 4)
        }
    }

    public static func allPids() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    /// One row of the kernel process table.
    public struct Entry: Sendable {
        public var pid: Int32
        public var ppid: Int32
        /// Kernel short name (at most 16 characters).
        public var comm: String
        public var startSec: Int
        public var startUsec: Int32
    }

    /// Processes whose effective user is the current user, in one sysctl call. Nil if the call failed.
    public static func currentUserTable() -> [Entry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: geteuid())]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<8 {
            var length = 0
            guard sysctl(&mib, 4, nil, &length, nil, 0) == 0 else { return nil }
            // Processes can appear between the two calls; leave generous headroom.
            let estimate = length / stride
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: estimate + estimate / 4 + 64)
            length = buffer.count * stride
            if sysctl(&mib, 4, &buffer, &length, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return buffer.prefix(length / stride).compactMap { k in
                let pid = k.kp_proc.p_pid
                guard pid > 0 else { return nil }
                let comm = withUnsafePointer(to: k.kp_proc.p_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
                }
                return Entry(pid: pid, ppid: k.kp_eproc.e_ppid, comm: comm,
                             startSec: k.kp_proc.p_un.__p_starttime.tv_sec,
                             startUsec: k.kp_proc.p_un.__p_starttime.tv_usec)
            }
        }
        return nil
    }

    public struct ThreadSample: Codable, Sendable, Hashable {
        public var name: String
        /// Kernel's recent-use estimate, percent of one core.
        public var cpuPercent: Double
        public var userSeconds: Double
        public var systemSeconds: Double
    }

    /// Busiest threads of a process (same user only) and how many threads it has. Nil if the process can't be read.
    public static func threads(_ pid: Int32, limit: Int = 5) -> (busiest: [ThreadSample], total: Int)? {
        var ids = [UInt64](repeating: 0, count: 512)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids, Int32(ids.count * MemoryLayout<UInt64>.size))
        guard bytes > 0 else { return nil }
        let count = min(ids.count, Int(bytes) / MemoryLayout<UInt64>.size)
        var result: [ThreadSample] = []
        let size = Int32(MemoryLayout<proc_threadinfo>.size)
        for id in ids.prefix(count) {
            var ti = proc_threadinfo()
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &ti, size) == size else { continue }
            let name = withUnsafePointer(to: ti.pth_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXTHREADNAMESIZE)) { String(cString: $0) }
            }
            result.append(ThreadSample(name: name.isEmpty ? "thread" : String(name.prefix(48)),
                                       cpuPercent: round1(Double(ti.pth_cpu_usage) / Double(TH_USAGE_SCALE) * 100),
                                       userSeconds: round2(Double(ti.pth_user_time) / 1e9),
                                       systemSeconds: round2(Double(ti.pth_system_time) / 1e9)))
        }
        let busiest = Array(result.sorted { ($0.cpuPercent, $0.userSeconds + $0.systemSeconds) > ($1.cpuPercent, $1.userSeconds + $1.systemSeconds) }
            .prefix(limit))
        return (busiest, max(count, result.count))
    }

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// Caches each process's executable path/name by (pid, start time, kernel short name), so repeated
/// scans only call `proc_pidpath` for new processes. An exec usually changes the short name and so the
/// key, but not always (/a/tool → /b/tool keeps "tool"), so path lookups re-read the path of every
/// process that could match (`refreshPath`), and `invalidate` drops a pid known to have exec'd.
/// Not thread-safe; use from one queue.
public final class ProcessDirectory {
    public struct Row: Sendable {
        public var pid: Int32
        public var ppid: Int32
        public var name: String
        public var path: String?
        fileprivate var key: CacheKey?
        var isCurrentInstance: Bool {
            guard let key else { return false }
            return Proc.matches(pid, startSec: key.sec, startUsec: key.usec)
        }

        public init(pid: Int32, ppid: Int32, name: String, path: String?) {
            self.pid = pid; self.ppid = ppid; self.name = name; self.path = path
        }
    }

    fileprivate struct CacheKey: Hashable { var pid: Int32; var sec: Int; var usec: Int32; var comm: String }
    private var cache: [CacheKey: (name: String, path: String?)] = [:]
    /// argv (after argv[0]) of processes an argument filter looked at; nil = unreadable. Never exposed.
    private var argsCache: [CacheKey: [String]?] = [:]
    private var invalidated = Set<Int32>()

    public init() {}

    /// Forget what is cached for `pid` (it exec'd), so the next scan reads its path again.
    public func invalidate(_ pid: Int32) { invalidated.insert(pid) }

    /// Current-user processes with names and paths. Nil if the process table could not be read.
    /// `refreshPath` picks rows whose path must be read fresh rather than taken from the cache.
    public func scan(refreshPath: ((Proc.Entry) -> Bool)? = nil) -> [Row]? {
        guard let table = Proc.currentUserTable() else { return nil }
        var next: [CacheKey: (name: String, path: String?)] = [:]
        next.reserveCapacity(table.count)
        var rows: [Row] = []
        rows.reserveCapacity(table.count)
        for e in table {
            let key = CacheKey(pid: e.pid, sec: e.startSec, usec: e.startUsec, comm: e.comm)
            let value: (name: String, path: String?)
            if let cached = cache[key], !invalidated.contains(e.pid), refreshPath?(e) != true {
                value = cached
            } else {
                let path = Proc.path(e.pid)
                let name = path.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? e.comm
                value = (name, path)
            }
            next[key] = value
            var row = Row(pid: e.pid, ppid: e.ppid, name: value.name, path: value.path)
            row.key = key
            rows.append(row)
        }
        cache = next
        // Arguments are re-read after an exec and forgotten once the process is gone.
        argsCache = argsCache.filter { next[$0.key] != nil && !invalidated.contains($0.key.pid) }
        invalidated.removeAll()
        return rows
    }

    /// Rows that match `selector`, including its argument filter: argv is read only for rows that already
    /// match by name/path, once per process instance (again after an exec). A row whose argv can't be read
    /// doesn't match and is counted in `argsUnreadable`.
    public func select(_ rows: [Row], _ selector: ProcessSelector) -> (rows: [Row], argsUnreadable: [Row]) {
        let candidates = rows.filter { selector.matches(name: $0.name, path: $0.path) }
        guard let needle = selector.argsContain else { return (candidates, []) }
        var matched: [Row] = [], unreadable: [Row] = []
        for r in candidates {
            let args: [String]?
            if let key = r.key, let cached = argsCache[key] {
                args = cached
            } else {
                args = Proc.arguments(r.pid)
                // A process that exited since the scan is simply gone, not "unreadable".
                if args == nil, !Proc.exists(r.pid) { continue }
                if let key = r.key { argsCache[key] = .some(args) }
            }
            guard let args else { unreadable.append(r); continue }
            if args.contains(where: { $0.contains(needle) }) { matched.append(r) }
        }
        return (matched, unreadable)
    }
}

/// What a caller asked to find or track.
public enum ProcessSelector: Sendable, Equatable {
    case pid(Int32, startToken: String?)
    /// `args`: optional argument filter (`argsContain`); see `ProcessDirectory.select`.
    case name(String, glob: Bool, args: String? = nil)
    case path(String, glob: Bool, args: String? = nil)

    public static let argsContainRange = 1...128

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Validates raw tool/CLI arguments. Exactly one of pid, name, path must be given.
    public static func parse(pid: Int?, startToken: String?, name: String?, path: String?, match: String?,
                             argsContain: String? = nil) throws -> ProcessSelector {
        let given = [pid != nil, name != nil, path != nil].filter { $0 }.count
        guard given == 1 else { throw Invalid("give exactly one of pid, name, path") }
        let glob: Bool
        switch match ?? "exact" {
        case "exact": glob = false
        case "glob": glob = true
        default: throw Invalid("match must be exact or glob")
        }
        if let pid {
            guard pid > 0, pid <= Int(Int32.max) else { throw Invalid("pid must be a positive integer") }
            if match == "glob" { throw Invalid("match applies to name or path, not pid") }
            if let t = startToken, t.isEmpty || UInt64(t) == nil { throw Invalid("startToken must be the string returned by find_processes") }
            if argsContain != nil { throw Invalid("argsContain goes with name or path, not pid") }
            return .pid(Int32(pid), startToken: startToken)
        }
        if let a = argsContain, !argsContainRange.contains(a.count) || a.contains("\0") {
            throw Invalid("argsContain must be 1–128 characters")
        }
        if startToken != nil { throw Invalid("startToken goes with pid") }
        if let name {
            guard (1...64).contains(name.count) else { throw Invalid("name must be 1–64 characters") }
            return .name(name, glob: glob, args: argsContain)
        }
        let p = path!
        guard p.hasPrefix("/"), p.count <= 1024 else { throw Invalid("path must be an absolute executable path") }
        // The kernel reports resolved paths (/private/var/…, not /var/…), so resolve exact paths too.
        return .path(glob ? p : realPath(p) ?? p, glob: glob, args: argsContain)
    }

    static func realPath(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    public var kind: String {
        switch self { case .pid: return "pid"; case .name: return "name"; case .path: return "path" }
    }

    public var matchMode: String? {
        switch self {
        case .pid: return nil
        case .name(_, let g, _), .path(_, let g, _): return g ? "glob" : "exact"
        }
    }

    /// The argument filter, if any (never returned to clients or logged).
    public var argsContain: String? {
        switch self {
        case .pid: return nil
        case .name(_, _, let a), .path(_, _, let a): return a
        }
    }

    var isPath: Bool { if case .path = self { return true } else { return false } }

    /// For path selectors: whether a process-table entry could match, judged by its kernel short name
    /// (the first 16 bytes of the executable's file name), so only those paths are re-read on each scan.
    /// Nil for other selectors (cached paths are fine there: names come from the short name key).
    var pathRefreshFilter: ((Proc.Entry) -> Bool)? {
        guard case .path(let pattern, let glob, _) = self else { return nil }
        let base = (pattern as NSString).lastPathComponent
        if glob && base.contains(where: { "*?[".contains($0) }) { return { _ in true } }
        let comm = String(decoding: Array(base.utf8.prefix(Int(MAXCOMLEN))), as: UTF8.self)
        return { $0.comm == comm }
    }

    public func matches(name: String, path: String?) -> Bool {
        switch self {
        case .pid: return false
        case .name(let pattern, let glob, _):
            if glob { return fnmatch(pattern, name, FNM_CASEFOLD) == 0 }
            return name.caseInsensitiveCompare(pattern) == .orderedSame
        case .path(let pattern, let glob, _):
            guard let path else { return false }
            return glob ? fnmatch(pattern, path, 0) == 0 : path == pattern
        }
    }
}
