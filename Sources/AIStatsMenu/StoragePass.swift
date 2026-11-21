import Darwin
import Foundation
import StatsCore

/// Lexical path rules of ADR 0010: Normalized Path, comparison keys and report paths.
enum StoragePath {
    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }

    /// Expands `~` and `~/`, drops empty and `.` components and a trailing `/`, and maps `/System/Volumes/Data` to `/`.
    /// nil for a path that is neither absolute nor home-relative.
    static func normalize(_ raw: String, home: String) -> String? {
        var path = raw
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + "/" + path.dropFirst(2) }
        guard path.hasPrefix("/") else { return nil }
        var parts = components(path)
        if parts.count >= 3, parts.prefix(3).map(key) == ["system", "volumes", "data"] { parts.removeFirst(3) }
        return "/" + parts.joined(separator: "/")
    }

    /// Unicode canonical decomposition and case folding, per component.
    static func key(_ s: String) -> String { s.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }

    static func keys(_ normalized: String) -> [String] { components(normalized).map(key) }

    static func isPrefix(_ a: [String], of b: [String]) -> Bool { a.count <= b.count && Array(b.prefix(a.count)) == a }

    /// `~/` plus the rest for a path inside `home`, else the absolute Normalized Path.
    static func report(_ normalized: String, home: String) -> String {
        let h = keys(home), parts = components(normalized)
        guard isPrefix(h, of: parts.map(key)) else { return normalized }
        let rest = parts.dropFirst(h.count)
        return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
    }
}

enum VolumeClass: String { case bootData = "boot_data", network, localOther = "local_other" }

struct StorageMount: Sendable {
    var path: String
    var local: Bool
}

/// Everything a pass reads from outside, so tests use fixture homes, mount tables, preferences and clocks.
struct StorageEnvironment {
    var home: String
    var aistatsHome: URL
    var now: () -> Date
    var threadCPU: () -> TimeInterval
    var processCPU: () -> TimeInterval?
    var preference: () -> Any?
    var mounts: @Sendable () -> [StorageMount]
    var macOSMajor: Int
    var onEntry: () -> Void = {}
    /// Blocked mount-table reads. Shared by every live pass; a fresh registry per test environment.
    var mountProbes = ProbeRegistry()

    private static let liveMountProbes = ProbeRegistry()

    static func live(aistatsHome: URL = AIStatsPaths.home) -> StorageEnvironment {
        StorageEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser.path, aistatsHome: aistatsHome, now: Date.init,
            threadCPU: { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 },
            processCPU: { Proc.usage(getpid()).map { Double($0.cpuNs) / 1e9 } },
            preference: { CFPreferencesCopyAppValue("IDECustomDerivedDataLocation" as CFString, "com.apple.dt.Xcode" as CFString) },
            mounts: { MountEntry.table().map { StorageMount(path: $0.path, local: $0.isLocal) } },
            macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, mountProbes: liveMountProbes)
    }
}

/// One Storage Pass over the Known Developer Directories, run as resumable Storage Slices (ADR 0010).
/// Not thread-safe: the scheduler calls it from one serial queue.
final class StoragePass {
    static let sliceWall: TimeInterval = 2, sliceCPU: TimeInterval = 0.1
    static let passCPU: TimeInterval = 30, passWall: TimeInterval = 5 * 3600
    static let admissionCPU: TimeInterval = 0.44, admissionWindow: TimeInterval = 60
    static let mountDeadline: TimeInterval = 0.2
    /// Tolerance for timer and floating-point rounding when comparing wall-clock times.
    static let clockSlack: TimeInterval = 0.001
    static let deviceSupportLimit = 8
    /// Enabled pairs of Volume Class and macOS major version. Add a pair only with its STO-003 result.
    static let qualified: [(VolumeClass, Int)] = [(.bootData, 14), (.bootData, 27)]

    static func enabled(_ volume: VolumeClass, major: Int) -> Bool {
        if qualified.contains(where: { $0.0 == volume && $0.1 == major }) { return true }
        return major > qualified.map(\.1).max()! && volume == .bootData
    }

    struct Root {
        var path: String?
        var source: String?
        var mountPath = ""
        var state: State = .pending
        var sizeBytes: UInt64 = 0
        var complete = true
    }
    enum State: Equatable { case pending, walking, done, absent, notMeasured(String) }

    private struct FileID: Hashable { var dev: dev_t; var ino: ino_t }

    private let env: StorageEnvironment
    private(set) var startedAt: Date?
    private(set) var report: StorageReport?
    private(set) var slices = 0, slicesSkippedForCpu = 0
    private var cpu: TimeInterval = 0
    /// App CPU readings, oldest first: the newest one that is at least 60 s old, and every later one.
    private var samples: [(wall: Date, cpu: TimeInterval)] = []
    private var prepared = false
    private(set) var roots: [Root] = []
    private var derivedDataLocation = "default"
    private var deviceSupportOmitted = 0
    private var homePath = ""
    private var seen = Set<FileID>()
    private var stack: [UnsafeMutablePointer<DIR>] = []
    private var current: (index: Int, dev: dev_t)?

    init(_ env: StorageEnvironment) { self.env = env }

    deinit { stack.forEach { closedir($0) } }

    /// Records an App CPU reading. The admission test compares against the newest reading that is at least 60 s old.
    func recordBaseline() {
        guard let cpu = env.processCPU() else { return }
        let now = env.now()
        samples.append((now, cpu))
        if let keep = samples.lastIndex(where: { now.timeIntervalSince($0.wall) >= Self.admissionWindow - Self.clockSlack }) {
            samples.removeFirst(keep)
        }
    }

    /// The time at which the pass wall cap ends a started pass.
    var wallCapAt: Date? { report == nil ? startedAt?.addingTimeInterval(Self.passWall) : nil }

    /// Ends a started pass that reached its wall cap, without a walk or an admission test. The scheduler calls it
    /// also while a deferral condition holds, because the wall cap keeps running during a pause (ADR 0010).
    func endAtWallCap() -> Bool {
        guard let cap = wallCapAt, env.now().timeIntervalSince(cap) >= -Self.clockSlack else { return false }
        let c0 = env.threadCPU()
        finish("pass_wall_cap", cpu: cpu + env.threadCPU() - c0)
        cpu += env.threadCPU() - c0
        return true
    }

    /// Runs one Storage Slice. Returns true when the pass ended: its report was written, or the pass did not start
    /// because `lastPassStartedAt` could not be persisted (STO-042). In that case `startedAt` stays nil.
    func slice() -> Bool {
        let c0 = env.threadCPU(), w0 = env.now()
        if startedAt == nil {
            do {
                try StorageFiles.write(StorageSchedule(lastPassStartedAt: w0), StorageFiles.schedule, home: env.aistatsHome)
            } catch {
                return true
            }
            startedAt = w0
        }
        let start = startedAt!
        func passCPU(_ c: TimeInterval) -> TimeInterval { cpu + c - c0 }
        func cap(_ t: Date, _ c: TimeInterval) -> String? {
            if t.timeIntervalSince(start) >= Self.passWall { return "pass_wall_cap" }
            return passCPU(c) >= Self.passCPU ? "pass_cpu_cap" : nil
        }
        if let reason = cap(w0, c0) {
            finish(reason, cpu: passCPU(env.threadCPU()))
            cpu = passCPU(env.threadCPU())
            return true
        }
        guard admit(w0) else {
            slicesSkippedForCpu += 1
            recordBaseline()
            cpu = passCPU(env.threadCPU())
            return false
        }
        slices += 1
        if !prepared, !prepare() {
            finish("mount_table_timeout", cpu: passCPU(env.threadCPU()))
            cpu = passCPU(env.threadCPU())
            return true
        }
        while true {
            let t = env.now(), c = env.threadCPU()
            if let reason = cap(t, c) { finish(reason, cpu: passCPU(c)); break }
            if t.timeIntervalSince(w0) >= Self.sliceWall || c - c0 >= Self.sliceCPU { break }
            guard step() else { finish("complete", cpu: passCPU(c)); break }
            env.onEntry()
        }
        cpu = passCPU(env.threadCPU())
        if report == nil { recordBaseline() }
        return report != nil
    }

    /// The App used no more than the admission threshold in the last 60 s. The test uses the App CPU time since the
    /// newest reading that is at least 60 s old, unscaled, so an older reading can only skip more slices. With no
    /// reading that old, the last 60 s are unknown and the slice is skipped.
    private func admit(_ now: Date) -> Bool {
        guard let cpu = env.processCPU() else { return true }
        guard let base = samples.last(where: { now.timeIntervalSince($0.wall) >= Self.admissionWindow - Self.clockSlack }) else { return false }
        return cpu - base.cpu <= Self.admissionCPU
    }

    // MARK: Roots

    /// Reads the preference and the Xcode entry names, builds the allowlist in ADR order and classifies each root
    /// from the mount table without touching it. False when the mount-table read missed its deadline.
    private func prepare() -> Bool {
        prepared = true
        let home = StoragePath.normalize(env.home, home: env.home) ?? env.home
        homePath = home
        func fixed(_ rest: String) -> Root { Root(path: home + "/" + rest) }
        roots = [fixed("Library/Caches/org.swift.swiftpm"), fixed("Library/Developer/Xcode/Archives")]
        let support = Self.entryNames(home + "/Library/Developer/Xcode").filter { $0.hasSuffix(" DeviceSupport") }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        deviceSupportOmitted = max(0, support.count - Self.deviceSupportLimit)
        roots += support.prefix(Self.deviceSupportLimit).map { fixed("Library/Developer/Xcode/" + $0) }
        roots.append(fixed("Library/Developer/CoreSimulator/Caches"))
        let defaultDerivedData = home + "/Library/Developer/Xcode/DerivedData"
        roots.append(Root(path: defaultDerivedData))
        switch Self.customLocation(env.preference(), home: home) {
        case .none: derivedDataLocation = "default"
        case .some(nil):
            derivedDataLocation = "unresolved"
            roots.append(Root(path: nil, source: "xcode_setting", state: .notMeasured("unresolved_setting")))
        case .some(let path?):
            if StoragePath.keys(path) == StoragePath.keys(defaultDerivedData) {
                derivedDataLocation = "default"
            } else {
                derivedDataLocation = "custom"
                roots.append(Root(path: path, source: "xcode_setting"))
            }
        }
        roots.append(fixed("Library/Developer/CoreSimulator/Devices"))

        guard let mounts = Self.readMounts(env.mounts, probes: env.mountProbes) else { return false }
        for i in roots.indices where roots[i].state == .pending {
            let (reason, mount) = Self.classify(roots[i].path!, home: home, mounts: mounts, major: env.macOSMajor)
            if let reason { roots[i].state = .notMeasured(reason) } else { roots[i].mountPath = mount! }
        }
        return true
    }

    /// nil when the preference is absent; `.some(nil)` for a value ADR 0010 does not accept.
    static func customLocation(_ value: Any?, home: String) -> String?? {
        guard let value else { return nil }
        guard let s = value as? String, s == "~" || s.hasPrefix("~/") || s.hasPrefix("/"),
              !s.split(separator: "/").contains(".."), let path = StoragePath.normalize(s, home: home) else { return .some(nil) }
        return .some(path)
    }

    /// Reads the mount table on a helper thread with a deadline. While an earlier read is still blocked, no second
    /// thread starts and the read counts as a missed deadline.
    static func readMounts(_ read: @escaping @Sendable () -> [StorageMount], probes: ProbeRegistry) -> [StorageMount]? {
        final class Box: @unchecked Sendable { var value: [StorageMount]?; let lock = NSLock() }
        guard let probe = probes.start("mount_table") else { return nil }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let value = read()
            probes.finish("mount_table", probe)
            box.lock.lock(); box.value = value; box.lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + mountDeadline) == .success else {
            probes.timedOut("mount_table", probe)
            return nil
        }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.value
    }

    /// Volume Class, then Excluded Locations, then volume qualification; all lexical. Returns a reason or the mount path.
    static func classify(_ path: String, home: String, mounts: [StorageMount], major: Int) -> (String?, String?) {
        let p = StoragePath.keys(path)
        let table = mounts.map { (mount: $0, keys: StoragePath.keys(StoragePath.normalize($0.path, home: home) ?? $0.path)) }
        guard let match = table.filter({ StoragePath.isPrefix($0.keys, of: p) })
            .max(by: { ($0.keys.count, $0.mount.path.count) < ($1.keys.count, $1.mount.path.count) }) else { return ("volume_unqualified", nil) }
        let volume: VolumeClass = !match.mount.local ? .network : match.keys.isEmpty ? .bootData : .localOther
        if volume == .network { return ("network_volume", nil) }
        if let reason = excluded(p, home: StoragePath.keys(home), boot: volume == .bootData, network: table.filter { !$0.mount.local }.map(\.keys)) {
            return (reason, nil)
        }
        guard enabled(volume, major: major) else { return ("volume_unqualified", nil) }
        return (nil, match.mount.path)
    }

    static func excluded(_ p: [String], home h: [String], boot: Bool, network: [[String]]) -> String? {
        func overlaps(_ l: [String]) -> Bool { StoragePath.isPrefix(l, of: p) || StoragePath.isPrefix(p, of: l) }
        if ["desktop", "documents", "downloads", "pictures", "movies", "music"].contains(where: { overlaps(h + [$0]) }) { return "protected_location" }
        let library = h + ["library"]
        if StoragePath.isPrefix(p, of: library) { return "protected_location" }
        if StoragePath.isPrefix(library, of: p), !StoragePath.isPrefix(library + ["developer"], of: p),
           !StoragePath.isPrefix(library + ["caches", "org.swift.swiftpm"], of: p) { return "protected_location" }
        if boot, !StoragePath.isPrefix(h, of: p),
           [["system"], ["library"], ["applications"], ["private"], ["users"]].contains(where: overlaps) { return "protected_location" }
        return network.contains(where: overlaps) ? "network_volume" : nil
    }

    enum Access { case ok, redirected, absent, unreadable }

    /// `lstat` of each component from the top; stops at the first symbolic link.
    static func access(_ path: String) -> Access {
        var current = ""
        for part in StoragePath.components(path) {
            current += "/" + part
            var st = stat()
            guard lstat(current, &st) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable }
            if st.st_mode & S_IFMT == S_IFLNK { return .redirected }
            if current == path, st.st_mode & S_IFMT != S_IFDIR { return .absent }
        }
        return .ok
    }

    static func entryNames(_ path: String) -> [String] {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        guard let dir = fdopendir(fd) else { close(fd); return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = String(cString: nameOf(entry))
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    // MARK: Walk

    static func nameOf(_ entry: UnsafeMutablePointer<dirent>) -> UnsafePointer<CChar> {
        UnsafeRawPointer(entry).advanced(by: MemoryLayout<dirent>.offset(of: \dirent.d_name)!).assumingMemoryBound(to: CChar.self)
    }

    /// Processes one directory entry, or opens or closes one directory. False when every root is done.
    private func step() -> Bool {
        guard let dir = stack.last, let walking = current else {
            if let c = current { roots[c.index].state = .done; current = nil }
            guard let next = roots.firstIndex(where: { $0.state == .pending }) else { return false }
            open(next)
            return true
        }
        let index = walking.index
        errno = 0
        guard let entry = readdir(dir) else {
            if errno != 0 { roots[index].complete = false }
            closedir(dir)
            stack.removeLast()
            return true
        }
        let fd = dirfd(dir), name = Self.nameOf(entry)
        if name[0] == 46, name[1] == 0 || (name[1] == 46 && name[2] == 0) { return true }
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno != ENOENT { roots[index].complete = false }
            return true
        }
        guard st.st_dev == walking.dev else { return true }
        if st.st_mode & S_IFMT == S_IFDIR {
            roots[index].sizeBytes += UInt64(max(0, st.st_blocks)) * 512
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0, let sub = fdopendir(child) else {
                if child >= 0 { close(child) }
                roots[index].complete = false
                return true
            }
            stack.append(sub)
        } else {
            if st.st_nlink > 1, !seen.insert(FileID(dev: st.st_dev, ino: st.st_ino)).inserted { return true }
            roots[index].sizeBytes += UInt64(max(0, st.st_blocks)) * 512
        }
        return true
    }

    private func open(_ index: Int) {
        let path = roots[index].path!
        switch Self.access(path) {
        case .redirected: roots[index].state = .notMeasured("redirected"); return
        case .absent: roots[index].state = .absent; return
        case .unreadable: roots[index].state = .notMeasured("unreadable"); return
        case .ok: break
        }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var st = stat()
        guard fd >= 0, fstat(fd, &st) == 0, let dir = fdopendir(fd) else {
            let missing = errno == ENOENT || errno == ENOTDIR
            if fd >= 0 { close(fd) }
            roots[index].state = missing ? .absent : .notMeasured("unreadable")
            return
        }
        roots[index].state = .walking
        roots[index].sizeBytes = UInt64(max(0, st.st_blocks)) * 512
        stack = [dir]
        current = (index, st.st_dev)
    }

    private func finish(_ reason: String, cpu: TimeInterval) {
        stack.forEach { closedir($0) }
        stack = []
        current = nil
        let end = env.now(), start = startedAt ?? end
        var directories: [(Int, StorageReport.Directory)] = [], missing: [StorageReport.NotMeasured] = []
        for (i, root) in roots.enumerated() {
            let path = root.path.map { StoragePath.report($0, home: homePath) }
            switch root.state {
            case .done, .walking:
                directories.append((i, .init(path: path!, sizeBytes: root.sizeBytes, complete: root.state == .done && root.complete,
                                             mountPath: root.mountPath, source: root.source)))
            case .pending: missing.append(.init(path: path, reason: "not_reached", source: root.source))
            case .notMeasured(let why): missing.append(.init(path: why == "unresolved_setting" ? nil : path, reason: why, source: root.source))
            case .absent: break
            }
        }
        directories.sort { $0.1.sizeBytes == $1.1.sizeBytes ? $0.0 < $1.0 : $0.1.sizeBytes > $1.1.sizeBytes }
        let result = StorageReport(passStartedAt: start, measuredAt: end, passSeconds: (end.timeIntervalSince(start) * 1000).rounded() / 1000,
                                   cpuSeconds: (cpu * 1000).rounded() / 1000, slices: slices, slicesSkippedForCpu: slicesSkippedForCpu,
                                   endReason: reason, derivedDataLocation: derivedDataLocation, deviceSupportOmitted: deviceSupportOmitted,
                                   directories: directories.map(\.1), notMeasured: missing)
        report = result
        try? StorageFiles.write(result, StorageFiles.report, home: env.aistatsHome)
    }
}
