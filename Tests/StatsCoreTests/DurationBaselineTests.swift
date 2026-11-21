import CryptoKit
import Darwin
import Foundation
import Testing
@testable import StatsCore

// MARK: - Helpers

private func sc(_ r: [String: Any]?) -> [String: Any]? {
    (r?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
}

private func mode(_ path: String) -> Int {
    var st = stat()
    return lstat(path, &st) == 0 ? Int(st.st_mode & 0o7777) : -1
}

private func stamp(_ path: String) -> String {
    var st = stat()
    guard lstat(path, &st) == 0 else { return "-" }
    return "\(st.st_ino).\(st.st_size).\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
}

private func stamps(_ s: DurationStore) -> [String] { [s.runsURL, s.keyURL, s.lockURL].map { stamp($0.path) } }

private func storedRuns(_ s: DurationStore) -> [StoredRun] { (try? Data(contentsOf: s.runsURL)).map(DurationStore.parse) ?? [] }

private func lineCount(_ s: DurationStore) -> Int {
    ((try? Data(contentsOf: s.runsURL)) ?? Data()).reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
}

private var nowSeconds: Int { Int(Date().timeIntervalSince1970) }

private func pending(_ path: String, _ sub: String = "", pid: Int32, token: UInt64, tenths: Int = 10, exitedAt: Int? = nil,
                     res: Int = 3) -> PendingRun {
    PendingRun(path: path, subcommand: sub, pid: pid, startToken: String(token), durationTenths: tenths,
               exitedAt: exitedAt ?? nowSeconds, resolutionTenths: res)
}

/// Writes `runs` as the whole `v1.jsonl`, signed with the store's key (created if needed).
@discardableResult
private func fixture(_ store: DurationStore, _ runs: [PendingRun], extra: String = "") throws -> [String] {
    let key = try #require(try store.withWriteLock { try store.currentKey() })
    let lines = runs.map { DurationStore.line($0, sig: CommandSignature.digest(key: key.key, path: $0.path, subcommand: $0.subcommand)) }
    try Data((lines.joined() + extra).utf8).write(to: store.runsURL)
    chmod(store.runsURL.path, 0o600)
    return lines
}

private func signedCopy(_ source: String, to url: URL) throws -> String {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: url)
    let r = try Subprocess.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path], timeout: 30)
    #expect(r.succeeded, "codesign: \(r.stderr)")
    return ProcessSelector.realPath(url.path) ?? url.path
}

private func spawn(_ path: String, _ args: [String], in dir: URL? = nil) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let dir { p.currentDirectoryURL = dir }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private func end(_ p: Process) { if p.isRunning { p.terminate() }; p.waitUntilExit() }

private func keyPaths(_ value: Any, _ prefix: String = "") -> Set<String> {
    if let d = value as? [String: Any] {
        return d.reduce(into: Set<String>()) { s, kv in s.insert(prefix + "/" + kv.key); s.formUnion(keyPaths(kv.value, prefix + "/" + kv.key)) }
    }
    if let a = value as? [Any] { return a.reduce(into: Set<String>()) { $0.formUnion(keyPaths($1, prefix + "[]")) } }
    return []
}

private func hasBaselineKey(_ value: Any) -> Bool {
    keyPaths(value).contains { $0.hasSuffix("/baseline") || $0.hasSuffix("/baselines") || $0.hasSuffix("/baselineIndex") }
}

private let liveCommand: ObservedCommand = {
    var c = ObservedCommand()
    c.observe(Proc.Key(pid: getpid(), start: Proc.usage(getpid())!.start),
              reader: CommandReader(path: { _ in "/fixtures/xcodebuild" }, arguments: { _ in ["-scheme", "App", "test"] }))
    return c
}()

// MARK: - Baseline content and Command Signature

@Suite struct BaselineContentTests {
    /// DUR-016, DUR-017, DUR-019, DUR-020, DUR-021.
    @Test func statisticsFieldsAndSize() throws {
        func keys(_ b: Baseline) throws -> Set<String> {
            Set((try JSONSerialization.jsonObject(with: MCPServer.encoder.encode(b)) as? [String: Any] ?? [:]).keys)
        }
        let all: Set<String> = ["label", "runs", "medianSeconds", "p90Seconds", "maxSeconds", "lastRunAt", "suggestedTimeoutSeconds", "resolutionSeconds"]
        let five = Baseline(label: "job", signature: "a", tenths: [50, 10, 40, 20, 30], lastRunAt: 1_800_000_000, resolutionTenths: 7)
        #expect(try keys(five) == all)
        #expect(five.medianSeconds == 3 && five.p90Seconds == 5 && five.maxSeconds == 5 && five.p90Seconds == five.maxSeconds)
        #expect(five.suggestedTimeoutSeconds == 10 && five.resolutionSeconds == 0.7 && five.runs == 5)
        #expect(five.lastRunAt == Date(timeIntervalSince1970: 1_800_000_000))
        let ten = Baseline(label: "job", signature: "a", tenths: Array(stride(from: 10, through: 100, by: 10)), lastRunAt: 0, resolutionTenths: 1)
        #expect(ten.medianSeconds == 5.5 && ten.p90Seconds == 9 && ten.maxSeconds == 10 && ten.suggestedTimeoutSeconds == 12)
        let four = Baseline(label: "job", signature: "a", tenths: [1, 2, 3, 4], lastRunAt: 0, resolutionTenths: 1)
        #expect(try keys(four) == ["label", "runs"] && four.runs == 4)
        for (p90, expected) in [(20, 10), (6000, 750), (100_000, 7200)] {
            let b = Baseline(label: "job", signature: "a", tenths: Array(repeating: p90, count: 5), lastRunAt: 0, resolutionTenths: 1)
            #expect(b.suggestedTimeoutSeconds == expected)
            #expect(try !keys(b).contains("waitForTimeoutSeconds"))
        }
        let label = CommandSignature.label(path: "/x/" + String(repeating: "j", count: 200), subcommand: "")
        #expect(label.utf8.count == 64)
        let worst = Baseline(label: label, signature: "a", tenths: Array(repeating: 25_920_000, count: 64), lastRunAt: 1_800_000_000,
                             resolutionTenths: 99_999)
        #expect(try MCPServer.encoder.encode(worst).count <= 256)
    }

    /// DUR-037, DUR-018, DUR-039 (label cut).
    @Test func subcommandRulesAndLabels() {
        func label(_ argv: [String]) -> String? {
            let base = argv[0]
            return CommandSignature.subcommand(basename: base, arguments: Array(argv.dropFirst())).map {
                CommandSignature.label(path: "/usr/bin/" + base, subcommand: $0)
            }
        }
        #expect(label(["xcodebuild", "-scheme", "App", "-destination", "X", "test"]) == "xcodebuild test")
        #expect(label(["xcodebuild", "-quiet", "clean", "build"]) == "xcodebuild clean build")
        #expect(label(["xcodebuild", "build", "test", "analyze"]) == "xcodebuild build test")
        #expect(label(["xcodebuild", "-destination=platform=macOS", "test"]) == "xcodebuild test")
        #expect(label(["xcodebuild", "-showBuildSettings"]) == "xcodebuild")
        #expect(label(["go", "test", "./...", "-run", "build"]) == "go test")
        #expect(label(["cargo", "run", "--", "test"]) == "cargo run")
        #expect(label(["cargo", "+nightly", "build"]) == "cargo build")
        #expect(label(["swift", "package", "resolve"]) == "swift")
        #expect(label(["xcodebuild", "-scheme", "test", "build"]) == nil)
        #expect(label(["xcodebuild", "-derivedDataPath", "build", "test"]) == nil)
        #expect(label(["swift", "-v", "build"]) == nil)
        #expect(CommandSignature.subcommand(basename: "node", arguments: ["-e", "test"]) == "")
        let uncut = String(repeating: "é", count: 40)
        let cut = CommandSignature.label(path: "/tmp/" + uncut, subcommand: "")
        #expect(cut.utf8.count <= 64 && uncut.hasPrefix(cut) && cut.count == 32)
        #expect(CommandSignature.label(path: "/a/\"q\\", subcommand: "").utf8.count == 3)
    }

    /// DUR-033: 15 rows with 5 distinct Baselines give 3 and count 2; dropped rows take their Baselines along.
    @Test func baselineIndexing() {
        var r = FindResult(observedAt: Date(), scope: "current_user", selector: "name", processes: [], matched: 15, truncated: false)
        r.processes = (0..<15).map { i in
            var row = FindResult.Row(pid: Int32(i + 1), startToken: "1", name: "n", ppid: 1, footprintBytes: 1, path: nil, unreadable: nil)
            row.baseline = Baseline(label: "job\(i % 5)", signature: "s\(i % 5)", tenths: [1], lastRunAt: 0, resolutionTenths: 1)
            return row
        }
        r.baselines = []
        r.indexBaselines()
        #expect(r.baselines?.map(\.label) == ["job0", "job1", "job2"] && r.baselinesOmitted == 2)
        #expect(r.processes.map(\.baselineIndex) == (0..<15).map { $0 % 5 < 3 ? $0 % 5 : nil })
        r.processes = Array(r.processes.prefix(4))
        r.indexBaselines()
        #expect(r.baselines?.count == 3 && r.baselinesOmitted == 1)
        r.processes = Array(r.processes.prefix(2))
        r.indexBaselines()
        #expect(r.baselines?.map(\.label) == ["job0", "job1"] && r.baselinesOmitted == nil)
    }

    /// DUR-038: the allowlist, the flag list and the prefix are pinned together.
    @Test func allowlistDigestIsPinned() {
        func digest(_ s: String) -> String { CommandSignature.hex(SHA256.hash(data: Data(s.utf8))) }
        #expect(digest(CommandSignature.canonical()) == "e205f50c53a425ceb78456f47092413ab9d19a43e6254852d53a603caa724334",
                "the Subcommand Allowlist, No-value Flag list or rules changed: change the v1 prefix")
        var extended = CommandSignature.allowlist
        extended[1].entries.append("package")
        #expect(digest(CommandSignature.canonical(allowlist: extended)) != digest(CommandSignature.canonical()))
        #expect(digest(CommandSignature.canonical(flags: CommandSignature.noValueFlags + ["-new"])) != digest(CommandSignature.canonical()))
    }

    /// DUR-040 and DUR-036 (no path or unknown Subcommand), with injected clocks and times.
    @Test func discardRules() throws {
        let key = Proc.Key(pid: 4242, start: 1)
        let exit: UInt64 = 3_000_000_000_000_000
        func make(_ command: ObservedCommand = liveCommand, start: UInt64 = exit - 30_000_000_000, lastAlive: UInt64 = exit - 500_000_000,
                  offset: Int64 = 0, interval: Double = 1) -> PendingRun? {
            PendingRun.make(command: command, key: key, startNs: start, exitNs: exit, lastAliveNs: lastAlive, firstOffset: 5_000_000_000,
                            exitOffset: 5_000_000_000 + offset, intervalSeconds: interval, exitedAt: Date(timeIntervalSince1970: 1_800_000_000.7))
        }
        let run = try #require(make())
        #expect(run.durationTenths == 300 && run.resolutionTenths == 5 && run.exitedAt == 1_800_000_000 && run.subcommand == "test")
        #expect(make(offset: 2_000_000_000) == nil)
        #expect(make(offset: 900_000_000) != nil)
        #expect(make(start: exit - 2_592_001_000_000_000) == nil)
        #expect(make(start: exit - 2_592_000_000_000_000) != nil)
        #expect(make(lastAlive: exit - 4_000_000_000) == nil)
        #expect(make(lastAlive: exit - 3_000_000_000) != nil)
        #expect(make(lastAlive: exit - 1_600_000_000, interval: 0.25) == nil)
        #expect(make(ObservedCommand()) == nil)
        var unreadable = ObservedCommand()
        unreadable.observe(Proc.Key(pid: getpid(), start: Proc.usage(getpid())!.start),
                           reader: CommandReader(path: { _ in "/usr/bin/xcodebuild" }, arguments: { _ in nil }))
        #expect(unreadable.path != nil && make(unreadable) == nil)
    }
}

// MARK: - Store

@Suite(.serialized) struct DurationStoreTests {
    /// DUR-043, DUR-010, DUR-031, DUR-009.
    @Test func lineFormatAndModes() throws {
        let home = TestTemp.dir()
        let store = DurationStore(home: home)
        for i in 0..<3 { store.record(pending(home.path + "/tool", "test", pid: 500 + Int32(i), token: 12_345 + UInt64(i), tenths: 15 + i)) }
        store.drain()
        let text = try String(contentsOf: store.runsURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3 && text.hasSuffix("\n"))
        for line in lines {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["sig", "pid", "startToken", "durationSeconds", "exitedAt", "exitResolutionSeconds"])
            #expect((object["sig"] as? String)?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
            #expect((object["exitedAt"] as? String)?.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil)
            #expect((object["startToken"] as? String).flatMap(UInt64.init) != nil && !line.contains(" "))
        }
        #expect(!text.contains("test") && !text.contains("tool") && !text.contains(home.path))
        #expect(!text.contains(NSHomeDirectory()) && !text.contains(NSUserName()))
        #expect(mode(store.directory.path) == 0o700)
        for url in [store.runsURL, store.lockURL, store.keyURL] { #expect(mode(url.path) == 0o600, "\(url.lastPathComponent)") }
        let worst = DurationStore.line(PendingRun(path: "/x", subcommand: "", pid: 99_999, startToken: "18446744073709551615",
                                                  durationTenths: 25_919_999, exitedAt: 1_800_000_000, resolutionTenths: 1209),
                                       sig: String(repeating: "f", count: 64))
        #expect(worst.utf8.count <= 216 && DurationStore.parse(Data(worst.utf8)).count == 1)
        for t in [0, 951_782_400, 1_709_251_199, 1_800_000_000, nowSeconds] {
            #expect(Array(DurationStore.iso(t).utf8).withUnsafeBytes { DurationStore.parseISO($0, 0) } == t)
        }
        for bad in ["2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-01-01 00:00:00Z", "2026-01-01T24:00:00Z"] {
            #expect(Array(bad.utf8).withUnsafeBytes { DurationStore.parseISO($0, 0) } == nil)
        }
        // A compaction keeps the modes.
        let other = DurationStore(home: home)
        other.record(pending("/x/y", pid: 9, token: 9))
        other.drain()
        #expect(lineCount(store) == 4)
        for url in [store.runsURL, store.lockURL, store.keyURL] { #expect(mode(url.path) == 0o600) }
    }

    /// DUR-014, DUR-044.
    @Test func readableRunsOnlyAndDeduplication() throws {
        let home = TestTemp.dir()
        let store = DurationStore(home: home)
        #expect(store.lookup(path: "/a", subcommand: "") == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "a lookup writes nothing")
        let lines = try fixture(store, [pending("/a", pid: 7, token: 70, tenths: 100, res: 20), pending("/a", pid: 7, token: 70, tenths: 200, res: 3),
                                        pending("/a", pid: 7, token: 70, tenths: 300, res: 3)])
        #expect(store.lookup(path: "/a", subcommand: "")?.runs == 1)
        let kept = DurationStore.retained(storedRuns(store), now: nowSeconds)
        #expect(kept.count == 1 && kept[0].durationTenths == 200)
        try fixture(store, (0..<5).map { pending("/a", pid: 10 + Int32($0), token: 1, tenths: 10) }, extra: "{\"sig\":broken\nnot json\n")
        #expect(store.lookup(path: "/a", subcommand: "")?.runs == 5)
        try FileManager.default.removeItem(at: store.runsURL)
        #expect(store.lookup(path: "/a", subcommand: "") == nil)
        try fixture(store, [])
        try Data(lines.joined().utf8).write(to: store.runsURL)
        let writer = DurationStore(home: home)
        writer.record(pending("/b", pid: 8, token: 80))
        writer.drain()
        let after = try String(contentsOf: store.runsURL, encoding: .utf8)
        #expect(after.contains(lines[1]) && !after.contains(lines[0]) && !after.contains(lines[2]) && lineCount(store) == 2)
    }

    /// DUR-013: per-signature, signature-count and age limits, at read time and after compaction.
    @Test func retentionLimits() throws {
        let home = TestTemp.dir()
        let store = DurationStore(home: home)
        let now = nowSeconds
        var runs = (0..<65).map { i in pending("/a", pid: 1000 + Int32(i), token: 1, tenths: i == 0 ? 99_999 : 10, exitedAt: now - 100 + i) }
        runs.append(pending("/b0", pid: 2000, token: 1, exitedAt: now - 2000))
        runs += (1...127).map { j in pending("/b\(j)", pid: 2000 + Int32(j), token: 1, exitedAt: now - 500 + j) }
        runs.append(pending("/c", pid: 3000, token: 1, exitedAt: now - DurationStore.maxAgeSeconds - 100))
        try fixture(store, runs)
        let a = try #require(store.lookup(path: "/a", subcommand: ""))
        #expect(a.runs == 64 && a.maxSeconds == 1)
        #expect(store.lookup(path: "/b0", subcommand: "") == nil && store.lookup(path: "/b1", subcommand: "") != nil)
        #expect(store.lookup(path: "/c", subcommand: "") == nil)
        let writer = DurationStore(home: home)
        writer.record(pending("/d", pid: 4000, token: 1))
        writer.drain()
        let pids = Set(storedRuns(store).map(\.pid))
        // The compaction runs before the append: it sees 129 signatures and drops only the one with the oldest newest Run.
        #expect(!pids.contains(1000) && !pids.contains(2000) && !pids.contains(3000) && pids.contains(2001) && pids.contains(4000))
        #expect(pids.count == 64 + 127 + 1)
        #expect(store.lookup(path: "/b1", subcommand: "") == nil && store.lookup(path: "/d", subcommand: "") != nil)
    }

    /// DUR-041: rejected key files give no Baseline and stay untouched until the writer replaces them.
    @Test func keyFileRules() throws {
        let home = TestTemp.dir()
        let store = DurationStore(home: home)
        try fixture(store, (0..<5).map { pending("/a", pid: 10 + Int32($0), token: 1) })
        #expect(store.lookup(path: "/a", subcommand: "")?.runs == 5)
        let good = try Data(contentsOf: store.keyURL)
        let fm = FileManager.default
        let replacements: [() throws -> Void] = [
            { chmod(store.keyURL.path, 0o644) },
            { let target = home.appendingPathComponent("elsewhere.json"); try good.write(to: target); chmod(target.path, 0o600)
              try fm.removeItem(at: store.keyURL); try fm.createSymbolicLink(at: store.keyURL, withDestinationURL: target) },
            { try fm.removeItem(at: store.keyURL)
              try Data("{\"key\":\"\(Data(count: 16).base64EncodedString())\",\"v\":1}".utf8).write(to: store.keyURL); chmod(store.keyURL.path, 0o600) },
        ]
        for replace in replacements {
            try? fm.removeItem(at: store.keyURL)
            try good.write(to: store.keyURL); chmod(store.keyURL.path, 0o600)
            try replace()
            let before = stamps(store)
            #expect(store.lookup(path: "/a", subcommand: "") == nil)
            #expect(stamps(store) == before)
        }
        let writer = DurationStore(home: home)
        writer.record(pending("/new", pid: 99, token: 1))
        writer.drain()
        #expect(try store.readKey() != nil && mode(store.keyURL.path) == 0o600)
        #expect(storedRuns(store).map(\.pid) == [99])
        #expect(store.lookup(path: "/new", subcommand: "")?.runs == 1)
    }

    /// DUR-012, DUR-041: a valid key that fails to open for a transient reason is not a rejected key. The writer keeps
    /// `v1.jsonl` and the key, and writes the queued Run once the key reads again.
    @Test func transientKeyReadFailureKeepsTheRuns() throws {
        let home = TestTemp.dir()
        let store = DurationStore(home: home)
        try fixture(store, (0..<5).map { pending("/a", pid: 10 + Int32($0), token: 1) })
        let before = stamps(store)
        let writer = DurationStore(home: home)
        writer.openKeyFile = { _ in errno = EMFILE; return -1 }
        writer.record(pending("/a", pid: 99, token: 1))
        writer.drain()
        #expect(stamps(store) == before, "no file changed")
        #expect(storedRuns(store).count == 5 && writer.queuedCount == 1)
        #expect(writer.lookup(path: "/a", subcommand: "") == nil, "no key read")
        writer.openKeyFile = { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        writer.drain()
        #expect(storedRuns(store).count == 6 && writer.queuedCount == 0)
        #expect(writer.lookup(path: "/a", subcommand: "")?.runs == 6, "the failed read was not cached")
    }

    /// DUR-027, DUR-042: the clear drops queued Runs that exited before it, and later Runs match again.
    @Test func clearRotatesTheKeyAndDropsEarlierRuns() throws {
        let home = TestTemp.dir()
        let store = DurationStore(home: home)
        store.record(pending("/a", pid: 1, token: 1))
        store.drain()
        let oldKey = try Data(contentsOf: store.keyURL)
        store.holdsWrites = true
        store.record(pending("/a", pid: 2, token: 2))
        try DurationStore.clear(home: home)
        #expect(!FileManager.default.fileExists(atPath: store.runsURL.path))
        let key = try #require(try store.readKey())
        #expect(try Data(contentsOf: store.keyURL) != oldKey && key.notBefore != nil)
        store.holdsWrites = false
        store.drain()
        #expect(storedRuns(store).allSatisfy { $0.exitedAt >= key.notBefore! })
        #expect(storedRuns(store).isEmpty)
        store.record(pending("/a", pid: 3, token: 3, exitedAt: key.notBefore! + 1))
        store.drain()
        #expect(store.lookup(path: "/a", subcommand: "")?.runs == 1)
    }

    /// DUR-012, DUR-046: concurrent writers lose nothing and keep the file bound.
    @Test func concurrentWritersKeepEveryRunAndTheBound() throws {
        let home = TestTemp.dir()
        DispatchQueue.concurrentPerform(iterations: 8) { w in
            let writer = DurationStore(home: home)
            for i in 0..<100 { writer.record(pending("/job\(i)", pid: Int32(w * 1000 + i + 1), token: UInt64(w + 1))) }
            writer.drain(timeout: 30)
        }
        let store = DurationStore(home: home)
        #expect(storedRuns(store).count == 800 && lineCount(store) == 800)
        let now = nowSeconds
        try fixture(store, (0..<16_384).map { i in pending("/fill\(i % 128)", pid: Int32(i + 1), token: 7, exitedAt: now - i % 1000) })
        let counts = NSLock()
        var largest = 0
        DispatchQueue.concurrentPerform(iterations: 8) { w in
            let writer = DurationStore(home: home)
            for b in 0..<4 {
                for i in 0..<50 { writer.record(pending("/w\(w)", pid: Int32(100_000 + w * 1000 + b * 50 + i), token: 9)) }
                writer.drain(timeout: 30)
                let n = (try? store.withSharedLockForTests { lineCount(store) }) ?? 0
                counts.lock(); largest = max(largest, n); counts.unlock()
            }
        }
        #expect(largest <= 16_776 && largest > 0)
    }

    /// DUR-035: an index rebuild at the file bound (median reported; the 50 ms budget applies to release builds).
    @Test func rebuildAtTheFileBound() throws {
        let home = TestTemp.dir()
        let store = DurationStore(home: home)
        let now = nowSeconds
        try fixture(store, (0..<16_776).map { i in
            PendingRun(path: "/job\(i % 128)", subcommand: "", pid: 10_000 + Int32(i % 89_000), startToken: String(10_000_000_000_000_000_000 + UInt64(i)),
                       durationTenths: 25_919_999, exitedAt: now - i % 5000, resolutionTenths: 1209)
        })
        var times: [Double] = []
        for i in 0..<100 {
            var t = [timespec(tv_sec: now - i, tv_nsec: 0), timespec(tv_sec: now - i, tv_nsec: 0)]
            utimensat(AT_FDCWD, store.runsURL.path, &t, 0)
            let start = Proc.nowNs()
            #expect(store.lookup(path: "/job\(i % 128)", subcommand: "")?.runs == 64)
            times.append(Double(Proc.nowNs() - start) / 1e6)
        }
        times.sort()
        let median = times[50], p90 = times[89]
        print("DUR-035 rebuild median \(median) ms, p90 \(p90) ms")
        #if DEBUG
        #expect(median <= 1000)
        #else
        #expect(median <= 50)
        #endif
    }
}

extension DurationStore {
    func withSharedLockForTests<T>(_ body: () -> T) throws -> T {
        let fd = open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.io("no lock") }
        defer { close(fd) }
        flock(fd, LOCK_SH)
        defer { flock(fd, LOCK_UN) }
        return body()
    }
}

// MARK: - Recording from tracks and waits

@Suite(.serialized) struct DurationRecordingTests {
    /// DUR-001, DUR-002, DUR-003 (1 s interval), DUR-018, DUR-022 to DUR-026, DUR-030, DUR-034.
    @Test func trackRunsAndAgentAccess() throws {
        let home = TestTemp.dir()
        let sleeper = try signedCopy("/bin/sleep", to: home.appendingPathComponent("aistats-dur-\(UUID().uuidString.prefix(6).lowercased())"))
        let name = (sleeper as NSString).lastPathComponent
        let store = DurationStore.forHome(home)
        let manager = TrackManager(home: home)
        manager.discoveryInterval = 200_000_000
        let started = try manager.start(TrackOptions(selector: .name(name, glob: false), durationSeconds: 120, intervalSeconds: 1))
        let job = try Child.sh("for i in 1 2 3 4 5; do '\(sleeper)' 2; done")
        defer { job.kill() }
        #expect(eventually(40) { store.drain(); return storedRuns(store).count == 5 })
        let report = try #require(manager.status(started.trackId))
        #expect(report.instances.count == 3 && report.instancesOmitted == 2)
        let runs = storedRuns(store)
        #expect(runs.count == 5 && Set(runs.map(\.pid)).count == 5)
        for r in runs {
            #expect(abs(Double(r.durationTenths) / 10 - 2) <= 1.1, "duration \(r.durationTenths)")
            #expect(r.resolutionTenths <= 11, "resolution \(r.resolutionTenths)")
            #expect(abs(r.exitedAt - nowSeconds) < 60)
        }
        let baseline = try #require(report.baseline)
        #expect(baseline.label == name && baseline.runs == 5 && baseline.medianSeconds != nil)
        _ = try manager.stop(started.trackId)
        var fitted = report
        fitted.events = Array(repeating: .init(t: Date(), kind: "exec", pid: 1, name: String(repeating: "e", count: 300)), count: 8)
        fitted.notes = Array(repeating: String(repeating: "n", count: 400), count: 10)
        #expect(fitted.fitting(maxBytes: 600).baseline == baseline, "DUR-024")

        let long = try spawn(sleeper, ["60"])
        defer { end(long) }
        let before = stamps(store)
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "track_processes", ["action": "start", "name": name, "durationSeconds": 60, "intervalSeconds": 1])
        let start = try #require(sc(h.response(1)))
        #expect((start["baseline"] as? [String: Any])?["runs"] as? Int == 5, "\(start)")
        let id = try #require(start["trackId"] as? String)
        h.call(2, "track_processes", ["action": "status", "trackId": id])
        let full = try #require(sc(h.response(2)))
        #expect((full["baseline"] as? [String: Any])?["label"] as? String == name)
        h.call(3, "track_processes", ["action": "status", "trackId": id, "since": try #require(full["cursor"] as? String)])
        let delta = try #require(sc(h.response(3)))
        #expect(delta["delta"] as? Bool == true && delta["baseline"] != nil)
        #expect(!(delta["unchanged"] as? [String] ?? []).contains("baseline"))
        h.call(4, "find_processes", ["pid": Int(long.processIdentifier), "includeBaseline": true])
        let found = try #require(sc(h.response(4)))
        #expect((found["baselines"] as? [[String: Any]])?.count == 1)
        #expect((found["processes"] as? [[String: Any]])?.first?["baselineIndex"] as? Int == 0)
        let cli = try JSONSerialization.jsonObject(with: MCPServer.encoder.encode(
            Args.find(["pid": Int(long.processIdentifier), "includeBaseline": true], durations: store)))
        #expect(keyPaths(cli) == keyPaths(found), "DUR-034")
        h.call(5, "find_processes", ["pid": Int(long.processIdentifier)])
        h.call(6, "get_top_processes", ["limit": 3])
        h.call(7, "wait_for", ["condition": "memory_pressure_normal", "timeoutSeconds": 1.5])
        h.call(8, "track_processes", ["action": "list"])
        h.call(9, "get_environment", ["includeToolchain": false])
        h.call(10, "get_system_stats")
        h.call(11, "get_stats_history", ["minutes": 5])
        h.call(12, "diagnose_system")
        h.call(13, "get_process_tree", ["limit": 3])
        h.call(14, "get_simulator_usage")
        h.call(15, "get_developer_storage")
        h.call(16, "get_agent_sessions")
        h.call(17, "wait_for", ["condition": "process_started", "name": name, "timeoutSeconds": 5])
        for i in 5...17 { #expect(!hasBaselineKey(try #require(sc(h.response(i)))), "DUR-026 call \(i)") }
        #expect((sc(h.response(17))?["processes"] as? [Any])?.isEmpty == false, "process_started returned rows")
        #expect(stamps(store) == before, "DUR-030: lookups write nothing")
        let short = try spawn(sleeper, ["1"])
        defer { end(short) }
        h.call(18, "wait_for", ["condition": "process_exit", "pid": Int(short.processIdentifier), "timeoutSeconds": 10])
        let exited = try #require(sc(h.response(18)))
        #expect(exited["state"] as? String == "met" && !hasBaselineKey(exited), "DUR-026 process_exit: \(exited)")
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
    }

    /// DUR-004, DUR-007, DUR-008, DUR-009, DUR-018, DUR-036, DUR-039 (after exit).
    @Test func xcodebuildFixturePrivacyAndCensoring() throws {
        let home = TestTemp.dir()
        let dir = home.appendingPathComponent("bin", isDirectory: true)
        let tool = try signedCopy("/usr/bin/tail", to: dir.appendingPathComponent("xcodebuild"))
        let marker = "M" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(31)
        try Data().write(to: dir.appendingPathComponent("test"))
        try Data().write(to: dir.appendingPathComponent(String(marker)))
        let store = DurationStore.forHome(home)
        let manager = TrackManager(home: home)
        manager.discoveryInterval = 200_000_000
        let a = try spawn(tool, ["-f", "/dev/null", "test", String(marker)], in: dir)
        let b = try spawn(tool, ["-f", "/dev/null", "test", String(marker)], in: dir)
        defer { end(a); end(b) }
        #expect(eventually { Proc.path(a.processIdentifier) != nil && Proc.path(b.processIdentifier) != nil })
        let track = try manager.start(TrackOptions(selector: .path(tool, glob: false, args: String(marker)), durationSeconds: 60, intervalSeconds: 1))
        #expect(eventually { manager.status(track.trackId)?.aggregate.liveMembers == 2 })
        end(a)
        #expect(eventually(15) { store.drain(); return storedRuns(store).count == 1 })
        _ = try manager.stop(track.trackId)
        store.drain()
        #expect(storedRuns(store).count == 1, "the live instance is censored")
        #expect(manager.status(track.trackId)?.baseline?.label == "xcodebuild test")
        #expect(store.lookup(path: tool, subcommand: "test")?.runs == 1)
        let text = try String(contentsOf: store.runsURL, encoding: .utf8)
        #expect(!text.contains("test") && !text.contains("xcodebuild") && !text.contains(dir.path) && !text.contains(NSHomeDirectory()))
        let everything = FileManager.default.enumerator(atPath: home.path)!.compactMap { $0 as? String }
            .filter { !$0.hasPrefix("bin") }
            .compactMap { try? Data(contentsOf: home.appendingPathComponent($0)) }
        #expect(!everything.contains { $0.range(of: Data(marker.utf8)) != nil }, "DUR-007: argsContain never stored")

        let blind = TrackManager(home: home)
        blind.commandReader = CommandReader(path: { Proc.path($0) }, arguments: { _ in nil })
        let c = try spawn(tool, ["-f", "/dev/null"])
        defer { end(c) }
        #expect(eventually { Proc.path(c.processIdentifier) != nil })
        let t2 = try blind.start(TrackOptions(selector: .pid(c.processIdentifier, startToken: nil), durationSeconds: 60, intervalSeconds: 1))
        end(c)
        #expect(eventually(15) { blind.status(t2.trackId)?.state != "running" })
        store.drain()
        #expect(storedRuns(store).count == 1, "DUR-036: unreadable arguments of an allowlisted tool")
        blind.commandReader = CommandReader(path: { _ in nil }, arguments: { Proc.arguments($0) })
        let d = try spawn("/bin/sleep", ["1"])
        defer { end(d) }
        let t3 = try blind.start(TrackOptions(selector: .pid(d.processIdentifier, startToken: nil), durationSeconds: 60, intervalSeconds: 1))
        #expect(eventually(15) { blind.status(t3.trackId)?.state != "running" })
        store.drain()
        #expect(storedRuns(store).count == 1, "DUR-036: no path read")
    }

    /// DUR-004: a track that ends by `duration_elapsed`, or that becomes `interrupted`, records no Run for a live Root
    /// Instance. The instance that exited before the end keeps its one Run.
    @Test func censoredAtDurationElapsedAndInterrupted() throws {
        let home = TestTemp.dir()
        let store = DurationStore.forHome(home)
        let sleeper = try signedCopy("/bin/sleep", to: home.appendingPathComponent("aistats-cen-\(UUID().uuidString.prefix(6).lowercased())"))
        let name = (sleeper as NSString).lastPathComponent
        let live = try spawn(sleeper, ["60"])
        let short = try spawn(sleeper, ["2"])
        defer { end(live); end(short) }
        #expect(eventually { Proc.path(live.processIdentifier) != nil && Proc.path(short.processIdentifier) != nil })
        let manager = TrackManager(home: home)
        manager.discoveryInterval = 200_000_000
        let track = try manager.start(TrackOptions(selector: .name(name, glob: false), durationSeconds: 10, intervalSeconds: 1))
        #expect(eventually(30) { manager.status(track.trackId)?.state != "running" })
        let ended = try #require(manager.status(track.trackId))
        #expect(ended.endReason == "duration_elapsed", "\(ended.endReason ?? "-")")
        store.drain()
        #expect(storedRuns(store).map(\.pid) == [short.processIdentifier], "duration_elapsed: only the instance that exited")
        #expect(ended.baseline?.runs == 1)

        // The session of a running track died: its stored report reads as interrupted and adds no Run.
        let dead = try spawn("/usr/bin/true", [])
        dead.waitUntilExit()
        var running = ended
        running.trackId = "trk-interrupted"
        running.state = "running"; running.endReason = nil; running.endedAt = nil
        try TrackManager.fileEncoder.encode(TrackManager.Stored(sessionPid: dead.processIdentifier, report: running))
            .write(to: TrackManager.tracksDir(home).appendingPathComponent(running.trackId + ".json"))
        let reader = TrackManager(home: home)
        #expect(reader.status(running.trackId)?.state == "interrupted")
        #expect(reader.list().contains { $0.trackId == running.trackId && $0.state == "interrupted" })
        reader.durations.drain()
        #expect(storedRuns(store).map(\.pid) == [short.processIdentifier], "interrupted: no new Run")
    }

    /// DUR-005, DUR-006, DUR-028, DUR-029, DUR-032, DUR-039.
    @Test func pidTracksWaitsAndDeduplication() throws {
        let home = TestTemp.dir()
        let store = DurationStore.forHome(home)
        let soloStore = DurationStore.forHome(TestTemp.dir())
        let sleeper = try signedCopy("/bin/sleep", to: home.appendingPathComponent(String(repeating: "é", count: 40)))
        // 6 s jobs observed from 3 s after their start: a Run near 6 s comes from the kernel start, near 3 s from the admission.
        let job = try spawn(sleeper, ["6"])
        let solo = try spawn("/bin/sleep", ["6"])
        defer { end(job); end(solo) }
        usleep(3_000_000)
        let manager = TrackManager(home: home)
        let track = try manager.start(TrackOptions(selector: .pid(job.processIdentifier, startToken: nil), durationSeconds: 60, intervalSeconds: 1))
        let soloWait = Box<WaitResult?>(nil)
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            soloWait.value = Waiter(condition: .processExit(pid: solo.processIdentifier, startToken: nil), timeout: 20, durations: soloStore).run()
        }
        let wait = Waiter(condition: .processExit(pid: job.processIdentifier, startToken: nil), timeout: 20, durations: store).run()
        group.wait()
        #expect(wait.state == "met" && soloWait.value?.state == "met")
        #expect(eventually(10) { manager.status(track.trackId)?.state != "running" })
        store.drain()
        let runs = storedRuns(store)
        #expect(runs.count == 2, "one Run from the track and one from the wait")
        #expect(runs.allSatisfy { abs(Double($0.durationTenths) / 10 - 6) <= 1.1 }, "DUR-005: from the kernel start: \(runs.map(\.durationTenths))")
        soloStore.drain()
        let soloRuns = storedRuns(soloStore)
        #expect(soloRuns.count == 1, "DUR-028: one Run from the wait alone")
        #expect(soloRuns.allSatisfy { abs(Double($0.durationTenths) / 10 - 6) <= 1.1 && $0.resolutionTenths <= 5 },
                "DUR-028: the wait's own Run: \(soloRuns.map { ($0.durationTenths, $0.resolutionTenths) })")
        let baseline = try #require(store.lookup(path: sleeper, subcommand: ""))
        #expect(baseline.runs == 1, "DUR-032")
        let label = try #require(manager.status(track.trackId)?.baseline?.label)
        #expect(label.utf8.count <= 64 && (sleeper as NSString).lastPathComponent.hasPrefix(label) && label == baseline.label)

        let tree = try spawn("/bin/sh", ["-c", "/bin/sleep 1 & /bin/sleep 1 & /bin/sleep 1 & wait"])
        defer { end(tree) }
        let t2 = try manager.start(TrackOptions(selector: .pid(tree.processIdentifier, startToken: nil), includeChildren: true,
                                                durationSeconds: 60, intervalSeconds: 1))
        #expect(eventually(15) { manager.status(t2.trackId)?.state != "running" })
        store.drain()
        #expect(storedRuns(store).count == 3, "DUR-006: only the root")
        #expect(storedRuns(store).last?.pid == tree.processIdentifier)

        let slow = try spawn("/bin/sleep", ["30"])
        defer { end(slow) }
        #expect(Waiter(condition: .processExit(pid: slow.processIdentifier, startToken: nil), timeout: 2, durations: store).run().state == "timed_out")
        end(slow)
        #expect(Waiter(condition: .processExit(pid: slow.processIdentifier, startToken: nil), timeout: 2, durations: store).run().state == "unavailable")
        store.drain()
        #expect(!storedRuns(store).contains { $0.pid == slow.processIdentifier }, "DUR-029")
    }

    /// DUR-045: the Server writes queued Runs when its input closes.
    @Test func serverDrainsOnInputClose() throws {
        let home = TestTemp.dir()
        let store = DurationStore.forHome(home)
        store.holdsWrites = true
        defer { store.holdsWrites = false }
        let job = try spawn("/bin/sleep", ["1"])
        defer { end(job) }
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "track_processes", ["action": "start", "pid": Int(job.processIdentifier), "durationSeconds": 30, "intervalSeconds": 1])
        _ = h.response(1)
        #expect(eventually(10) { store.queuedCount == 1 })
        #expect(storedRuns(store).isEmpty)
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
        #expect(storedRuns(store).count == 1 && store.queuedCount == 0)
    }

    /// DUR-045, DUR-039: queued Runs are written by the shutdown that the Server's SIGTERM, SIGINT and SIGHUP handlers
    /// call while its input is still open, by the end of `aistats track` (also after its SIGINT handler stopped the
    /// track), and by `aistats wait process_exit` after `met`. The final report of `aistats track` carries the label.
    @Test func recordersDrainOnEveryExit() throws {
        let home = TestTemp.dir()
        let store = DurationStore.forHome(home)
        store.holdsWrites = true
        defer { store.holdsWrites = false }

        let a = try spawn("/bin/sleep", ["1"])
        defer { end(a) }
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "track_processes", ["action": "start", "pid": Int(a.processIdentifier), "durationSeconds": 30, "intervalSeconds": 1])
        _ = h.response(1)
        #expect(eventually(10) { store.queuedCount == 1 })
        h.server.shutdown()
        #expect(storedRuns(store).count == 1 && store.queuedCount == 0, "Server signal route")
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)

        let b = try spawn("/bin/sleep", ["1"])
        defer { end(b) }
        let manager = TrackManager(home: home)
        let t = try manager.start(TrackOptions(selector: .pid(b.processIdentifier, startToken: nil), durationSeconds: 30, intervalSeconds: 1))
        #expect(eventually(10) { store.queuedCount == 1 })
        _ = try? manager.stop(t.trackId)
        let final = try #require(manager.finalReport(t.trackId, captureWait: 1))
        #expect(storedRuns(store).count == 2 && store.queuedCount == 0, "aistats track")
        #expect(final.baseline?.label == "sleep" && final.baseline?.runs == 2, "DUR-039: \(String(describing: final.baseline))")

        let c = try spawn("/bin/sleep", ["1"])
        defer { end(c) }
        let w = Waiter(condition: .processExit(pid: c.processIdentifier, startToken: nil), timeout: 20, durations: store).runToExit()
        #expect(w.state == "met")
        #expect(storedRuns(store).count == 3 && store.queuedCount == 0, "aistats wait process_exit")
    }

    /// DUR-015: Baseline lookups run off the tracker queue. A store lock held elsewhere, or an index rebuild after each
    /// recorded Run, never delays a tick, also when every tick persists the report.
    @Test func lookupsNeverDelayTheTrackTick() throws {
        let home = TestTemp.dir()
        let store = DurationStore.forHome(home)
        try fixture(store, (0..<DurationStore.maxSignatures).flatMap { sig in
            (0..<DurationStore.maxRunsPerSignature).map { i in pending("/fixtures/job\(sig)", pid: Int32(1000 + sig * 64 + i), token: 1) }
        })
        let sleeper = try signedCopy("/bin/sleep", to: home.appendingPathComponent("aistats-tick-\(UUID().uuidString.prefix(6).lowercased())"))
        let name = (sleeper as NSString).lastPathComponent
        let manager = TrackManager(home: home)
        manager.discoveryInterval = 200_000_000
        manager.persistInterval = 0
        let ticks = Box<[UInt64]>([])
        let track = try manager.start(TrackOptions(selector: .name(name, glob: false), durationSeconds: 60, intervalSeconds: 1),
                                      onTick: { _ in ticks.value.append(Proc.nowNs()) })
        let job = try Child.sh("for i in 1 2 3 4 5 6 7 8; do '\(sleeper)' 1; done")
        defer { job.kill() }
        #expect(eventually(20) { store.drain(); return storedRuns(store).contains { $0.startToken != 1 } }, "a recorded Run of the job")

        // Another process holds the exclusive lock, as during its compaction.
        let fd = open(store.lockURL.path, O_RDWR | O_CLOEXEC)
        #expect(fd >= 0 && flock(fd, LOCK_EX) == 0)
        let blocked = Box(false)
        DispatchQueue.global().async { _ = manager.status(track.trackId); blocked.value = true }
        let listStart = Proc.nowNs()
        _ = manager.list()
        manager.queue.sync {}
        #expect(Double(Proc.nowNs() - listStart) / 1e9 < 0.5, "list and the tracker queue stay free while a lookup waits")
        usleep(2_500_000)
        #expect(!blocked.value, "the status lookup waited for the shared lock")
        flock(fd, LOCK_UN)
        close(fd)
        #expect(eventually(5) { blocked.value })
        #expect(eventually(30) { store.drain(); return manager.status(track.trackId)?.baseline?.runs == 8 })
        _ = try manager.stop(track.trackId)

        let times = ticks.value
        let gaps = zip(times.dropFirst(), times).map { Double($0 - $1) / 1e9 }
        let worst = gaps.max() ?? 0
        print("DUR-015 worst tick gap \(worst) s over \(gaps.count) ticks")
        #expect(gaps.count >= 5)
        #expect(worst < 1.5, "a tick waited behind a lookup: \(gaps)")
    }

    /// DUR-033: at most 3 Baselines, counted omissions, and the 4,096-byte check with long paths.
    @Test func findProcessesBaselineBudget() throws {
        let home = TestTemp.dir()
        let store = DurationStore.forHome(home)
        let prefix = "aistats-bl-\(UUID().uuidString.prefix(6).lowercased())"
        let paths = try (0..<5).map { try signedCopy("/bin/sleep", to: home.appendingPathComponent("\(prefix)-\($0)")) }
        var deep = home
        while deep.path.utf8.count < 880 { deep.appendPathComponent(String(repeating: "d", count: 100), isDirectory: true) }
        let longPaths = try (0..<5).map { try signedCopy("/bin/sleep", to: deep.appendingPathComponent("\(prefix)-long-\($0)")) }
        #expect(longPaths.allSatisfy { $0.utf8.count > 900 && $0.utf8.count < 1024 })
        try fixture(store, (paths + longPaths).enumerated().map { pending($1, pid: Int32(50 + $0), token: 1) })
        var children: [Process] = []
        defer { children.forEach(end) }
        for path in paths + longPaths { for _ in 0..<3 { children.append(try spawn(path, ["60"])) } }
        #expect(eventually { children.allSatisfy { Proc.path($0.processIdentifier) != nil } })
        let h = MCPHarness(home: home)
        h.initialize()
        h.call(1, "find_processes", ["name": prefix + "-?", "match": "glob", "limit": 15, "includeBaseline": true])
        let r = try #require(sc(h.response(1)))
        #expect(((r["processes"] as? [Any])?.count ?? 0) + (r["processesOmitted"] as? Int ?? 0) == 15 && r["matched"] as? Int == 15)
        #expect((r["baselines"] as? [[String: Any]])?.count == 3 && (1...2).contains(r["baselinesOmitted"] as? Int ?? 0))
        #expect((try #require(h.line(1))).utf8.count <= 4096)
        h.call(2, "find_processes", ["path": deep.path + "/*", "match": "glob", "limit": 15, "includeBaseline": true])
        let long = try #require(sc(h.response(2)))
        let rows = long["processes"] as? [[String: Any]] ?? []
        let shown = (long["baselines"] as? [Any])?.count ?? 0
        #expect((try #require(h.line(2))).utf8.count <= 4096)
        #expect(long["matched"] as? Int == 15 && rows.count + (long["processesOmitted"] as? Int ?? 0) == 15 && rows.count < 15)
        #expect(rows.allSatisfy { ($0["baselineIndex"] as? Int).map { $0 < shown } ?? false })
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
    }
}
