import Darwin
import Foundation
import Testing
@testable import StatsCore

// Regression tests for the second review's findings (H1–H5, M1–M5, L2). Each reproduces the reviewer's
// scenario in an isolated temp folder.

private func tempDir() -> URL { TestTemp.dir() }

private func writeCursor(_ f: FakeAgents, _ text: String) throws {
    try FileManager.default.createDirectory(at: f.cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: f.cursorConfig, atomically: true, encoding: .utf8)
}

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
}

private func aistatsEntry(_ url: URL) throws -> [String: Any]? {
    let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    return (root["mcpServers"] as? [String: Any])?["aistats"] as? [String: Any]
}

private func signedCopy(_ source: String, to dir: URL, name: String) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: url)
    let r = try Subprocess.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path], timeout: 120)
    #expect(r.succeeded, "codesign: \(r.stderr)")
    return url
}

private final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct ReReviewRegistrationTests {
    /// H2: JSONSerialization keeps one of two duplicate keys, the agent may use the other.
    @Test func duplicateKeysOnTheWayToTheEntryAreRefused() throws {
        let f = try FakeAgents()
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let cases = [
            #"{"mcpServers":{},"mcpServers":{"aistats":{"command":"/foreign/duplicate","args":["mcp"]}}}"#,
            #"{"mcpServers":{"aistats":{"command":"/x/aistats","args":["mcp"]},"aistats":{"command":"/foreign","args":["mcp"]}}}"#,
            #"{"mcpServers":{"aistats":{"command":"/x/aistats","command":"/foreign","args":["mcp"]}}}"#,
            #"{"mcpServers":{"aistats":{"command":"/foreign","args":["mcp"]},"aistats":{"command":"/x/aistats","args":["mcp"]}}}"#,
        ]
        for text in cases {
            try writeCursor(f, text)
            guard case .checkFailed(let why) = r.status(.cursor).state else { Issue.record("not refused: \(text)"); continue }
            #expect(why.contains("twice"), "\(why)")
            #expect(!r.install(.cursor).ok)
            #expect(!r.uninstall(.cursor).ok)
            #expect(try String(contentsOf: f.cursorConfig, encoding: .utf8) == text)
        }
        #expect(f.backups(.cursor).isEmpty)
        // Duplicates elsewhere in the document are not ours to judge.
        try writeCursor(f, #"{"other":{"a":1,"a":2},"mcpServers":{}}"#)
        #expect(r.status(.cursor).state == .notInstalled)
    }

    /// H2: an AIStats bundle reached through links is ours only if its binary really is inside it.
    @Test func bundleOwnershipUsesRealPaths() throws {
        let f = try FakeAgents()
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let fm = FileManager.default
        func entry(_ c: String) -> RegistrationEntry { RegistrationEntry(command: c, args: ["mcp"], env: [:], extras: [], raw: Data()) }
        let app = f.root.appendingPathComponent("linked/AIStats.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.oozoofrog.aistats"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fm.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/aistats"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let alias = f.root.appendingPathComponent("alias.app")
        try fm.createSymbolicLink(at: alias, withDestinationURL: app)
        guard case .nameConflict = r.classify(entry(alias.path + "/Contents/MacOS/aistats")) else { Issue.record("alias, binary links out"); return }
        guard case .nameConflict = r.classify(entry(app.path + "/Contents/MacOS/aistats")) else { Issue.record("binary links out"); return }
        // A real AIStats bundle reached through an alias is still ours.
        let real = try f.bundle("AIStats", identifier: "com.oozoofrog.aistats")
        let bundle = URL(fileURLWithPath: real).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let alias2 = f.root.appendingPathComponent("alias2.app")
        try fm.createSymbolicLink(at: alias2, withDestinationURL: bundle)
        let viaAlias = alias2.path + "/Contents/MacOS/aistats"
        #expect(r.classify(entry(viaAlias)) == .pathUpdateNeeded(registered: viaAlias))
    }

    /// H3: consent names the whole entry (env values included) and is checked again on the bytes edited.
    @Test func replaceConsentIsBoundToTheExactEntry() throws {
        let f = try FakeAgents()
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        func config(_ value: String) -> String { #"{"mcpServers":{"aistats":{"command":"/shared","args":["mcp"],"env":{"CUSTOM":"\#(value)"}}}}"# }
        try writeCursor(f, config("first"))
        let first = r.status(.cursor)
        let fp = try #require(first.entryFingerprint)
        // Same summary (env values are hidden), different entry.
        try writeCursor(f, config("second"))
        #expect(r.status(.cursor).state.detail == first.state.detail)
        #expect(r.status(.cursor).entryFingerprint != fp)
        let collision = r.install(.cursor, replacing: fp)
        #expect(!collision.ok, "\(collision.message)")
        #expect(try String(contentsOf: f.cursorConfig, encoding: .utf8) == config("second"))
        // The entry changes after the check, before the edit: the edit refuses.
        let fp2 = try #require(r.status(.cursor).entryFingerprint)
        r.afterInspect = { _ in try? config("third").write(to: f.cursorConfig, atomically: true, encoding: .utf8) }
        let race = r.install(.cursor, replacing: fp2)
        r.afterInspect = nil
        #expect(!race.ok && race.message.contains("changed"), "\(race.message)")
        #expect(try String(contentsOf: f.cursorConfig, encoding: .utf8) == config("third"))
        #expect(f.backups(.cursor).isEmpty)

        // A CLI agent: checked on the bytes read right before its CLI runs, and those bytes are the backup.
        try config("first").write(to: f.claudeConfig, atomically: true, encoding: .utf8)
        let cfp = try #require(r.status(.claudeCode).entryFingerprint)
        r.afterInspect = { _ in try? config("other").write(to: f.claudeConfig, atomically: true, encoding: .utf8) }
        let cc = r.install(.claudeCode, replacing: cfp)
        r.afterInspect = nil
        #expect(!cc.ok && cc.message.contains("changed"), "\(cc.message)")
        #expect(!f.calls().contains { $0.hasPrefix("claude mcp add") || $0.hasPrefix("claude mcp remove") })
        let ok = r.install(.claudeCode, replacing: r.status(.claudeCode).entryFingerprint)
        #expect(ok.ok, "\(ok.message)")
        #expect(try String(contentsOf: URL(fileURLWithPath: try #require(ok.backup)), encoding: .utf8) == config("other"))
    }

    /// H4: a permissions-only change or a re-pointed symlink during the edit stops it (nothing is
    /// "repaired"); the file's mode is kept; a symlinked config is edited at its real file and says so.
    @Test func commitStopsOnAnyChangeAndKeepsMode() throws {
        let f = try FakeAgents()
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let empty = #"{"mcpServers":{}}"#
        try writeCursor(f, empty)
        chmod(f.cursorConfig.path, 0o640)
        let mine = f.cursorConfig.path
        JSONConfigEditor.beforeCommit(mine) { url in chmod(url.path, 0o400) }
        let modeRace = r.install(.cursor)
        JSONConfigEditor.beforeCommit(mine, nil)
        #expect(!modeRace.ok && modeRace.message.contains("changed"), "\(modeRace.message)")
        #expect(mode(f.cursorConfig) == 0o400)
        #expect(try String(contentsOf: f.cursorConfig, encoding: .utf8) == empty)
        #expect(f.backups(.cursor).isEmpty, "the stopped edit's backup is removed")
        chmod(f.cursorConfig.path, 0o640)
        #expect(r.install(.cursor).ok)
        #expect(mode(f.cursorConfig) == 0o640, "mode kept")

        let dir = f.cursorConfig.deletingLastPathComponent()
        let old = dir.appendingPathComponent("old-target.json"), new = dir.appendingPathComponent("new-target.json")
        try empty.write(to: old, atomically: true, encoding: .utf8)
        let foreign = #"{"mcpServers":{"aistats":{"command":"/new-target-foreign","args":["mcp"]}}}"#
        try foreign.write(to: new, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: f.cursorConfig)
        try FileManager.default.createSymbolicLink(at: f.cursorConfig, withDestinationURL: old)
        let realOld = try #require(AgentRegistrar.realPath(old.path))
        JSONConfigEditor.beforeCommit(realOld) { _ in
            let staging = dir.appendingPathComponent("new-link")
            try? FileManager.default.createSymbolicLink(at: staging, withDestinationURL: new)
            rename(staging.path, mine)
        }
        let linkRace = r.install(.cursor)
        JSONConfigEditor.beforeCommit(realOld, nil)
        #expect(!linkRace.ok, "\(linkRace.message)")
        #expect(try String(contentsOf: old, encoding: .utf8) == empty, "former target untouched")
        #expect(try String(contentsOf: new, encoding: .utf8) == foreign, "new target untouched")

        try FileManager.default.removeItem(at: f.cursorConfig)
        try FileManager.default.createSymbolicLink(at: f.cursorConfig, withDestinationURL: old)
        let edited = r.install(.cursor)
        #expect(edited.ok && edited.message.contains(realOld), "\(edited.message)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: mine)) == old.path, "link kept")
    }

    /// H5: a failed Claude Code replace puts back exactly the entry the file held, whatever its type
    /// (it used to delete HTTP entries and drop fields, and compared fields in dictionary order).
    @Test func failedClaudeReplaceRestoresAnyEntryExactly() throws {
        let f = try FakeAgents()
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment(["FAKE_FAIL_CLAUDE_ADD": "1"]))
        let entries = [
            #"{"type":"http","url":"http://127.0.0.1:9/aistats","headers":{"X-Config-Test":"keep"}}"#,
            #"{"type":"stdio","command":"/foreign","args":["mcp"],"env":{"X":"one=two"},"custom":{"keep":true}}"#,
            #"{"command":"/foreign","args":["mcp"],"env":{"X":"one=two"}}"#,
        ]
        for e in entries {
            let expected = try #require(try JSONSerialization.jsonObject(with: Data(e.utf8)) as? [String: Any])
            for _ in 0..<4 {
                try #"{"numStartups":3,"mcpServers":{"aistats":\#(e)}}"#.write(to: f.claudeConfig, atomically: true, encoding: .utf8)
                let fp = try #require(r.status(.claudeCode).entryFingerprint)
                let o = r.install(.claudeCode, replacing: fp)
                #expect(!o.ok && o.message.contains("restored"), "\(o.message)")
                #expect(NSDictionary(dictionary: try #require(try aistatsEntry(f.claudeConfig))).isEqual(to: expected))
                #expect(r.status(.claudeCode).entryFingerprint == fp)
            }
        }
        #expect(f.calls().filter { $0.hasPrefix("claude mcp add-json --scope user aistats") }.count == 12)
    }
}

@Suite struct ReReviewSubprocessTests {
    /// M1: the leader exits on TERM and the pipes close, while a descendant ignores TERM.
    @Test func cancelKillsATermIgnoringDescendantAfterTheLeaderExits() throws {
        let pidFile = tempDir().appendingPathComponent("child-pid")
        let token = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { token.cancel() }
        let r = try Subprocess.run("/bin/sh", ["-c", "trap 'exit 0' TERM; (trap '' TERM; exec /bin/sleep 30) >/dev/null 2>&1 & echo $! > \"$1\"; wait",
                                               "sh", pidFile.path], timeout: 20, cancel: token)
        #expect(r.cancelled)
        let pid = Int32(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0)
        #expect(eventually(3) { Proc.usage(pid) == nil }, "the TERM-ignoring descendant survived")
        if pid > 0, Proc.usage(pid) != nil { kill(pid, SIGKILL) }
    }
}

@Suite struct ReReviewMCPTests {
    /// M4: one validator for every id; cancellation ids match type-exactly; method+result is invalid.
    /// M3: over-long ids are rejected, error lines fit the budget, waits are admitted before parsing.
    @Test func idsShapesBudgetAndAdmission() throws {
        let h = MCPHarness()
        defer { h.close() }
        let me = Int(getpid())
        h.send(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "wait_for", "arguments": ["condition": "process_exit", "pid": me, "timeoutSeconds": 20]]])
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": true]])
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "1"]])
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1.5]])
        h.send(["jsonrpc": "2.0", "id": 1, "method": "resources/list"])
        let inUse = try #require(h.response(1, timeout: 10))
        #expect((inUse["error"] as? [String: Any])?["code"] as? Int == -32600, "id 1 is still pending: \(inUse)")

        h.send(["jsonrpc": "2.0", "id": 5, "method": "ping", "result": [String: Any]()])
        let both = try #require(h.response(5))
        #expect((both["error"] as? [String: Any])?["code"] as? Int == -32600, "\(both)")

        let longID = String(repeating: "y", count: 300)
        h.send(["jsonrpc": "2.0", "id": longID, "method": "ping"])
        h.send(["jsonrpc": "2.0", "id": 6, "method": "tools/call",
                "params": ["name": "track_processes", "arguments": ["action": "status", "trackId": String(repeating: "x", count: 6000)]]])
        let status = try #require(h.response(6))
        #expect((status["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(h.rawLines.allSatisfy { $0.utf8.count <= MCPServer.maxResponseBytes || $0.contains("\"tools\"") },
                "\(h.rawLines.map(\.utf8.count))")
        #expect(h.messages().contains { m in
            m["id"] is NSNull && ((m["error"] as? [String: Any])?["message"] as? String)?.contains("at most 256") == true
        })

        // Seven more valid waits fill the eight slots; a malformed ninth is refused before its arguments are read.
        for id in 10..<17 {
            h.send(["jsonrpc": "2.0", "id": id, "method": "tools/call",
                    "params": ["name": "wait_for", "arguments": ["condition": "process_exit", "pid": me, "timeoutSeconds": 20]]])
        }
        h.send(["jsonrpc": "2.0", "id": 17, "method": "tools/call", "params": ["name": "wait_for", "arguments": ["condition": "nope"]]])
        let refused = try #require(h.response(17))
        #expect((refused["error"] as? [String: Any])?["code"] as? Int == -32000, "\(refused)")
        for id in [1] + Array(10..<17) { h.cancel(id) }
    }

    /// M3: a client that doesn't read stdout makes the server stop reading stdin (bounded memory).
    @Test func readerPausesWhileOutputIsNotRead() throws {
        let home = tempDir()
        let released = Flag()
        let server = MCPServer(history: HistoryStore(directory: home), activity: ActivityStore(directory: home),
                               tracks: TrackManager(home: home), name: "backpressure",
                               write: { _ in while !released.isSet { usleep(1000) } })
        let ping = #"{"jsonrpc":"2.0","id":"\#(String(repeating: "p", count: 200))","method":"ping"}"#
        let reads = Counter()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            server.run(readLine: { reads.next() <= 10_000 ? ping : nil })
            done.signal()
        }
        Thread.sleep(forTimeInterval: 1.5)
        let n = reads.value
        #expect(n < 3_000, "read \(n) lines while nothing was written")
        released.set()
        #expect(done.wait(timeout: .now() + 60) == .success)
        #expect(reads.value > 10_000)
    }
}

@Suite(.serialized) struct ReReviewTrackTests {
    /// M5: an instance that started while the first still ran, but was discovered after it exited, is an
    /// additional instance, not a restart.
    @Test func overlapNoticedLateIsAnAdditionalInstance() throws {
        let sleeper = try uniqueSleeper(in: tempDir())
        let a = try Child(sleeper.path, ["60"])
        defer { a.kill() }
        #expect(eventually { Proc.name(a.pid) == sleeper.lastPathComponent })
        let m = TrackManager(home: tempDir())
        m.discoveryInterval = 4_000_000_000
        let t = try m.start(TrackOptions(selector: .name(sleeper.lastPathComponent, glob: false), durationSeconds: 60, intervalSeconds: 1))
        let b = try Child(sleeper.path, ["60"])
        defer { b.kill() }
        #expect(eventually { Proc.usage(b.pid) != nil })
        usleep(250_000)
        a.kill()
        #expect(eventually(30) { (m.status(t.trackId)?.aggregate.membersSeen ?? 0) >= 2 })
        let r = try m.stop(t.trackId)
        #expect(r.additionalInstances == 1 && r.restartCount == 0, "\(r.events.map { ($0.kind, $0.pid) })")
    }

    /// M5: a saved summary read back only keeps paths that were checked against a path selector.
    @Test func savedSummariesDropUncheckedPaths() throws {
        let home = tempDir()
        let child = try Child("/bin/sleep", ["60"])
        defer { child.kill() }
        let m = TrackManager(home: home)
        let t = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60))
        var r = try m.stop(t.trackId)
        r.trackId = "trk-legacy01"
        r.selector = "path"
        r.members[0].path = "/legacy/private/child-executable"
        TrackManager.save(r, home: home)
        let loaded = try #require(TrackManager.load("trk-legacy01", home: home))
        #expect(loaded.members.first?.path == nil)
        // MCP output never carries the internal flag.
        let wire = String(decoding: try MCPServer.encoder.encode(loaded), as: UTF8.self)
        #expect(!wire.contains("pathMatched"))
    }

    /// M2: dropping managers with running tracks used to leak a kqueue thread each.
    @Test func droppedManagersStopTheirThreads() throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.kill() }
        let home = tempDir()
        var states: [Weak] = []
        var ids: [String] = []
        for _ in 0..<12 {
            let m = TrackManager(home: home)
            let t = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60))
            ids.append(t.trackId)
            states += m.watcherThreadStates().map(Weak.init)
        }
        #expect(states.count == 12)
        #expect(eventually(10) { states.allSatisfy { $0.object == nil } }, "kqueue threads still running")
        #expect(eventually(10) { ids.allSatisfy { TrackManager.load($0, home: home)?.state == "stopped" } })
    }

    /// L2: the exited member holding the highest lifetime peak is evicted; the aggregate keeps exactly its peak.
    @Test func evictedMembersPeakIsKeptExactly() throws {
        let dir = tempDir()
        let name = "aistats-peak-\(UUID().uuidString.prefix(4).lowercased())"
        let shell = try signedCopy("/bin/bash", to: dir, name: name)
        let ready = dir.appendingPathComponent("ready")
        // Shells that wait in `read` on a pipe never written to: no forks while tracked.
        func start(_ script: String) throws -> (Process, Pipe) {
            let p = Process(), input = Pipe()
            p.executableURL = shell
            p.arguments = ["-c", script]
            p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            return (p, input)
        }
        func stop(_ p: Process) { if p.isRunning { p.terminate() }; p.waitUntilExit() }
        let (big, bigIn) = try start("x=$(head -c 40000000 /dev/zero | tr '\\0' a); unset x; : > '\(ready.path)'; read line")
        defer { stop(big); _ = bigIn }
        let (small, smallIn) = try start("read line")
        defer { stop(small); _ = smallIn }
        #expect(eventually(120) { FileManager.default.fileExists(atPath: ready.path) })
        let peak = try #require(Proc.usage(big.processIdentifier)).lifetimeMaxFootprint
        #expect(peak > 30_000_000, "peak \(peak)")

        let m = TrackManager(home: tempDir())
        m.discoveryInterval = 300_000_000
        m.maxMembers = 2
        let t = try m.start(TrackOptions(selector: .name(name, glob: false), durationSeconds: 600, intervalSeconds: 1))
        #expect(t.aggregate.membersSeen == 2)
        #expect(eventually(30) { (m.status(t.trackId)?.validSamples ?? 0) >= 1 })
        stop(big)
        #expect(eventually(30) { (m.status(t.trackId)?.aggregate.liveMembers ?? 0) == 1 })
        // A third instance needs the room: the exited big one is evicted.
        let (third, thirdIn) = try start("read line")
        defer { stop(third); _ = thirdIn }
        #expect(eventually(30) { (m.status(t.trackId)?.aggregate.membersSeen ?? 0) == 3 })
        let r = try m.stop(t.trackId)
        #expect(!r.members.contains { $0.pid == big.processIdentifier }, "the big one was evicted")
        #expect(r.membersDropped == nil)
        #expect(r.aggregate.largestProcessLifetimePeakBytes == peak)
    }
}
