import Darwin
import Foundation

public enum AIStatsPaths {
    /// `$AISTATS_HOME`, or `~/Library/Application Support/AIStats`.
    public static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["AISTATS_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AIStats", isDirectory: true)
    }

    public static let appBundleIdentifier = "com.oozoofrog.aistats"
}

/// Small helpers shared by the stores: a directory, an exclusive `flock`, JSON-lines files.
final class JSONLinesFile {
    let url: URL
    private let lockURL: URL

    static let compactionCheckInterval = 50
    private var appendsSinceCheck = 0
    private var checkedOnce = false

    init(url: URL) {
        self.url = url
        self.lockURL = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".lock")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func read<T: Decodable>(_ type: T.Type) -> [T] {
        (try? withLock(shared: true) { readUnlocked(type) }) ?? []
    }

    /// Appends `value`; when the file holds more than `2 * keep` lines it is rewritten with the newest `keep`.
    func append<T: Codable>(_ value: T, keep: Int) throws {
        try withLock(shared: false) {
            var line = try Self.encoder.encode(value)
            line.append(UInt8(ascii: "\n"))
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw StoreError.io("open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard written == line.count else { throw StoreError.io("short write to \(url.lastPathComponent)") }

            // Only check the size on the first append and then every `compactionCheckInterval`
            // appends from this process. Counting newlines in the raw bytes avoids decoding JSON.
            appendsSinceCheck += 1
            if appendsSinceCheck >= Self.compactionCheckInterval || !checkedOnce {
                checkedOnce = true
                appendsSinceCheck = 0
                guard let data = try? Data(contentsOf: url) else { return }
                let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
                if lines.count > keep * 2 {
                    var kept = Data()
                    for l in lines.suffix(keep) {
                        kept.append(contentsOf: l)
                        kept.append(UInt8(ascii: "\n"))
                    }
                    try kept.write(to: url, options: .atomic)
                    chmod(url.path, 0o600)
                }
            }
        }
    }

    private func readUnlocked<T: Decodable>(_ type: T.Type) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? Self.decoder.decode(T.self, from: Data($0)) }
    }

    private func withLock<R>(shared: Bool, _ body: () throws -> R) throws -> R {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("open lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        while flock(fd, shared ? LOCK_SH : LOCK_EX) != 0 {
            if errno != EINTR { throw StoreError.io("flock: \(String(cString: strerror(errno)))") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case io(String)
    public var description: String {
        switch self { case .io(let d): return "AIStats storage failed: \(d)" }
    }
}

// MARK: - History

/// One recorded sample. Kept small because the app writes one every refresh. A metric that could not be
/// read in that sample is left out (nil), never recorded as 0.
public struct HistoryPoint: Codable, Sendable, Hashable {
    public var t: Date
    public var cpuPercent: Double?
    public var memoryUsedPercent: Double?
    public var memoryUsedBytes: UInt64?
    /// "normal", "warning", "critical", or "unknown" when it could not be read.
    public var memoryPressure: String
    public var receivedBytesPerSecond: Double?
    public var sentBytesPerSecond: Double?
    public var diskAvailableBytes: UInt64?
    public var batteryPercent: Int?

    public init(snapshot s: Snapshot) {
        t = s.timestamp
        let cpu = s.isAvailable("cpu"), memory = s.isAvailable("memory"), network = s.isAvailable("network")
        cpuPercent = cpu ? s.cpu.usagePercent : nil
        memoryUsedPercent = memory ? (s.memory.usedPercent * 10).rounded() / 10 : nil
        memoryUsedBytes = memory ? s.memory.usedBytes : nil
        memoryPressure = s.isAvailable("memoryPressure") ? s.memory.pressure : "unknown"
        receivedBytesPerSecond = network ? s.network.receivedBytesPerSecond : nil
        sentBytesPerSecond = network ? s.network.sentBytesPerSecond : nil
        diskAvailableBytes = s.isAvailable("disk") ? s.disk?.availableBytes : nil
        batteryPercent = s.battery?.percent
    }
}

/// Rolling history written by the menu bar app and read by agents.
public final class HistoryStore: @unchecked Sendable {
    /// Keep one hour at the app's 2-second refresh.
    public static let capacity = 1800
    /// If the newest point is older than this, the app is not recording.
    public static let staleAfter: TimeInterval = 15

    private let file: JSONLinesFile

    public init(directory: URL = AIStatsPaths.home) {
        file = JSONLinesFile(url: directory.appendingPathComponent("history.jsonl"))
    }

    public func record(_ point: HistoryPoint) throws {
        try file.append(point, keep: Self.capacity)
    }

    public func points(since: Date) -> [HistoryPoint] {
        file.read(HistoryPoint.self).filter { $0.t >= since }
    }

    public func latest() -> HistoryPoint? {
        file.read(HistoryPoint.self).last
    }

    public func isRecording(now: Date = Date()) -> Bool {
        guard let last = latest() else { return false }
        return now.timeIntervalSince(last.t) < Self.staleAfter
    }
}

public struct HistoryResult: Encodable, Sendable {
    public let minutes: Int
    public let recording: Bool
    public let summary: HistorySummary?
    public let startCommand: String?
    public let fallbackTool: String?
    public let notes: [String]?

    public init(minutes: Int, recording: Bool, summary: HistorySummary?) {
        self.minutes = minutes
        self.recording = recording
        self.summary = summary
        startCommand = recording ? nil : "open -b " + AIStatsPaths.appBundleIdentifier
        fallbackTool = summary == nil ? "get_system_stats" : nil
        notes = !recording && summary != nil ? ["The AIStats app is not recording now; this history ends at the last recorded sample."] : nil
    }

    public var text: String {
        if let summary { return ([summary.text] + (notes ?? [])).joined(separator: "\n") }
        let state = startCommand.map { "not running (start it with: " + $0 + ")" } ?? "running but has not recorded this window yet"
        return "No history for the last \(minutes) minutes. The AIStats menu bar app records history while it runs; it is \(state). get_system_stats works without it."
    }
}

public struct HistorySummary: Codable, Sendable {
    public struct Range: Codable, Sendable {
        public var min: Double
        public var average: Double
        public var max: Double
    }

    public var from: Date
    public var to: Date
    public var sampleCount: Int
    /// Over the samples where the metric was read; absent when none had a reading.
    public var cpuPercent: Range?
    public var memoryUsedPercent: Range?
    public var receivedBytesPerSecond: Range?
    public var sentBytesPerSecond: Range?
    /// Samples without a reading, per metric ("cpu", "memory", "network", "memoryPressure", "disk").
    public var unavailableSamples: [String: Int]?
    /// Highest memory pressure seen in the window ("unknown" if it was never read).
    public var worstMemoryPressure: String
    /// Change in free disk space over the window (negative = space was used).
    public var diskAvailableChangeBytes: Int64?
    /// At most `maxPoints` evenly spaced points (window averages) for trend reading; empty when 0 were asked for.
    public var points: [HistoryPoint]

    static func range(_ values: [Double]) -> Range? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        return Range(min: lo, average: (avg * 10).rounded() / 10, max: hi)
    }

    public static func make(from points: [HistoryPoint], maxPoints: Int = 60) -> HistorySummary? {
        guard let first = points.first, let last = points.last else { return nil }
        let order = ["normal": 1, "warning": 2, "critical": 3]
        let known = points.map(\.memoryPressure).filter { order[$0] != nil }
        let worst = known.max { order[$0]! < order[$1]! } ?? "unknown"
        var diskChange: Int64?
        if let a = points.first(where: { $0.diskAvailableBytes != nil })?.diskAvailableBytes,
           let b = points.last(where: { $0.diskAvailableBytes != nil })?.diskAvailableBytes {
            diskChange = Int64(b) - Int64(a)
        }
        var missing: [String: Int] = [:]
        func count(_ name: String, _ n: Int) { if n > 0 { missing[name] = n } }
        count("cpu", points.filter { $0.cpuPercent == nil }.count)
        count("memory", points.filter { $0.memoryUsedPercent == nil }.count)
        count("network", points.filter { $0.receivedBytesPerSecond == nil }.count)
        count("memoryPressure", points.count - known.count)
        count("disk", points.filter { $0.diskAvailableBytes == nil }.count)
        return HistorySummary(from: first.t, to: last.t, sampleCount: points.count,
                              cpuPercent: range(points.compactMap(\.cpuPercent)),
                              memoryUsedPercent: range(points.compactMap(\.memoryUsedPercent)),
                              receivedBytesPerSecond: range(points.compactMap(\.receivedBytesPerSecond)),
                              sentBytesPerSecond: range(points.compactMap(\.sentBytesPerSecond)),
                              unavailableSamples: missing.isEmpty ? nil : missing,
                              worstMemoryPressure: worst, diskAvailableChangeBytes: diskChange,
                              points: downsample(points, to: maxPoints))
    }

    /// Averages consecutive buckets so the result has at most `count` points (none for `count <= 0`).
    /// Bucket edges are integer (`i * n / count`), so every point lands in exactly one bucket and the
    /// last bucket ends with the newest point. Averages skip points without a reading.
    static func downsample(_ points: [HistoryPoint], to count: Int) -> [HistoryPoint] {
        guard count > 0 else { return [] }
        guard points.count > count else { return points }
        let n = points.count
        func avg(_ values: [Double], scale: Double) -> Double? {
            values.isEmpty ? nil : (values.reduce(0, +) / Double(values.count) * scale).rounded() / scale
        }
        return (0..<count).map { i in
            let slice = points[(i * n / count)..<((i + 1) * n / count)]
            var p = slice.last!
            p.cpuPercent = avg(slice.compactMap(\.cpuPercent), scale: 10)
            p.memoryUsedPercent = avg(slice.compactMap(\.memoryUsedPercent), scale: 10)
            p.receivedBytesPerSecond = avg(slice.compactMap(\.receivedBytesPerSecond), scale: 1)
            p.sentBytesPerSecond = avg(slice.compactMap(\.sentBytesPerSecond), scale: 1)
            return p
        }
    }

    public var text: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        var lines = ["\(f.string(from: from))–\(f.string(from: to)), \(sampleCount) samples"]
        if let c = cpuPercent {
            lines.append(String(format: "CPU min %.0f%% avg %.0f%% max %.0f%%", c.min, c.average, c.max))
        } else {
            lines.append("CPU not measured in this window")
        }
        if let m = memoryUsedPercent {
            lines.append(String(format: "Memory min %.0f%% avg %.0f%% max %.0f%%, worst pressure %@", m.min, m.average, m.max, worstMemoryPressure))
        } else {
            lines.append("Memory not measured in this window, worst pressure \(worstMemoryPressure)")
        }
        if let rx = receivedBytesPerSecond, let tx = sentBytesPerSecond {
            lines.append("Network ↓ avg \(Format.rate(rx.average)) max \(Format.rate(rx.max)), ↑ avg \(Format.rate(tx.average)) max \(Format.rate(tx.max))")
        } else {
            lines.append("Network not measured in this window")
        }
        if let d = diskAvailableChangeBytes {
            lines.append("Disk free space " + (d < 0 ? "dropped \(Format.bytes(UInt64(-d)))" : "grew \(Format.bytes(UInt64(d)))"))
        }
        if let missing = unavailableSamples {
            lines.append("Samples without a reading: " + missing.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Agent activity

/// What agents did with AIStats: who is connected and which tools they called.
public final class ActivityStore: @unchecked Sendable {
    public static let logCapacity = 200

    public struct Presence: Codable, Hashable, Sendable {
        public var name: String
        public var pid: Int32
        public var client: String?
        public var connectedAt: Date
        public var lastSeen: Date
        /// The session process's start time, so a record isn't kept alive by a reused pid.
        public var startToken: String?

        public init(name: String, pid: Int32, client: String?, connectedAt: Date, lastSeen: Date, startToken: String? = nil) {
            self.name = name; self.pid = pid; self.client = client
            self.connectedAt = connectedAt; self.lastSeen = lastSeen; self.startToken = startToken
        }

        var isAlive: Bool {
            guard ActivityStore.isAlive(pid) else { return false }
            guard let startToken else { return true }
            // Our own sessions are readable; an unreadable pid now belongs to someone else.
            return Proc.usage(pid).map { String($0.start) == startToken } ?? false
        }
    }

    public struct Call: Codable, Hashable, Sendable, Identifiable {
        public var date: Date
        public var agent: String
        public var tool: String
        /// Short human-readable description, e.g. "top 10 by memory".
        public var detail: String?
        public var id: String { "\(date.timeIntervalSince1970)-\(agent)-\(tool)" }

        public init(date: Date = Date(), agent: String, tool: String, detail: String? = nil) {
            self.date = date; self.agent = agent; self.tool = tool; self.detail = detail
        }
    }

    public let directory: URL
    private let log: JSONLinesFile
    var agentsURL: URL { directory.appendingPathComponent("agents", isDirectory: true) }

    public init(directory: URL = AIStatsPaths.home) {
        self.directory = directory
        log = JSONLinesFile(url: directory.appendingPathComponent("activity.jsonl"))
    }

    public func record(_ call: Call) {
        try? log.append(call, keep: Self.logCapacity)
    }

    public func recentCalls(limit: Int) -> [Call] {
        Array(log.read(Call.self).suffix(limit))
    }

    /// Cheap change detector for the activity log and the agents folder (modification times and size),
    /// so a poller can skip reading and decoding when nothing changed.
    public func changeToken() -> String {
        func stamp(_ path: String) -> String {
            var st = stat()
            guard stat(path, &st) == 0 else { return "-" }
            return "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec).\(st.st_size)"
        }
        return stamp(directory.appendingPathComponent("activity.jsonl").path) + "|" + stamp(agentsURL.path)
    }

    public func updatePresence(_ presence: Presence) {
        try? FileManager.default.createDirectory(at: agentsURL, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONLinesFile.encoder.encode(presence) {
            try? data.write(to: presenceURL(presence.name), options: .atomic)
        }
    }

    public func removePresence(name: String, pid: Int32) {
        let url = presenceURL(name)
        if let data = try? Data(contentsOf: url),
           let p = try? JSONLinesFile.decoder.decode(Presence.self, from: data), p.pid == pid {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Agents whose process is still running. Records of exited processes are deleted.
    public func connectedAgents() -> [Presence] {
        let files = (try? FileManager.default.contentsOfDirectory(at: agentsURL, includingPropertiesForKeys: nil)) ?? []
        var result: [Presence] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let p = try? JSONLinesFile.decoder.decode(Presence.self, from: data) else { continue }
            if p.isAlive { result.append(p) } else { try? FileManager.default.removeItem(at: file) }
        }
        return result.sorted { $0.connectedAt < $1.connectedAt }
    }

    /// `base`, or `base-2`, `base-3`… when another live agent already uses the name.
    public func uniqueAgentName(_ base: String, pid: Int32) -> String {
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = cleaned.isEmpty ? "agent" : String(cleaned.prefix(64))
        let taken = Set(connectedAgents().filter { $0.pid != pid }.map(\.name))
        if !taken.contains(root) { return root }
        var n = 2
        while taken.contains("\(root)-\(n)") { n += 1 }
        return "\(root)-\(n)"
    }

    private func presenceURL(_ name: String) -> URL {
        agentsURL.appendingPathComponent(Self.sanitize(name) + ".json")
    }

    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = String(mapped.prefix(64))
        return trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) ? "_" : trimmed
    }
}
