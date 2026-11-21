import CryptoKit
import Darwin
import Foundation

/// Statistics over the stored Runs of one Command Signature (SDD 0015, ADR 0011).
public struct Baseline: Codable, Sendable, Equatable {
    public static let minimumRuns = 5

    public var label: String
    public var runs: Int
    public var medianSeconds: Double?
    public var p90Seconds: Double?
    public var maxSeconds: Double?
    public var lastRunAt: Date?
    public var suggestedTimeoutSeconds: Int?
    public var resolutionSeconds: Double?
    /// The Command Signature digest; never encoded.
    var signature = ""

    enum CodingKeys: String, CodingKey {
        case label, runs, medianSeconds, p90Seconds, maxSeconds, lastRunAt, suggestedTimeoutSeconds, resolutionSeconds
    }

    /// `tenths`: Run Durations in tenths of a second; `lastRunAt`: newest `exitedAt` in Unix seconds.
    init(label: String, signature: String, tenths: [Int], lastRunAt: Int, resolutionTenths: Int) {
        let sorted = tenths.sorted(), n = sorted.count
        self.label = label; self.signature = signature; runs = n
        guard n >= Self.minimumRuns else { return }
        medianSeconds = (n % 2 == 1 ? Double(sorted[n / 2]) : (Double(sorted[n / 2 - 1] + sorted[n / 2]) / 2).rounded()) / 10
        let p90 = sorted[(9 * n + 9) / 10 - 1]
        p90Seconds = Double(p90) / 10
        maxSeconds = Double(sorted[n - 1]) / 10
        self.lastRunAt = Date(timeIntervalSince1970: TimeInterval(lastRunAt))
        suggestedTimeoutSeconds = min(7200, max(10, (p90 + 7) / 8))
        resolutionSeconds = Double(resolutionTenths) / 10
    }

    public var summaryLine: String {
        guard let median = medianSeconds, let p90 = p90Seconds, let timeout = suggestedTimeoutSeconds else {
            return "\(label): \(runs) run\(runs == 1 ? "" : "s"), statistics from \(Self.minimumRuns) runs"
        }
        return "\(label): \(runs) runs, median \(median) s, p90 \(p90) s, max \(maxSeconds ?? p90) s, suggested timeout \(timeout) s"
    }
}

// MARK: - Command Signature

enum CommandSignature {
    static let version = "v1"
    static let allowlist: [(basename: String, entries: [String])] = [
        ("xcodebuild", ["build", "build-for-testing", "test", "test-without-building", "analyze", "archive", "docbuild", "clean"]),
        ("swift", ["build", "test", "run"]),
        ("cargo", ["build", "check", "test", "bench", "run", "clippy"]),
        ("go", ["build", "test", "run", "vet"]),
    ]
    static let noValueFlags = ["-quiet", "-json", "-verbose", "-alltargets", "-parallelizeTargets", "-allowProvisioningUpdates",
                               "-allowProvisioningDeviceRegistration", "-skipUnavailableActions", "-skipPackageUpdates",
                               "-skipPackagePluginValidation", "-skipMacroValidation", "-disableAutomaticPackageResolution",
                               "-onlyUsePackageVersionsFromResolvedFile", "-hideShellScriptEnvironment", "-showBuildTimingSummary",
                               "-retry-tests-on-failure", "-run-tests-until-failure"]

    /// The prefix, the allowlist and the flag list in one text; a unit test pins its SHA-256 (DUR-038).
    static func canonical(allowlist: [(basename: String, entries: [String])] = CommandSignature.allowlist,
                          flags: [String] = CommandSignature.noValueFlags) -> String {
        ([version] + allowlist.map { $0.basename + ":" + $0.entries.joined(separator: ",") } + ["flags:" + flags.joined(separator: ",")])
            .joined(separator: "\n")
    }

    static func entries(_ basename: String) -> [String]? { allowlist.first { $0.basename == basename }?.entries }

    /// The Subcommand of an allowlisted tool from its arguments after argv[0]: "" without one, nil when unknown.
    static func subcommand(basename: String, arguments: [String]) -> String? {
        guard let entries = entries(basename) else { return "" }
        if basename == "xcodebuild" {
            var actions: [String] = []
            for (i, a) in arguments.enumerated() where entries.contains(a) {
                if i > 0, arguments[i - 1].hasPrefix("-"), !selfContained(arguments[i - 1]) { return nil }
                actions.append(a)
            }
            return actions.prefix(2).joined(separator: " ")
        }
        let i = basename == "cargo" && arguments.first?.hasPrefix("+") == true ? 1 : 0
        guard i < arguments.count else { return "" }
        if entries.contains(arguments[i]) { return arguments[i] }
        return arguments[i].hasPrefix("-") ? nil : ""
    }

    static func selfContained(_ flag: String) -> Bool { flag.contains("=") || flag.contains(":") || noValueFlags.contains(flag) }

    static func digest(key: SymmetricKey, path: String, subcommand: String) -> String {
        var message = Data(version.utf8)
        message.append(0); message.append(contentsOf: path.utf8); message.append(0); message.append(contentsOf: subcommand.utf8)
        return hex(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The path basename, then the Subcommand, cut at a character so its JSON string content is at most 64 bytes.
    static func label(path: String, subcommand: String) -> String {
        let base = (path as NSString).lastPathComponent
        let full = subcommand.isEmpty ? base : base + " " + subcommand
        var bytes = 0, out = ""
        for ch in full {
            let n = ch.unicodeScalars.reduce(0) { sum, u in
                sum + (u == "\"" || u == "\\" || u == "\n" || u == "\r" || u == "\t" ? 2 : u.value < 0x20 ? 6 : u.utf8.count)
            }
            guard bytes + n <= 64 else { break }
            bytes += n
            out.append(ch)
        }
        return out
    }
}

/// Reads an instance's executable path and arguments (tests inject failures).
struct CommandReader: Sendable {
    var path: @Sendable (Int32) -> String?
    var arguments: @Sendable (Int32) -> [String]?
    static let live = CommandReader(path: { Proc.path($0) }, arguments: { Proc.arguments($0) })
}

/// What AIStats last read of an Observed Instance's command: the path, and the Subcommand (nil when unknown or unread).
struct ObservedCommand {
    private(set) var path: String?
    private(set) var subcommand: String?
    private var name: String?

    var identity: (path: String, subcommand: String)? {
        guard let path, let subcommand else { return nil }
        return (path, subcommand)
    }

    /// Reads the path; reads the arguments of an allowlisted tool only when the path or name changed. The argument
    /// vector is discarded at once; only the matched tokens stay.
    mutating func observe(_ key: Proc.Key, name newName: String? = nil, reader: CommandReader) {
        guard let p = reader.path(key.pid), path == nil || p != path || (newName != nil && newName != name) else { return }
        let base = (p as NSString).lastPathComponent
        var sub: String? = ""
        if CommandSignature.entries(base) != nil {
            sub = reader.arguments(key.pid).flatMap { CommandSignature.subcommand(basename: base, arguments: $0) }
        }
        guard Proc.isAlive(key) else { return }
        path = p; subcommand = sub
        if let newName { name = newName }
    }
}

enum DurationClock {
    /// Continuous time (counts sleep) minus uptime (stops in sleep), in nanoseconds.
    static func offset() -> Int64 {
        Int64(bitPattern: Proc.ns(mach_continuous_time())) - Int64(bitPattern: Proc.ns(mach_absolute_time()))
    }
}

/// A Run waiting in the writer queue. It holds no digest; the writer signs it under the lock.
struct PendingRun: Sendable {
    var path: String
    var subcommand: String
    var pid: Int32
    var startToken: String
    var durationTenths: Int
    /// Unix seconds, rounded down.
    var exitedAt: Int
    var resolutionTenths: Int

    static let maxDurationTenths = 25_920_000

    /// The Run of one observed exit, or nil for a Discarded Run.
    static func make(command: ObservedCommand, key: Proc.Key, startNs: UInt64, exitNs: UInt64, lastAliveNs: UInt64,
                     firstOffset: Int64, exitOffset: Int64, intervalSeconds: Double, exitedAt: Date) -> PendingRun? {
        guard let id = command.identity, abs(exitOffset - firstOffset) <= 1_000_000_000,
              exitNs >= startNs, exitNs >= lastAliveNs else { return nil }
        let duration = Int((Double(exitNs - startNs) / 1e8).rounded())
        let resolution = Int((Double(exitNs - lastAliveNs) / 1e8).rounded(.up))
        guard duration <= maxDurationTenths, Double(resolution) <= (2 * intervalSeconds + 1) * 10 else { return nil }
        return PendingRun(path: id.path, subcommand: id.subcommand, pid: key.pid, startToken: key.token, durationTenths: duration,
                          exitedAt: Int(exitedAt.timeIntervalSince1970.rounded(.down)), resolutionTenths: resolution)
    }
}

/// One decoded line of `v1.jsonl`.
struct StoredRun {
    var sig: String
    var pid: Int32
    var startToken: UInt64
    var durationTenths: Int
    var exitedAt: Int
    var resolutionTenths: Int
    var range: Range<Int>
}

// MARK: - Store

/// The Duration Store: `durations/` under the AIStats home with `v1.jsonl`, its lock file and `key.json`.
/// Runs go through a serial writer queue; lookups use a per-process index and write nothing.
public final class DurationStore: @unchecked Sendable {
    static let maxBatch = 50
    static let maxRunsPerSignature = 64
    static let maxSignatures = 128
    static let maxAgeSeconds = 2_592_000
    static let compactAt = 16_384
    public static let drainBound: TimeInterval = 2

    let directory: URL
    var runsURL: URL { directory.appendingPathComponent("v1.jsonl") }
    var keyURL: URL { directory.appendingPathComponent("key.json") }
    var lockURL: URL { directory.appendingPathComponent(".v1.jsonl.lock") }

    private let state = NSLock()
    private var queued: [PendingRun] = []
    private var held = false
    private var drainDeadline: UInt64?
    private let writer = DispatchQueue(label: "aistats.durations", qos: .utility)
    private var appendedSinceCount = 0
    private var compacted = false

    private struct FileID: Equatable { var dev: Int32; var ino: UInt64; var size: Int64; var sec: Int; var nsec: Int }
    private struct Entry { var tenths: [Int]; var newest: Int; var resolution: Int }
    private struct Index { var ids: [FileID?]; var key: SymmetricKey?; var entries: [String: Entry]; var expiresAt: Int }
    private let indexLock = NSLock()
    private var index: Index?

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: DurationStore] = [:]

    /// The store of `home` shared by everything in this process.
    public static func forHome(_ home: URL) -> DurationStore {
        registryLock.lock(); defer { registryLock.unlock() }
        let path = home.standardizedFileURL.path
        if let s = registry[path] { return s }
        let s = DurationStore(home: home)
        registry[path] = s
        return s
    }

    init(home: URL) { directory = home.appendingPathComponent("durations", isDirectory: true) }

    // MARK: Writer

    /// Test hook: while true, queued Runs wait (a drain still writes them).
    var holdsWrites: Bool {
        get { state.lock(); defer { state.unlock() }; return held }
        set {
            state.lock(); held = newValue; state.unlock()
            if !newValue { writer.async { [self] in flush() } }
        }
    }

    var queuedCount: Int { state.lock(); defer { state.unlock() }; return queued.count }

    /// Constant work for the caller: the Run goes on the writer queue.
    func record(_ run: PendingRun) {
        state.lock(); queued.append(run); let hold = held; state.unlock()
        if !hold { writer.async { [self] in flush() } }
    }

    /// Writes the queued Runs, waiting at most `timeout` for the exclusive lock.
    public func drain(timeout: TimeInterval = DurationStore.drainBound) {
        state.lock(); drainDeadline = Proc.nowNs() + UInt64(timeout * 1e9); state.unlock()
        writer.sync { flush() }
        state.lock(); drainDeadline = nil; state.unlock()
    }

    private func deadlinePassed() -> Bool {
        state.lock(); defer { state.unlock() }
        return drainDeadline.map { Proc.nowNs() >= $0 } ?? false
    }

    private func flush() {
        while true {
            state.lock()
            guard !held || drainDeadline != nil else { state.unlock(); return }
            let batch = Array(queued.prefix(Self.maxBatch))
            state.unlock()
            guard !batch.isEmpty else { return }
            // A batch that could not be written stays queued for the next flush or the drain.
            guard (try? write(batch)) == true else { return }
            state.lock(); queued.removeFirst(min(batch.count, queued.count)); state.unlock()
        }
    }

    /// False when the drain bound passed before the lock was free; throws when the batch could not be written.
    private func write(_ batch: [PendingRun]) throws -> Bool {
        try withWriteLock(gaveUp: deadlinePassed) {
            let key = try currentKey()
            var lines = Data(), n = 0
            for run in batch where key.notBefore.map({ run.exitedAt >= $0 }) ?? true {
                lines.append(contentsOf: Self.line(run, sig: CommandSignature.digest(key: key.key, path: run.path, subcommand: run.subcommand)).utf8)
                n += 1
            }
            guard n > 0 else { return }
            if !compacted {
                try compact()
                compacted = true
                appendedSinceCount = 0
            } else if appendedSinceCount + n > Self.maxBatch {
                appendedSinceCount = 0
                if lineCount() + n > Self.compactAt { try compact() }
            }
            try append(lines)
            appendedSinceCount += n
        } != nil
    }

    static func line(_ r: PendingRun, sig: String) -> String {
        "{\"durationSeconds\":\(tenths(r.durationTenths)),\"exitResolutionSeconds\":\(tenths(r.resolutionTenths)),"
            + "\"exitedAt\":\"\(iso(r.exitedAt))\",\"pid\":\(r.pid),\"sig\":\"\(sig)\",\"startToken\":\"\(r.startToken)\"}\n"
    }

    static func tenths(_ t: Int) -> String { t % 10 == 0 ? String(t / 10) : "\(t / 10).\(t % 10)" }

    static func iso(_ seconds: Int) -> String {
        var t = time_t(seconds), tm = tm()
        gmtime_r(&t, &tm)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1, Int(tm.tm_mday),
                      Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec))
    }

    // MARK: Files

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid(),
              chmod(directory.path, 0o700) == 0 else { throw StoreError.io("durations directory is not usable") }
    }

    /// Runs `body` under the exclusive lock; nil when `gaveUp` turned true while the lock was held elsewhere.
    @discardableResult
    func withWriteLock<T>(gaveUp: () -> Bool = { false }, _ body: () throws -> T) throws -> T? {
        try ensureDirectory()
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("open duration lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw StoreError.io("flock: \(String(cString: strerror(errno)))") }
            if gaveUp() { return nil }
            usleep(5_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func readFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    private func lineCount() -> Int {
        guard let data = readFile(runsURL) else { return 0 }
        return data.withUnsafeBytes { p in p.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } }
    }

    private func append(_ lines: Data) throws {
        let fd = open(runsURL.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("open v1.jsonl: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        fchmod(fd, 0o600)
        var data = lines
        // A line cut short by a crash stays malformed on its own instead of swallowing the next Run.
        let end = lseek(fd, 0, SEEK_END)
        var last: UInt8 = 10
        if end > 0, pread(fd, &last, 1, end - 1) == 1, last != 10 { data.insert(10, at: 0) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw StoreError.io("short write to v1.jsonl") }
    }

    private func replace(_ url: URL, with data: Data) throws {
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.io("create \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw StoreError.io("replace \(url.lastPathComponent)")
        }
    }

    /// Rewrites `v1.jsonl` with the Runs inside every retention limit (malformed lines go).
    private func compact() throws {
        guard let data = readFile(runsURL) else { return }
        let kept = Self.retained(Self.parse(data), now: Int(Date().timeIntervalSince1970))
        var out = Data()
        out.reserveCapacity(data.count)
        for r in kept { out.append(data[r.range]); out.append(10) }
        try replace(runsURL, with: out)
    }

    // MARK: Signature Key

    struct Key { var key: SymmetricKey; var notBefore: Int? }
    private struct KeyFile: Codable { var v: Int; var key: String; var notBefore: String? }

    /// Test hook: opens `key.json` (tests inject a transient failure such as EMFILE).
    var openKeyFile: (String) -> Int32 = { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }

    /// The key, only from a regular file of this user with mode 0600 and a 32-byte key. Nil when `key.json` is missing
    /// or breaks one of those rules (DUR-041). Throws when a valid file could not be read for another reason, such as
    /// EMFILE or EIO, so that a transient failure never deletes the Runs.
    func readKey() throws -> Key? {
        func failure(_ what: String) -> StoreError { StoreError.io("\(what) key.json: \(String(cString: strerror(errno)))") }
        func accepted(_ st: stat) -> Bool {
            st.st_mode & S_IFMT == S_IFREG && st.st_uid == geteuid() && st.st_mode & 0o7777 == 0o600 && st.st_size < 4096
        }
        var st = stat()
        guard lstat(keyURL.path, &st) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw failure("stat")
        }
        guard accepted(st) else { return nil }
        let fd = openKeyFile(keyURL.path)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw failure("open")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &st) == 0 else { throw failure("fstat") }
        guard accepted(st) else { return nil }
        let data: Data
        do { data = try handle.readToEnd() ?? Data() } catch { throw StoreError.io("read key.json: \(error.localizedDescription)") }
        guard let file = try? JSONDecoder().decode(KeyFile.self, from: data), file.v == 1,
              let raw = Data(base64Encoded: file.key), raw.count == 32 else { return nil }
        var notBefore: Int?
        if let text = file.notBefore {
            guard let t = Array(text.utf8).withUnsafeBytes({ Self.parseISO($0, 0) }), text.utf8.count == 20 else { return nil }
            notBefore = t
        }
        return Key(key: SymmetricKey(data: raw), notBefore: notBefore)
    }

    @discardableResult
    private func writeKey(notBefore: Int?) throws -> Key {
        let key = SymmetricKey(size: .bits256)
        let file = KeyFile(v: 1, key: key.withUnsafeBytes { Data($0) }.base64EncodedString(), notBefore: notBefore.map(Self.iso))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try replace(keyURL, with: encoder.encode(file))
        return Key(key: key, notBefore: notBefore)
    }

    /// Under the exclusive lock: the valid key, or a new one after the Runs of a missing or rejected key are deleted.
    /// A read failure of another kind throws and leaves both files as they are.
    func currentKey() throws -> Key {
        if let key = try readKey() { return key }
        unlink(runsURL.path)
        return try writeKey(notBefore: nil)
    }

    /// `aistats baselines clear`: deletes every Run and replaces the key, so Runs that exited before now are dropped.
    public static func clear(home: URL) throws {
        let store = DurationStore(home: home)
        try store.withWriteLock {
            unlink(store.runsURL.path)
            try store.writeKey(notBefore: Int(Date().timeIntervalSince1970.rounded(.up)))
        }
    }

    // MARK: Lookup

    /// The Baseline of an executable path and Subcommand, or nil without a matching Run. Takes only the shared lock.
    func lookup(path: String, subcommand: String) -> Baseline? {
        let fd = open(lockURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        while flock(fd, LOCK_SH) != 0 { guard errno == EINTR else { return nil } }
        defer { flock(fd, LOCK_UN) }
        let ids = [fileID(runsURL), fileID(keyURL)]
        let now = Int(Date().timeIntervalSince1970)
        indexLock.lock(); defer { indexLock.unlock() }
        if let current = index, current.ids == ids, now < current.expiresAt {} else { index = rebuild(ids, now: now) }
        guard let key = index?.key else { return nil }
        let sig = CommandSignature.digest(key: key, path: path, subcommand: subcommand)
        guard let e = index?.entries[sig] else { return nil }
        return Baseline(label: CommandSignature.label(path: path, subcommand: subcommand), signature: sig,
                        tenths: e.tenths, lastRunAt: e.newest, resolutionTenths: e.resolution)
    }

    private func fileID(_ url: URL) -> FileID? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return FileID(dev: st.st_dev, ino: st.st_ino, size: st.st_size, sec: st.st_mtimespec.tv_sec, nsec: st.st_mtimespec.tv_nsec)
    }

    private func rebuild(_ ids: [FileID?], now: Int) -> Index {
        let read: Key?
        // A transient read failure is not cached: the next lookup tries again.
        do { read = try readKey() } catch { return Index(ids: ids, key: nil, entries: [:], expiresAt: now + 1) }
        guard let key = read else { return Index(ids: ids, key: nil, entries: [:], expiresAt: Int.max) }
        let runs = readFile(runsURL).map { Self.retained(Self.parse($0), now: now) } ?? []
        var entries: [String: Entry] = [:]
        var expires = Int.max
        for r in runs {
            entries[r.sig, default: Entry(tenths: [], newest: r.exitedAt, resolution: 0)].tenths.append(r.durationTenths)
            entries[r.sig]!.newest = max(entries[r.sig]!.newest, r.exitedAt)
            entries[r.sig]!.resolution = max(entries[r.sig]!.resolution, r.resolutionTenths)
            expires = min(expires, r.exitedAt + Self.maxAgeSeconds + 1)
        }
        return Index(ids: ids, key: key.key, entries: entries, expiresAt: expires)
    }

    /// Applies the age, deduplication, per-signature and signature-count rules; keeps file order.
    static func retained(_ runs: [StoredRun], now: Int) -> [StoredRun] {
        struct Instance: Hashable { var pid: Int32; var token: UInt64 }
        var best: [Instance: Int] = [:]
        for i in runs.indices where runs[i].exitedAt >= now - maxAgeSeconds {
            let k = Instance(pid: runs[i].pid, token: runs[i].startToken)
            if let j = best[k], runs[j].resolutionTenths <= runs[i].resolutionTenths { continue }
            best[k] = i
        }
        func newer(_ a: Int, _ b: Int) -> Bool { (runs[a].exitedAt, a) > (runs[b].exitedAt, b) }
        var bySig: [String: [Int]] = [:]
        for i in best.values { bySig[runs[i].sig, default: []].append(i) }
        let groups = bySig.values.map { Array($0.sorted(by: newer).prefix(maxRunsPerSignature)) }
        let kept = groups.sorted { newer($0[0], $1[0]) }.prefix(maxSignatures).flatMap { $0 }
        return kept.sorted().map { runs[$0] }
    }

    // MARK: Line format

    /// Decodes the lines of exactly the ADR 0011 format; any other line is skipped.
    static func parse(_ data: Data) -> [StoredRun] {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> [StoredRun] in
            guard let base = p.baseAddress else { return [] }
            var out: [StoredRun] = []
            out.reserveCapacity(p.count / 200)
            var start = 0
            while start < p.count, let nl = memchr(base + start, 10, p.count - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if let r = parseLine(p, start, end) { out.append(r) }
                start = end + 1
            }
            return out
        }
    }

    /// Unix seconds of `YYYY-MM-DDTHH:MM:SSZ` at `s`, or nil.
    static func parseISO(_ p: UnsafeRawBufferPointer, _ s: Int) -> Int? {
        guard p.count >= s + 20, p[s + 4] == 45, p[s + 7] == 45, p[s + 10] == 84, p[s + 13] == 58, p[s + 16] == 58,
              p[s + 19] == 90 else { return nil }
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in (s + a)..<(s + a + n) { let c = p[i]; guard c >= 48, c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2),
              y >= 1970, (1...12).contains(mo), h < 24, mi < 60, sec < 60 else { return nil }
        let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]
        guard (1...days).contains(d) else { return nil }
        let yy = mo <= 2 ? y - 1 : y, era = yy / 400, yoe = yy - era * 400
        let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1
        let epochDay = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
        return ((epochDay * 24 + h) * 60 + mi) * 60 + sec
    }

    private static func parseLine(_ p: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> StoredRun? {
        let quote: UInt8 = 34
        guard end - start >= 2, p[start] == 123, p[end - 1] == 125 else { return nil }
        var i = start + 1
        var sig: String?, pid: Int32?, token: UInt64?, duration: Int?, exited: Int?, resolution: Int?
        var fields = 0
        func digits(_ a: Int, _ b: Int) -> Bool { a < b && (a..<b).allSatisfy { p[$0] >= 48 && p[$0] <= 57 } }
        func integer(_ a: Int, _ b: Int) -> UInt64? {
            guard digits(a, b), b - a <= 20, p[a] != 48 || b - a == 1 else { return nil }
            var v: UInt64 = 0
            for k in a..<b {
                let (m, o1) = v.multipliedReportingOverflow(by: 10)
                let (n, o2) = m.addingReportingOverflow(UInt64(p[k] - 48))
                guard !o1, !o2 else { return nil }
                v = n
            }
            return v
        }
        func tenths(_ a: Int, _ b: Int) -> Int? {
            var dot = b
            if b - a >= 3, p[b - 2] == 46 { dot = b - 2; guard p[b - 1] >= 48, p[b - 1] <= 57 else { return nil } }
            guard digits(a, dot), dot - a <= 9, p[a] != 48 || dot - a == 1 else { return nil }
            var v = 0
            for k in a..<dot { v = v * 10 + Int(p[k] - 48) }
            return v * 10 + (dot < b ? Int(p[b - 1] - 48) : 0)
        }
        while i < end - 1 {
            if fields > 0 { guard p[i] == 44 else { return nil }; i += 1 }
            guard i < end, p[i] == quote else { return nil }
            let ks = i + 1
            i = ks
            while i < end, p[i] != quote { i += 1 }
            let ke = i
            i += 1
            guard i < end, p[i] == 58 else { return nil }
            i += 1
            let vs: Int, ve: Int, isString: Bool
            if i < end, p[i] == quote {
                isString = true
                vs = i + 1; i = vs
                while i < end, p[i] != quote { guard p[i] >= 0x20, p[i] != 92 else { return nil }; i += 1 }
                guard i < end else { return nil }
                ve = i; i += 1
            } else {
                isString = false
                vs = i
                while i < end - 1, p[i] != 44 { i += 1 }
                ve = i
            }
            func key(_ name: StaticString) -> Bool {
                ke - ks == name.utf8CodeUnitCount && (0..<(ke - ks)).allSatisfy { p[ks + $0] == name.utf8Start[$0] }
            }
            if key("sig") {
                guard sig == nil, isString, ve - vs == 64,
                      (vs..<ve).allSatisfy({ (48...57).contains(p[$0]) || (97...102).contains(p[$0]) }) else { return nil }
                sig = String(decoding: UnsafeRawBufferPointer(rebasing: p[vs..<ve]), as: UTF8.self)
            } else if key("pid") {
                guard pid == nil, !isString, let v = integer(vs, ve), v > 0, v <= UInt64(Int32.max) else { return nil }
                pid = Int32(v)
            } else if key("startToken") {
                guard token == nil, isString, let v = integer(vs, ve) else { return nil }
                token = v
            } else if key("durationSeconds") {
                guard duration == nil, !isString, let v = tenths(vs, ve) else { return nil }
                duration = v
            } else if key("exitResolutionSeconds") {
                guard resolution == nil, !isString, let v = tenths(vs, ve) else { return nil }
                resolution = v
            } else if key("exitedAt") {
                guard exited == nil, isString, ve - vs == 20, let v = parseISO(p, vs) else { return nil }
                exited = v
            } else { return nil }
            fields += 1
        }
        guard fields == 6, let sig, let pid, let token, let duration, let exited, let resolution else { return nil }
        return StoredRun(sig: sig, pid: pid, startToken: token, durationTenths: duration, exitedAt: exited,
                         resolutionTenths: resolution, range: start..<end)
    }
}
