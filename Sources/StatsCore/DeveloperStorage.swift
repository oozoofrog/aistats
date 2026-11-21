import Darwin
import DiskArbitration
import Foundation

/// The latest Storage Pass result as the menu app stores it in `storage/report.json` (ADR 0010).
public struct StorageReport: Codable, Sendable, Equatable {
    public struct Directory: Codable, Sendable, Equatable {
        public var path: String
        public var sizeBytes: UInt64
        public var complete: Bool
        public var mountPath: String
        public var source: String?
        public init(path: String, sizeBytes: UInt64, complete: Bool, mountPath: String, source: String? = nil) {
            self.path = path; self.sizeBytes = sizeBytes; self.complete = complete; self.mountPath = mountPath; self.source = source
        }
    }
    public struct NotMeasured: Codable, Sendable, Equatable {
        public var path: String?
        public var reason: String
        public var source: String?
        public init(path: String?, reason: String, source: String? = nil) { self.path = path; self.reason = reason; self.source = source }
    }

    public static let currentSchema = 1
    public var schemaVersion = StorageReport.currentSchema
    public var scope = "current_user"
    public var sizeKind = "allocated_blocks"
    public var passStartedAt: Date
    public var measuredAt: Date
    public var passSeconds: Double
    public var cpuSeconds: Double
    public var slices: Int
    public var slicesSkippedForCpu: Int
    public var endReason: String
    public var derivedDataLocation: String
    public var deviceSupportOmitted: Int
    public var directories: [Directory]
    public var directoriesOmitted: Int?
    public var notMeasured: [NotMeasured]
    public var notMeasuredOmitted: Int?

    public init(passStartedAt: Date, measuredAt: Date, passSeconds: Double, cpuSeconds: Double, slices: Int, slicesSkippedForCpu: Int,
                endReason: String, derivedDataLocation: String, deviceSupportOmitted: Int, directories: [Directory], notMeasured: [NotMeasured]) {
        self.passStartedAt = passStartedAt; self.measuredAt = measuredAt; self.passSeconds = passSeconds; self.cpuSeconds = cpuSeconds
        self.slices = slices; self.slicesSkippedForCpu = slicesSkippedForCpu; self.endReason = endReason
        self.derivedDataLocation = derivedDataLocation; self.deviceSupportOmitted = deviceSupportOmitted
        self.directories = directories; self.notMeasured = notMeasured
    }
}

/// `lastPassStartedAt`, persisted before the first slice of each pass.
public struct StorageSchedule: Codable, Sendable {
    public var schemaVersion = StorageReport.currentSchema
    public var lastPassStartedAt: Date
    public init(lastPassStartedAt: Date) { self.lastPassStartedAt = lastPassStartedAt }
}

/// Files under `<AIStats home>/storage`: mode 0600 in a 0700 directory, each replaced by a rename.
public enum StorageFiles {
    public static let report = "report.json", schedule = "schedule.json"

    public static func directory(_ home: URL) -> URL { home.appendingPathComponent("storage", isDirectory: true) }

    public static func write<T: Encodable>(_ value: T, _ name: String, home: URL) throws {
        let dir = directory(home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let data = try JSONLinesFile.encoder.encode(value)
        let temp = dir.appendingPathComponent(".\(name).\(getpid()).\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("open \(name): \(String(cString: strerror(errno)))") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temp.path, dir.appendingPathComponent(name).path) == 0 else {
            unlink(temp.path)
            throw StoreError.io("write \(name) failed")
        }
    }

    private struct Version: Decodable { var schemaVersion: Int }

    enum Read<T> { case missing, unreadable, unsupported, value(T) }

    static func read<T: Decodable>(_ type: T.Type, _ name: String, home: URL) -> Read<T> {
        let url = directory(home).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        guard let version = try? JSONLinesFile.decoder.decode(Version.self, from: data) else { return .unreadable }
        guard version.schemaVersion == StorageReport.currentSchema else { return .unsupported }
        guard let value = try? JSONLinesFile.decoder.decode(T.self, from: data) else { return .unreadable }
        return .value(value)
    }

    /// The report, or why it can't be used: `no_report`, `unreadable` or `unsupported_schema`.
    public static func readReport(home: URL) -> (report: StorageReport?, reason: String?) {
        switch read(StorageReport.self, report, home: home) {
        case .value(let r): return (r, nil)
        case .missing: return (nil, "no_report")
        case .unreadable: return (nil, "unreadable")
        case .unsupported: return (nil, "unsupported_schema")
        }
    }

    /// nil when no schedule file exists; `.some(nil)` when it is unreadable or has an unknown schema.
    public static func readSchedule(home: URL) -> Date?? {
        switch read(StorageSchedule.self, schedule, home: home) {
        case .missing: return nil
        case .value(let s): return .some(s.lastPassStartedAt)
        case .unreadable, .unsupported: return .some(nil)
        }
    }
}

// MARK: - Volume List

public struct MountEntry: Sendable {
    public var path: String
    public var fromName: String
    public var fileSystem: String
    public var flags: UInt32
    /// Cached statistics from the mount table (`MNT_NOWAIT`); nil when the table gives none.
    public var totalBytes: UInt64?
    public var availableBytes: UInt64?
    public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }

    public init(path: String, fromName: String = "", fileSystem: String = "apfs", flags: UInt32, totalBytes: UInt64? = nil, availableBytes: UInt64? = nil) {
        self.path = path; self.fromName = fromName; self.fileSystem = fileSystem; self.flags = flags
        self.totalBytes = totalBytes; self.availableBytes = availableBytes
    }

    /// `getfsstat` with `MNT_NOWAIT`: cached statistics, no request to the file systems.
    public static func table() -> [MountEntry] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = Array(repeating: statfs(), count: Int(count) + 8)
        let filled = getfsstat(&buffer, Int32(MemoryLayout<statfs>.stride * buffer.count), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        func text<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return buffer.prefix(Int(filled)).map { fs in
            let block = UInt64(fs.f_bsize)
            return MountEntry(path: text(fs.f_mntonname), fromName: text(fs.f_mntfromname), fileSystem: text(fs.f_fstypename),
                              flags: fs.f_flags, totalBytes: fs.f_blocks > 0 ? UInt64(fs.f_blocks) * block : nil,
                              availableBytes: fs.f_blocks > 0 ? UInt64(fs.f_bavail) * block : nil)
        }
    }
}

public struct VolumeStats: Sendable {
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var availableForImportantUsageBytes: UInt64?
    public var apfsContainer: String?
    public init(totalBytes: UInt64, availableBytes: UInt64, availableForImportantUsageBytes: UInt64? = nil, apfsContainer: String? = nil) {
        self.totalBytes = totalBytes; self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes; self.apfsContainer = apfsContainer
    }

    nonisolated(unsafe) private static let diskSession = DASessionCreate(kCFAllocatorDefault)

    /// Fresh statistics of one local volume, plus the DiskArbitration whole disk of an APFS volume.
    public static func live(_ mount: MountEntry) -> VolumeStats? {
        var fs = statfs()
        guard statfs(mount.path, &fs) == 0 else { return nil }
        let block = UInt64(fs.f_bsize)
        let important = (try? URL(fileURLWithPath: mount.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        var container: String?
        if mount.fileSystem == "apfs", mount.fromName.hasPrefix("/dev/"), let session = diskSession,
           let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, String(mount.fromName.dropFirst(5))),
           let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole) {
            container = String(cString: name)
        }
        return VolumeStats(totalBytes: UInt64(fs.f_blocks) * block, availableBytes: UInt64(fs.f_bavail) * block,
                           availableForImportantUsageBytes: important.map { UInt64(max(0, $0)) }, apfsContainer: container)
    }
}

public struct StorageVolume: Encodable, Sendable {
    public var mountPath: String
    public var totalBytes: UInt64?
    public var availableBytes: UInt64?
    public var availableForImportantUsageBytes: UInt64?
    public var apfsContainer: String?
    public var network: Bool?
}

/// Remembers reads that missed their deadline and still block their helper thread, so that a caller starts at most
/// one blocked thread per key instead of one per call.
public final class ProbeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var running = Set<Int>()
    private var stuck: [String: Int] = [:]

    public init() {}

    /// A probe id, or nil while an earlier read for `key` is blocked.
    public func start(_ key: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard stuck[key] == nil else { return nil }
        next += 1
        running.insert(next)
        return next
    }

    public func finish(_ key: String, _ probe: Int) {
        lock.lock(); defer { lock.unlock() }
        running.remove(probe)
        if stuck[key] == probe { stuck[key] = nil }
    }

    /// Marks `key` as blocked when its read has not finished.
    public func timedOut(_ key: String, _ probe: Int) {
        lock.lock(); defer { lock.unlock() }
        if running.contains(probe) { stuck[key] = probe }
    }

    public func isBlocked(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stuck[key] != nil }
}

public enum VolumeList {
    public static let bootData = "/System/Volumes/Data"
    static let deadline: TimeInterval = 0.15

    /// A statistics read that blocks keeps its thread. A later call starts no second read for that mount and lists it
    /// as unavailable until the blocked read returns.
    static let probes = ProbeRegistry()

    /// The boot data volume and every mount Finder shows. Local statistics are read in parallel and a
    /// volume that misses the deadline is unavailable; network volumes use the cached mount-table statistics.
    /// At most one statistics read runs per mount path at a time.
    public static func build(mounts: [MountEntry], stats: @escaping @Sendable (MountEntry) -> VolumeStats? = { VolumeStats.live($0) })
        -> (volumes: [StorageVolume], omitted: Int, unavailable: [String]) {
        let shown = mounts.filter { $0.path == "/" || $0.path == bootData || $0.flags & UInt32(MNT_DONTBROWSE) == 0 }
            .sorted { rank($0.path) == rank($1.path) ? $0.path < $1.path : rank($0.path) < rank($1.path) }
        let lock = NSLock(), finished = DispatchSemaphore(value: 0)
        var read: [Int: VolumeStats] = [:]
        let local = shown.enumerated().filter { $0.element.isLocal }.compactMap { i, mount in
            probes.start(mount.path).map { (i, mount, $0) }
        }
        for (i, mount, probe) in local {
            Thread.detachNewThread {
                let value = stats(mount)
                probes.finish(mount.path, probe)
                lock.lock(); read[i] = value; lock.unlock()
                finished.signal()
            }
        }
        let end = DispatchTime.now() + deadline
        for _ in local where finished.wait(timeout: end) == .timedOut { break }
        lock.lock(); let done = read; lock.unlock()
        for (i, mount, probe) in local where done[i] == nil { probes.timedOut(mount.path, probe) }
        var volumes: [StorageVolume] = [], unavailable: [String] = []
        for (i, mount) in shown.enumerated() {
            var volume = StorageVolume(mountPath: mount.path, network: mount.isLocal ? nil : true)
            if mount.isLocal, let s = done[i] {
                volume.totalBytes = s.totalBytes
                volume.availableBytes = s.availableBytes
                volume.availableForImportantUsageBytes = s.availableForImportantUsageBytes
                volume.apfsContainer = s.apfsContainer
            } else if !mount.isLocal, let total = mount.totalBytes, let available = mount.availableBytes {
                volume.totalBytes = total
                volume.availableBytes = available
            } else {
                unavailable.append(mount.path)
            }
            volumes.append(volume)
        }
        return (volumes, mounts.count - volumes.count, unavailable)
    }

    private static func rank(_ path: String) -> Int { path == "/" ? 0 : path == bootData ? 1 : 2 }
}

// MARK: - Drain Rate

public struct DrainRate: Codable, Sendable, Equatable {
    public var drainBytesPerHour: Int64?
    public var windowSeconds: Int?
    public var diskSamples: Int
    public var reason: String?

    public static let window: TimeInterval = 3600

    /// From the first and last distinct Disk Read Times in the hour that ends at `now`. Positive means free space decreased.
    public static func make(points: [HistoryPoint], now: Date) -> DrainRate {
        var readings: [Date: UInt64] = [:]
        for p in points {
            guard let at = p.diskReadAt, let bytes = p.diskAvailableBytes, at <= now, now.timeIntervalSince(at) <= window,
                  readings[at] == nil else { continue }
            readings[at] = bytes
        }
        let times = readings.keys.sorted()
        guard let first = times.first, let last = times.last, times.count >= 2 else {
            return DrainRate(diskSamples: times.count, reason: "fewer_than_two_disk_readings")
        }
        let span = last.timeIntervalSince(first)
        let drop = Double(readings[first]!) - Double(readings[last]!)
        return DrainRate(drainBytesPerHour: Int64((drop / (span / 3600)).rounded()), windowSeconds: Int(span.rounded()), diskSamples: times.count)
    }
}

// MARK: - Tool result

/// `get_developer_storage` and `aistats storage --json`: built at call time from the mount table, the stored
/// report and the recorded history. No directory is walked here (STO-014).
public struct DeveloperStorage: Encodable, Sendable {
    public var appRunning: Bool
    public var startCommand: String?
    public var volumes: [StorageVolume]
    public var volumesOmitted: Int
    public var unavailable: [String]
    public var storage: StorageReport?
    public var storageReason: String?
    public var ageSeconds: Int?
    public var drain: DrainRate

    enum CodingKeys: String, CodingKey {
        case appRunning, startCommand, volumes, volumesOmitted, unavailable, storage, storageReason, ageSeconds, drain
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appRunning, forKey: .appRunning)
        try c.encodeIfPresent(startCommand, forKey: .startCommand)
        try c.encode(volumes, forKey: .volumes)
        try c.encode(volumesOmitted, forKey: .volumesOmitted)
        try c.encode(unavailable, forKey: .unavailable)
        try c.encode(storage, forKey: .storage)
        try c.encodeIfPresent(storageReason, forKey: .storageReason)
        try c.encodeIfPresent(ageSeconds, forKey: .ageSeconds)
        try c.encode(drain, forKey: .drain)
    }

    public static func collect(home: URL = AIStatsPaths.home, now: Date = Date(), mounts: [MountEntry] = MountEntry.table(),
                               stats: @escaping @Sendable (MountEntry) -> VolumeStats? = { VolumeStats.live($0) }) -> DeveloperStorage {
        let points = HistoryStore(directory: home).points(since: now.addingTimeInterval(-DrainRate.window))
        let running = points.last.map { now.timeIntervalSince($0.t) < HistoryStore.staleAfter } ?? false
        let list = VolumeList.build(mounts: mounts, stats: stats)
        let (report, reason) = StorageFiles.readReport(home: home)
        return DeveloperStorage(appRunning: running, startCommand: running ? nil : "open -b " + AIStatsPaths.appBundleIdentifier,
                                volumes: list.volumes, volumesOmitted: list.omitted, unavailable: list.unavailable,
                                storage: report, storageReason: reason,
                                ageSeconds: report.map { max(0, Int(now.timeIntervalSince($0.measuredAt))) },
                                drain: DrainRate.make(points: points, now: now))
    }

    /// One Trimming step: the last volume other than `/` and the boot data volume (STO-007), then the smallest
    /// directories, then `notMeasured`.
    mutating func trim() -> Bool {
        if let last = volumes.lastIndex(where: { $0.mountPath != "/" && $0.mountPath != VolumeList.bootData }) {
            let removed = volumes.remove(at: last)
            unavailable.removeAll { $0 == removed.mountPath }
            volumesOmitted += 1
            return true
        }
        guard var report = storage else { return false }
        defer { storage = report }
        if !report.directories.isEmpty {
            report.directories.removeLast()
            report.directoriesOmitted = (report.directoriesOmitted ?? 0) + 1
            return true
        }
        if !report.notMeasured.isEmpty {
            report.notMeasured.removeLast()
            report.notMeasuredOmitted = (report.notMeasuredOmitted ?? 0) + 1
            return true
        }
        return false
    }

    /// Shortens paths over 96 bytes to their last 64 characters, marked with `…` (RSZ-009, RSZ-010).
    mutating func clipPaths() {
        func clip(_ s: String) -> String { s.utf8.count > 96 ? "…" + String(s.unicodeScalars.suffix(64)) : s }
        volumes = volumes.map { var v = $0; v.mountPath = clip(v.mountPath); return v }
        unavailable = unavailable.map(clip)
        guard var report = storage else { return }
        report.directories = report.directories.map { var d = $0; d.path = clip(d.path); d.mountPath = clip(d.mountPath); return d }
        report.notMeasured = report.notMeasured.map { var n = $0; n.path = n.path.map(clip); return n }
        storage = report
    }

    public var summaryLine: String {
        var parts = ["\(volumes.count) volume\(volumes.count == 1 ? "" : "s")"]
        if let storage, let ageSeconds {
            let total = storage.directories.reduce(UInt64(0)) { $0 + $1.sizeBytes }
            parts.append("developer folders \(Format.bytes(total)) in \(storage.directories.count), measured \(ageSeconds / 60) min ago")
        } else {
            parts.append("no storage report (\(storageReason ?? "no_report"))")
        }
        if let rate = drain.drainBytesPerHour {
            parts.append(rate >= 0 ? "free space dropping \(Format.bytes(UInt64(rate)))/h" : "free space growing \(Format.bytes(UInt64(-rate)))/h")
        }
        if !appRunning { parts.append("app not running") }
        return parts.joined(separator: "; ") + "."
    }

    public func text() -> String {
        var lines = [summaryLine]
        for v in volumes {
            let free = v.availableBytes.map { Format.bytes($0) + " free" } ?? "unavailable"
            let total = v.totalBytes.map { " of " + Format.bytes($0) } ?? ""
            lines.append("  \(v.mountPath)  \(free)\(total)" + (v.apfsContainer.map { "  container \($0)" } ?? ""))
        }
        if let storage {
            for d in storage.directories {
                lines.append("  \(Format.bytes(d.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(d.path)" + (d.complete ? "" : "  (incomplete)"))
            }
            for n in storage.notMeasured { lines.append("  not measured: \(n.path ?? "Xcode DerivedData setting") (\(n.reason))") }
        }
        if let reason = drain.reason { lines.append("Drain rate: \(reason)") }
        if let startCommand { lines.append("Start the AIStats app to record history and measure folders: \(startCommand)") }
        return lines.joined(separator: "\n")
    }
}
