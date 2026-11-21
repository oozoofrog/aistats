import Darwin
import Foundation
import Testing
@testable import StatsCore

private func tempDir() -> URL { TestTemp.dir() }

// MARK: - In-process MCP harness

/// Feeds lines to `MCPServer.run` from the test and collects responses by id.
final class MCPHarness: @unchecked Sendable {
    private let lock = NSCondition()
    private var input: [String?] = []
    private var responses: [String: [String: Any]] = [:]
    private(set) var rawLines: [String] = []
    let finished = DispatchSemaphore(value: 0)
    let server: MCPServer

    init(home: URL = tempDir()) {
        var harness: MCPHarness?
        server = MCPServer(history: HistoryStore(directory: home), activity: ActivityStore(directory: home),
                           tracks: TrackManager(home: home), name: "test-agent",
                           write: { data in harness?.received(data) })
        harness = self
        Thread.detachNewThread { [self] in
            server.run(readLine: { self.nextLine() })
            finished.signal()
        }
    }

    private func nextLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        while input.isEmpty { lock.wait() }
        return input.removeFirst()
    }

    func send(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        sendRaw(String(decoding: data, as: UTF8.self))
    }

    func sendRaw(_ line: String) {
        lock.lock(); input.append(line); lock.broadcast(); lock.unlock()
    }

    func cancel(_ id: Int) {
        send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id, "reason": "test"]])
    }

    /// Every message received so far, parsed.
    func messages() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return rawLines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func line(_ id: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return rawLines.first { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["id"] as? Int == id }
    }

    func close() {
        lock.lock(); input.append(nil); lock.broadcast(); lock.unlock()
    }

    private func received(_ data: Data) {
        let line = String(decoding: data, as: UTF8.self)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        lock.lock()
        rawLines.append(line)
        if let object, let id = object["id"] { responses["\(id)"] = object }
        lock.broadcast()
        lock.unlock()
    }

    func response(_ id: Int, timeout: TimeInterval = 30) -> [String: Any]? {
        let end = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while responses["\(id)"] == nil {
            if !lock.wait(until: end) { break }
        }
        return responses["\(id)"]
    }

    func hasResponse(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return responses["\(id)"] != nil
    }

    func call(_ id: Int, _ tool: String, _ args: [String: Any] = [:]) {
        send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": args]])
    }

    func initialize(client: String = "test") {
        send(["jsonrpc": "2.0", "id": 0, "method": "initialize",
              "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": client]]])
        _ = response(0)
    }
}

private func structured(_ r: [String: Any]?) -> [String: Any]? {
    (r?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
}

@Suite(.serialized) struct MCPServerTests {
    @Test func listsAllToolsAndAnswersCompactly() throws {
        let h = MCPHarness()
        h.initialize()
        h.send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try #require((h.response(1)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["get_system_stats", "get_top_processes", "get_stats_history", "diagnose_system",
                                                      "find_processes", "track_processes", "wait_for", "get_environment", "get_process_tree", "get_agent_sessions"])
        h.call(2, "find_processes", ["name": "*", "match": "glob", "limit": 15])
        let found = try #require(h.response(2))
        #expect((structured(found)?["processes"] as? [Any])?.count == 15)
        let line = h.rawLines.first { $0.contains("\"id\":2") } ?? ""
        #expect(line.utf8.count <= 4096, "find_processes response is \(line.utf8.count) bytes")
        #expect(!line.contains("00000000001"), "doubles are written in shortest form")
        h.call(3, "find_processes", ["pid": 1, "name": "x"])
        #expect((h.response(3)?["result"] as? [String: Any])?["isError"] as? Bool == true)
        h.call(4, "get_stats_history", ["minutes": 5, "maxPoints": 0])
        #expect((h.response(4)?["result"] as? [String: Any])?["isError"] as? Bool == false)
        h.call(5, "diagnose_system", ["purpose": "heavy_work"])
        let d = try #require(structured(h.response(5)))
        #expect(["issue_detected", "no_clear_issue", "insufficient_data"].contains(d["status"] as? String ?? ""))
        #expect(["ready", "caution", "unknown"].contains(d["readiness"] as? String ?? ""))
        h.call(6, "get_environment", ["includeToolchain": false])
        #expect(structured(h.response(6))?["logicalCores"] != nil)
        h.close()
        #expect(h.finished.wait(timeout: .now() + 5) == .success)
    }

    @Test func pingAndCancelDuringWait() throws {
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        let h = MCPHarness()
        h.initialize()
        h.call(10, "wait_for", ["condition": "process_exit", "pid": Int(child.pid), "timeoutSeconds": 20])
        h.send(["jsonrpc": "2.0", "id": 11, "method": "ping"])
        #expect(h.response(11, timeout: 20) != nil, "ping is answered while wait_for is pending")
        #expect(!h.hasResponse(10))
        h.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 10, "reason": "test"]])
        // Other calls still work after the cancellation.
        h.call(12, "find_processes", ["pid": Int(child.pid)])
        #expect(h.response(12) != nil)
        child.kill()
        // The exit is seen within 250 ms; a later call proves time passed on the server's side too.
        usleep(1_500_000)
        h.call(14, "find_processes", ["pid": 1])
        #expect(h.response(14, timeout: 30) != nil)
        #expect(!h.hasResponse(10), "a cancelled wait sends no response, even after its condition is met")

        // A wait that completes normally answers with state met.
        let short = try Child("/bin/sleep", ["1"])
        h.call(13, "wait_for", ["condition": "process_exit", "pid": Int(short.pid), "timeoutSeconds": 10])
        let met = try #require(structured(h.response(13, timeout: 30)))
        #expect(met["state"] as? String == "met")
        h.close()
        #expect(h.finished.wait(timeout: .now() + 5) == .success)
    }

    @Test func eofWhileWaitPendingEndsPromptly() throws {
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        let h = MCPHarness()
        h.initialize()
        h.call(20, "wait_for", ["condition": "process_exit", "pid": Int(child.pid), "timeoutSeconds": 50])
        h.call(21, "track_processes", ["action": "start", "pid": Int(child.pid), "durationSeconds": 60])
        let started = try #require(structured(h.response(21)))
        let id = try #require(started["trackId"] as? String)
        usleep(300_000)
        let begin = Date()
        h.close()
        #expect(h.finished.wait(timeout: .now() + 30) == .success)
        // Ending doesn't wait for the 50 s wait_for.
        #expect(Date().timeIntervalSince(begin) < 30)
        #expect(!h.hasResponse(20))
        #expect(TrackManager.load(id, home: h.server.tracksHome)?.endReason == "session_ended")
    }

    @Test func waitForValidationAndBatch() throws {
        let h = MCPHarness()
        h.initialize()
        h.call(30, "wait_for", ["condition": "nope"])
        #expect((h.response(30)?["result"] as? [String: Any])?["isError"] as? Bool == true)
        h.call(31, "wait_for", ["condition": "cpu_idle", "timeoutSeconds": 99])
        #expect((h.response(31)?["result"] as? [String: Any])?["isError"] as? Bool == true)
        h.call(32, "track_processes", ["action": "status", "trackId": "trk-missing"])
        #expect((h.response(32)?["result"] as? [String: Any])?["isError"] as? Bool == true)
        h.close()
        _ = h.finished.wait(timeout: .now() + 5)
    }

    /// Review MEDIUM 14: malformed envelopes were accepted, scalars got -32700, `[]` got nothing.
    @Test func rejectsMalformedEnvelopesAndBatches() throws {
        let h = MCPHarness()
        h.initialize()
        let bad = [
            #"{"jsonrpc":"1.0","id":101,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
            #"{"id":106,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":107,"method":7}"#,
            #"{"jsonrpc":"2.0","id":108,"method":"ping","params":[1]}"#,
            "42", #""text""#, "[]",
            #"[{"jsonrpc":"2.0","id":109,"method":"ping"}]"#,
        ]
        bad.forEach(h.sendRaw)
        h.sendRaw("not json")
        h.send(["jsonrpc": "2.0", "id": 110, "method": "ping"])
        h.call(111, "no_such_tool")
        #expect(h.response(110) != nil)
        let unknown = try #require(h.response(111))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32602, "unknown tool is a JSON-RPC error")
        let msgs = h.messages()
        let invalid = msgs.filter { ($0["error"] as? [String: Any])?["code"] as? Int == -32600 }
        #expect(invalid.count == bad.count, "every malformed message gets exactly one Invalid Request: \(msgs)")
        #expect(msgs.filter { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 }.count == 1)
        #expect(!msgs.contains { $0["id"] as? Int == 109 && $0["result"] != nil }, "batches are not executed")
        // Ids that are themselves valid are echoed.
        #expect(invalid.contains { $0["id"] as? Int == 101 } && invalid.contains { $0["id"] as? Int == 108 })
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
    }

    /// Calls already queued when stdin closes still get their responses (only waits are dropped).
    @Test func eofAnswersQueuedCalls() throws {
        let h = MCPHarness()
        h.send(["jsonrpc": "2.0", "id": 170, "method": "initialize",
                "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "eof"]]])
        h.call(171, "get_environment", ["includeToolchain": false])
        h.close()
        #expect(h.finished.wait(timeout: .now() + 60) == .success)
        #expect(h.hasResponse(170) && h.hasResponse(171))
    }

    /// Review MEDIUM 14: cancelling get_system_stats still produced its response.
    @Test func cancellationSuppressesAnyPendingResponse() throws {
        let h = MCPHarness()
        h.initialize()
        // Two slow calls keep the work queue busy, so 122 is still queued when its cancellation arrives.
        h.call(120, "diagnose_system")
        h.call(121, "diagnose_system")
        h.call(122, "get_system_stats")
        h.cancel(122)
        h.call(123, "get_environment", ["includeToolchain": false])
        #expect(h.response(123, timeout: 120) != nil)
        #expect(h.response(120) != nil && h.response(121) != nil)
        #expect(!h.hasResponse(122))
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
    }

    /// Review MEDIUM 13: the wait table had no admission limit.
    @Test func pendingWaitsAreLimited() throws {
        let child = try Child("/bin/sleep", ["60"])
        defer { child.kill() }
        let h = MCPHarness()
        h.initialize()
        for i in 0..<MCPServer.maxPendingWaits {
            h.call(130 + i, "wait_for", ["condition": "process_exit", "pid": Int(child.pid), "timeoutSeconds": 50])
        }
        h.call(140, "wait_for", ["condition": "process_exit", "pid": Int(child.pid), "timeoutSeconds": 50])
        let refused = try #require(h.response(140))
        #expect((refused["error"] as? [String: Any])?["code"] as? Int == -32000)
        // Duplicate ids of pending requests are refused too.
        h.call(130, "wait_for", ["condition": "process_exit", "pid": Int(child.pid), "timeoutSeconds": 50])
        #expect(h.response(130).map { ($0["error"] as? [String: Any])?["code"] as? Int } == -32600)
        for i in 0..<MCPServer.maxPendingWaits { h.cancel(130 + i) }
        h.call(141, "wait_for", ["condition": "process_exit", "pid": Int(child.pid), "timeoutSeconds": 1])
        #expect(structured(h.response(141, timeout: 60))?["state"] as? String == "timed_out", "slots free again after cancelling")
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
    }

    /// Review MEDIUM 11: a persisted report with a long path and ten 160-char frames gave a 9.5 KB line.
    @Test func persistedTrackStatusStaysUnder4KiB() throws {
        let home = tempDir()
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        let m = TrackManager(home: home)
        let started = try m.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60))
        var r = try m.stop(started.trackId)
        let longPath = "/" + String(repeating: "a-rather-long-directory-name/", count: 30) + "tool"
        r.members[0].path = longPath
        r.members[0].name = String(repeating: "n", count: 300)
        r.spikes = (0..<3).map { i in
            TrackReport.Spike(t: Date(), pid: child.pid, name: String(repeating: "s", count: 200), cpuPercent: 900,
                              threads: (0..<5).map { Proc.ThreadSample(name: "thread-\($0)-" + String(repeating: "t", count: 40), cpuPercent: 99, userSeconds: 1, systemSeconds: 1) },
                              threadsOmitted: 20, sampleFile: longPath + ".\(i).txt",
                              sampleTopFrames: (0..<10).map { _ in String(repeating: "f", count: 160) })
        }
        r.events = (0..<8).map { _ in .init(t: Date(), kind: "exec", pid: child.pid, name: String(repeating: "e", count: 200), detail: String(repeating: "d", count: 200)) }
        r.eventsOmitted = 40
        r.notes = [String(repeating: "note ", count: 100)]
        TrackManager.save(r, home: home)

        let h = MCPHarness(home: home)
        h.initialize()
        h.call(150, "track_processes", ["action": "status", "trackId": started.trackId])
        let s = try #require(structured(h.response(150)))
        let line = try #require(h.line(150))
        #expect(line.utf8.count <= MCPServer.maxResponseBytes, "status line is \(line.utf8.count) bytes")
        #expect(s["trackId"] as? String == started.trackId)
        #expect(s["state"] as? String == "stopped")
        #expect((s["aggregate"] as? [String: Any])?["membersSeen"] as? Int == 1)
        let spikes = s["spikes"] as? [[String: Any]] ?? []
        #expect(spikes.count + (s["spikesOmitted"] as? Int ?? 0) == 3, "spike total preserved")
        #expect((s["eventsOmitted"] as? Int ?? 0) >= 40)
        for sp in spikes {
            let shown = (sp["threads"] as? [Any])?.count ?? 0
            #expect(shown + (sp["threadsOmitted"] as? Int ?? 0) >= 25, "trimmed threads are counted: \(sp)")
        }
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
    }

    /// Review LOW 16 and MEDIUM 13: cross-session stop is an explicit error; client names are capped.
    @Test func stopOfAnotherSessionsTrackIsAnErrorAndNamesAreCapped() throws {
        let home = tempDir()
        let child = try Child("/bin/sleep", ["30"])
        defer { child.kill() }
        let other = TrackManager(home: home)
        let started = try other.start(TrackOptions(selector: .pid(child.pid, startToken: nil), durationSeconds: 60))
        let h = MCPHarness(home: home)
        h.initialize(client: String(repeating: "client\u{7}", count: 2000))
        h.call(160, "track_processes", ["action": "stop", "trackId": started.trackId])
        let r = try #require(h.response(160)?["result"] as? [String: Any])
        #expect(r["isError"] as? Bool == true)
        let text = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("another session"), "\(text)")
        #expect(other.status(started.trackId)?.state == "running", "the other session's track keeps running")
        let presence = try #require(ActivityStore(directory: home).connectedAgents().first)
        #expect((presence.client ?? "").count <= 64 && !(presence.client ?? "").contains("\u{7}"))
        other.stopAll(reason: "test")
        h.close()
        _ = h.finished.wait(timeout: .now() + 30)
    }

    @Test func jsonWriterEscapesAndShortensNumbers() {
        var data = Data()
        JSONWriter.write(["a": 34.7, "b": "q\"\\\n\u{01}", "c": true, "d": [1, NSNull()], "e": 2.0] as [String: Any], into: &data)
        let s = String(decoding: data, as: UTF8.self)
        #expect(s == #"{"a":34.7,"b":"q\"\\\n\u0001","c":true,"d":[1,null],"e":2}"#)
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }
}

// MARK: - Agent registration

/// Fake agent CLIs that edit config files the way the real ones do, and log their arguments.
/// Like the real tools: `codex`/`gemini mcp add` overwrite an existing name, `claude mcp add` refuses it;
/// `codex mcp get --json` is how Codex reports what it parsed (kept in `aistats.json` here).
struct FakeAgents {
    let root = tempDir()
    var bin: URL { root.appendingPathComponent("bin") }
    var apps: URL { root.appendingPathComponent("apps") }
    var home: URL { root.appendingPathComponent("home") }
    var log: URL { root.appendingPathComponent("calls.log") }

    init(clis: [String] = ["claude", "codex", "gemini"], apps appNames: [String] = ["Claude.app", "Cursor.app"]) throws {
        let fm = FileManager.default
        for d in [bin, apps, home, root.appendingPathComponent("claude"), root.appendingPathComponent("codex"),
                  root.appendingPathComponent("gemini/.gemini"), root.appendingPathComponent("aistats-home")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        for a in appNames { try fm.createDirectory(at: apps.appendingPathComponent(a), withIntermediateDirectories: true) }
        let scripts: [String: String] = [
            "claude": #"""
            #!/bin/sh
            echo "claude $*" >> "$FAKE_LOG"
            [ -n "$FAKE_FAIL_CLAUDE" ] && { echo "claude: simulated failure" >&2; exit 1; }
            cfg="$CLAUDE_CONFIG_DIR/.claude.json"
            sub="$1 $2"; shift 2
            case "$sub" in
            "mcp add")
              [ -n "$FAKE_FAIL_CLAUDE_ADD" ] && { echo "claude: simulated add failure" >&2; exit 1; }
              env=""; cmd=""; a=""
              while [ $# -gt 0 ]; do case "$1" in
                --scope|-s) shift 2;;
                -e) env="$2"; shift 2;;
                --) shift; cmd="$1"; shift; a="$1"; break;;
                *) shift;;
              esac; done
              if grep -q '"aistats":' "$cfg" 2>/dev/null; then echo "MCP server aistats already exists in user config" >&2; exit 1; fi
              printf '{"numStartups":3,"mcpServers":{"aistats":{"type":"stdio","command":"%s","args":["%s"],"env":{"%s":"%s"}}}}' "$cmd" "$a" "${env%%=*}" "${env#*=}" > "$cfg";;
            "mcp add-json")
              printf '{"numStartups":3,"mcpServers":{"aistats":%s}}' "$4" > "$cfg";;
            "mcp remove")
              grep -q '"aistats":' "$cfg" 2>/dev/null || { echo 'No MCP server named "aistats" in user scope' >&2; exit 1; }
              printf '{"numStartups":3,"mcpServers":{}}' > "$cfg";;
            esac
            """#,
            "codex": #"""
            #!/bin/sh
            echo "codex $*" >> "$FAKE_LOG"
            [ -n "$FAKE_FAIL_CODEX" ] && { echo "Error: simulated failure" >&2; exit 1; }
            cfg="$CODEX_HOME/config.toml"; js="$CODEX_HOME/aistats.json"
            sub="$1 $2"; shift 2
            case "$sub" in
            "mcp get")
              [ -n "$FAKE_FAIL_CODEX_GET" ] && { echo "Error: failed to load bootstrap configuration" >&2; exit 1; }
              [ -n "$FAKE_CODEX_GET_ERR" ] && { printf '%s\n' "$FAKE_CODEX_GET_ERR" >&2; exit 1; }
              if [ -f "$js" ]; then cat "$js"; else echo "Error: No MCP server named 'aistats' found." >&2; exit 1; fi;;
            "mcp add")
              [ -n "$FAKE_FAIL_CODEX_ADD" ] && { echo "Error: simulated add failure" >&2; exit 1; }
              shift; envj="null"
              while [ $# -gt 0 ]; do case "$1" in
                --env) envj="{\"${2%%=*}\":\"${2#*=}\"}"; shift 2;;
                --) shift; break;;
                *) shift;;
              esac; done
              printf '{"name":"aistats","enabled":true,"disabled_reason":null,"transport":{"type":"stdio","command":"%s","args":["%s"],"env":%s,"env_vars":[],"cwd":null},"enabled_tools":null,"disabled_tools":null,"startup_timeout_sec":null,"tool_timeout_sec":null}' "$1" "$2" "$envj" > "$js"
              printf 'model = "x"\n\n[mcp_servers.aistats]\ncommand = "%s"\nargs = ["%s"]\n' "$1" "$2" > "$cfg";;
            "mcp remove")
              [ -f "$js" ] || { echo "No MCP server named 'aistats' found."; exit 0; }
              rm -f "$js"; printf 'model = "x"\n' > "$cfg";;
            esac
            """#,
            "gemini": #"""
            #!/bin/sh
            echo "gemini $*" >> "$FAKE_LOG"
            [ -n "$FAKE_FAIL_GEMINI" ] && { echo "simulated failure" >&2; exit 1; }
            cfg="$GEMINI_CLI_HOME/.gemini/settings.json"
            sub="$1 $2"; shift 2
            case "$sub" in
            "mcp add")
              envj=""
              while [ $# -gt 0 ]; do case "$1" in
                -s) shift 2;;
                -e) envj=",\"env\":{\"${2%%=*}\":\"${2#*=}\"}"; shift 2;;
                *) break;;
              esac; done
              printf '{"mcpServers":{"aistats":{"command":"%s","args":["%s"]%s}}}' "$2" "$3" "$envj" > "$cfg";;
            "mcp remove") printf '{"mcpServers":{}}' > "$cfg" ;;
            esac
            """#,
        ]
        for name in clis {
            let url = bin.appendingPathComponent(name)
            try scripts[name]!.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
        }
    }

    func environment(_ extra: [String: String] = [:], cwd: String? = nil) -> RegistrationEnvironment {
        var vars = ["HOME": home.path, "PATH": "/usr/bin:/bin", "FAKE_LOG": log.path,
                    "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
                    "CODEX_HOME": root.appendingPathComponent("codex").path,
                    "GEMINI_CLI_HOME": root.appendingPathComponent("gemini").path,
                    "AISTATS_HOME": root.appendingPathComponent("aistats-home").path]
        vars.merge(extra) { _, b in b }
        return RegistrationEnvironment(home: home, variables: vars, cliSearchPaths: [bin.path], appSearchPaths: [apps.path], timeout: 20,
                                       currentDirectory: cwd)
    }

    func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var claudeConfig: URL { root.appendingPathComponent("claude/.claude.json") }
    var codexJSON: URL { root.appendingPathComponent("codex/aistats.json") }
    var codexConfig: URL { root.appendingPathComponent("codex/config.toml") }
    var desktopConfig: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }
    var cursorConfig: URL { home.appendingPathComponent(".cursor/mcp.json") }
    var dataDir: URL { root.appendingPathComponent("aistats-home") }

    /// AIStats's backups of one agent's config, newest first.
    func backups(_ t: AgentTarget) -> [URL] {
        BackupStore(directory: dataDir.appendingPathComponent("backups/\(t.rawValue)"), keep: AgentRegistrar.maxBackups).list()
    }

    func writeDesktop(_ text: String) throws {
        try FileManager.default.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: desktopConfig, atomically: true, encoding: .utf8)
    }

    /// A fake AIStats.app (or another app) bundle containing an `aistats` binary.
    func bundle(_ name: String, identifier: String) throws -> String {
        let app = root.appendingPathComponent("bundles/\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": identifier] as NSDictionary
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bin = macOS.appendingPathComponent("aistats")
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)
        return bin.path
    }
}

private func json(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func entry(_ url: URL) throws -> [String: Any]? {
    try (json(url)["mcpServers"] as? [String: Any])?["aistats"] as? [String: Any]
}

@Suite struct RegistrationTests {
    @Test func installStatusReinstallUninstallForEveryAgent() throws {
        let f = try FakeAgents()
        let r = AgentRegistrar(binaryPath: "/Apps/AIStats.app/Contents/MacOS/aistats", environment: f.environment())
        for t in AgentTarget.allCases {
            #expect(r.status(t).state == .notInstalled, "\(t)")
            let first = r.install(t)
            #expect(first.ok && first.action == "registered", "\(t): \(first.message)")
            #expect(r.status(t).state == .installed, "\(t)")
            let again = r.install(t)
            #expect(again.ok && again.action == "already_registered", "\(t)")
            let removed = r.uninstall(t)
            #expect(removed.ok && removed.action == "removed", "\(t): \(removed.message)")
            #expect(r.status(t).state == .notInstalled, "\(t)")
            let noop = r.uninstall(t)
            #expect(noop.ok && noop.action == "not_registered")
        }
        // One add and one remove per CLI agent: the second install didn't duplicate.
        let calls = f.calls()
        for cli in ["claude", "codex", "gemini"] {
            #expect(calls.filter { $0.hasPrefix("\(cli) mcp add") }.count == 1, "\(cli): \(calls)")
            #expect(calls.filter { $0.hasPrefix("\(cli) mcp remove") }.count == 1)
        }
        #expect(calls.contains("claude mcp add --scope user aistats -e AISTATS_MANAGED=1 -- /Apps/AIStats.app/Contents/MacOS/aistats mcp"))
        #expect(calls.contains("codex mcp add aistats --env AISTATS_MANAGED=1 -- /Apps/AIStats.app/Contents/MacOS/aistats mcp"))
        #expect(calls.contains("gemini mcp add -s user -e AISTATS_MANAGED=1 aistats /Apps/AIStats.app/Contents/MacOS/aistats mcp"))
        #expect(calls.contains("codex mcp get aistats --json"), "codex status comes from the codex CLI")
        // The JSON agents got the marker too.
        let desktop = try #require(try { () throws -> [String: Any]? in
            try f.writeDesktop("{}"); _ = r.install(.claudeDesktop); return try entry(f.desktopConfig) }())
        #expect((desktop["env"] as? [String: String]) == ["AISTATS_MANAGED": "1"])
    }

    @Test func movedBinaryNeedsPathUpdateAndReconnectFixesIt() throws {
        let f = try FakeAgents()
        let old = AgentRegistrar(binaryPath: "/old/place/aistats", environment: f.environment())
        let new = AgentRegistrar(binaryPath: "/new/place/aistats", environment: f.environment())
        for t in AgentTarget.allCases {
            #expect(old.install(t).ok)
            #expect(new.status(t).state == .pathUpdateNeeded(registered: "/old/place/aistats"), "\(t)")
            let o = new.install(t)
            #expect(o.ok && o.action == "updated", "\(t): \(o.message)")
            #expect(new.status(t).state == .installed)
            #expect(old.status(t).state == .pathUpdateNeeded(registered: "/new/place/aistats"))
        }
        // Codex and Gemini update with one overwriting add; Claude needs remove + add.
        #expect(!f.calls().contains("codex mcp remove aistats"))
        #expect(f.calls().contains("claude mcp remove aistats --scope user"))
    }

    @Test func ownershipNeedsThisBinaryOurBundleOrTheMarker() throws {
        let f = try FakeAgents()
        let me = "/x/AIStats.app/Contents/MacOS/aistats"
        let r = AgentRegistrar(binaryPath: me, environment: f.environment())
        func e(_ command: String, _ args: [String] = ["mcp"], env: [String: String] = [:], extras: [String] = []) -> RegistrationEntry {
            RegistrationEntry(command: command, args: args, env: env, extras: extras, raw: Data())
        }
        let ourBundle = try f.bundle("AIStats", identifier: "com.oozoofrog.aistats")
        let otherBundle = try f.bundle("Other", identifier: "com.example.other")
        #expect(r.classify(e(me)) == .installed)
        #expect(r.classify(e(me, env: ["AISTATS_MANAGED": "1"])) == .installed)
        #expect(r.classify(e(ourBundle)) == .pathUpdateNeeded(registered: ourBundle))
        #expect(r.classify(e("/third/party/aistats", env: ["AISTATS_MANAGED": "1"])) == .pathUpdateNeeded(registered: "/third/party/aistats"))
        // Same file name is not enough.
        guard case .nameConflict = r.classify(e("/third/party/aistats")) else { Issue.record("basename alone"); return }
        guard case .nameConflict = r.classify(e(otherBundle)) else { Issue.record("other bundle id"); return }
        guard case .nameConflict = r.classify(e("/gone/AIStats.app/Contents/MacOS/aistats")) else { Issue.record("missing bundle"); return }
        // Our command but anything extra is not ours to change.
        guard case .nameConflict = r.classify(e(me, ["mcp", "--x"])) else { Issue.record("args"); return }
        guard case .nameConflict = r.classify(e(me, env: ["TOKEN": "s"])) else { Issue.record("env"); return }
        guard case .nameConflict = r.classify(e(me, extras: ["cwd"])) else { Issue.record("extras"); return }
        guard case .nameConflict = r.classify(e(ourBundle, env: ["AISTATS_MANAGED": "0"])) else { Issue.record("marker value"); return }
    }

    /// Review HIGH 2: `/third/party/aistats mcp` with custom env was treated as ours and replaced.
    @Test func foreignAistatsBinaryIsNotReplacedWithoutConfirmation() throws {
        let f = try FakeAgents()
        let foreign = #"{"mcpServers":{"aistats":{"args":["mcp"],"command":"/third/party/aistats","env":{"TOKEN":"secret"}},"keep":{"command":"x"}},"theme":"dark"}"#
        try f.writeDesktop(foreign)
        try foreign.write(to: f.claudeConfig, atomically: true, encoding: .utf8)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        for t in [AgentTarget.claudeDesktop, .claudeCode] {
            guard case .nameConflict(let what) = r.status(t).state else { Issue.record("\(t) not a conflict"); continue }
            #expect(what.contains("/third/party/aistats"))
            let o = r.install(t)
            #expect(!o.ok && o.message.contains("--replace"), "\(t): \(o.message)")
            #expect(!r.uninstall(t).ok)
        }
        #expect(try String(contentsOf: f.desktopConfig, encoding: .utf8) == foreign)
        #expect(try String(contentsOf: f.claudeConfig, encoding: .utf8) == foreign)
        #expect(!f.calls().contains { $0.contains("mcp add") || $0.contains("mcp remove") })
        #expect(f.backups(.claudeDesktop).isEmpty, "nothing changed, no backup")

        // A replace naming another entry is refused; naming this entry's fingerprint replaces it and keeps a backup.
        let stale = r.install(.claudeDesktop, replacing: "000000000000")
        #expect(!stale.ok && stale.message.contains("not the one confirmed"), "\(stale.message)")
        let shown = try #require(r.status(.claudeDesktop).entryFingerprint)
        #expect(r.install(.claudeDesktop).message.contains("--replace \(shown)"), "the refusal names the fingerprint")
        let replaced = r.install(.claudeDesktop, replacing: shown)
        #expect(replaced.ok && replaced.action == "replaced", "\(replaced.message)")
        #expect(r.status(.claudeDesktop).state == .installed)
        let backup = try #require(replaced.backup)
        #expect(try String(contentsOf: URL(fileURLWithPath: backup), encoding: .utf8) == foreign, "backup is the original exactly")
        #expect((try json(f.desktopConfig)["theme"]) as? String == "dark")
        #expect(((try json(f.desktopConfig)["mcpServers"] as? [String: Any])?["keep"]) != nil)
        // Claude Code through its CLI: replace is remove + add, and the file was backed up first.
        let cc = r.install(.claudeCode, replacing: r.status(.claudeCode).entryFingerprint)
        #expect(cc.ok && cc.action == "replaced", "\(cc.message)")
        #expect(try String(contentsOf: URL(fileURLWithPath: try #require(cc.backup)), encoding: .utf8) == foreign)
    }

    /// Review HIGH 1 (both rounds): backups must never delete or overwrite anything of the user's. They
    /// live only in AIStats's own folder; nothing next to the config is created, pruned or touched.
    @Test func backupsLiveOnlyInAIStatsStorage() throws {
        let f = try FakeAgents()
        let original = #"{"mcpServers":{}}"#
        try f.writeDesktop(original)
        let dir = f.desktopConfig.deletingLastPathComponent()
        let fm = FileManager.default
        // Things next to the config that look like backups (old fixed name, our old naming, future stamps).
        let oldName = dir.appendingPathComponent("claude_desktop_config.json.aistats-backup")
        try fm.createDirectory(at: oldName, withIntermediateDirectories: true)
        try "precious".write(to: oldName.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)
        var lookalikes: [URL] = []
        for stamp in ["19990101T000000Z", "1999T101T000000Z", "29990101T000000Z", "29990101T000001Z", "29990101T000002Z",
                      "29990101T000003Z", "29990101T000004Z", "29990101T000005Z"] {
            let u = dir.appendingPathComponent("claude_desktop_config.json.aistats-backup-" + stamp)
            try "not AIStats's \(stamp)".write(to: u, atomically: true, encoding: .utf8)
            lookalikes.append(u)
        }
        let before = Set(try fm.contentsOfDirectory(atPath: dir.path))
        // Inside our backup folder: a future-dated lookalike and a file that isn't one of our names.
        let store = f.dataDir.appendingPathComponent("backups/claude-desktop")
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let notOurs = store.appendingPathComponent("README.txt")
        try "keep".write(to: notOurs, atomically: true, encoding: .utf8)

        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let installed = r.install(.claudeDesktop)
        #expect(installed.ok, "\(installed.message)")
        let backup = try #require(installed.backup.map { URL(fileURLWithPath: $0) })
        #expect(backup.deletingLastPathComponent().path == store.path, "backup is in AIStats storage: \(backup.path)")
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect((try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int) == 0o600)
        // The folder existed already (made by the test, 0755): AIStats uses it as it is, without chmod.
        #expect((try fm.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int) == 0o755)
        #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == before, "nothing created or removed next to the config")
        for u in lookalikes { #expect(fm.fileExists(atPath: u.path)) }
        #expect(try String(contentsOf: oldName.appendingPathComponent("data.txt"), encoding: .utf8) == "precious")

        // Retention: the newest five of our backups remain; the newest is always kept; other files stay.
        for _ in 0..<6 {
            let u = r.uninstall(.claudeDesktop)
            #expect(u.ok)
            #expect(fm.fileExists(atPath: try #require(u.backup)), "the backup just made is never pruned")
            let i = r.install(.claudeDesktop)
            #expect(i.ok)
            #expect(fm.fileExists(atPath: try #require(i.backup)))
        }
        let kept = (try? fm.contentsOfDirectory(atPath: store.path).sorted()) ?? []
        #expect(f.backups(.claudeDesktop).count == AgentRegistrar.maxBackups, "\(kept)")
        #expect(fm.fileExists(atPath: notOurs.path))
        #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == before)
    }

    /// Review HIGH 3: `[mcp_servers . 'aistats']` hid a foreign server from the local TOML parser.
    @Test func codexStatusComesFromCodexAndFailuresAreNotNotInstalled() throws {
        let f = try FakeAgents()
        try "[mcp_servers . 'aistats']\ncommand = \"/third/aistats\"\nargs = [\"mcp\"]\n".write(to: f.codexConfig, atomically: true, encoding: .utf8)
        // What the real Codex CLI reports for that file.
        let reported = #"{"name":"aistats","enabled":true,"disabled_reason":null,"transport":{"type":"stdio","command":"/third/aistats","args":["mcp"],"env":null,"env_vars":[],"cwd":null},"enabled_tools":null,"disabled_tools":null,"startup_timeout_sec":null,"tool_timeout_sec":null}"#
        try reported.write(to: f.codexJSON, atomically: true, encoding: .utf8)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        guard case .nameConflict(let what) = r.status(.codex).state else { Issue.record("expected a conflict: \(r.status(.codex).state)"); return }
        #expect(what.contains("/third/aistats"))
        #expect(!r.install(.codex).ok)
        #expect(!f.calls().contains { $0.hasPrefix("codex mcp add") })
        #expect(try String(contentsOf: f.codexJSON, encoding: .utf8) == reported)

        // A lookup that fails for another reason is check_failed, and nothing is written.
        try FileManager.default.removeItem(at: f.codexJSON)
        let broken = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment(["FAKE_FAIL_CODEX_GET": "1"]))
        guard case .checkFailed(let why) = broken.status(.codex).state else { Issue.record("expected check_failed"); return }
        #expect(why.contains("failed to load"))
        #expect(!broken.install(.codex).ok)
        #expect(!f.calls().contains { $0.hasPrefix("codex mcp add") })
        // Codex saying "not found" while config.toml still defines the entry is not "not installed".
        guard case .checkFailed(let doubt) = r.status(.codex).state else { Issue.record("expected check_failed"); return }
        #expect(doubt.contains("defines one"))
        // Not found, with nothing in the file, is the one case that means "not installed".
        try "model = \"x\"\n".write(to: f.codexConfig, atomically: true, encoding: .utf8)
        #expect(r.status(.codex).state == .notInstalled)

        // Real Codex output for an entry it parsed (the user's own registration shape) is recognised.
        let mine = RegistrationEntry.fromCodexJSON(try JSONSerialization.jsonObject(with: Data(reported.replacingOccurrences(of: "/third/aistats", with: "/x/aistats").utf8)))
        #expect(r.classify(mine) == .installed)
    }

    /// Review HIGH 3, against the real Codex CLI when it is installed (isolated CODEX_HOME).
    @Test func realCodexReadsUnusualTOMLSpelling() throws {
        let env = RegistrationEnvironment.current()
        guard let codex = env.findCLI("codex") else { return }
        let f = try FakeAgents(clis: [])
        try FileManager.default.createSymbolicLink(at: f.bin.appendingPathComponent("codex"), withDestinationURL: URL(fileURLWithPath: codex))
        try "[mcp_servers . 'aistats']\ncommand = \"/third/aistats\"\nargs = [\"mcp\"]\n".write(to: f.codexConfig, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: f.codexConfig)
        var e = f.environment()
        e.cliSearchPaths = [f.bin.path] + env.cliSearchPaths
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: e)
        let state = r.status(.codex).state
        guard case .nameConflict = state else { Issue.record("real codex: expected name_conflict, got \(state)"); return }
        #expect(!r.install(.codex).ok)
        #expect(try Data(contentsOf: f.codexConfig) == before)
    }

    /// Review HIGH 4a: a foreign entry written after the status check must not be overwritten.
    @Test func entryAppearingAfterTheCheckIsNotOverwritten() throws {
        let f = try FakeAgents()
        try f.writeDesktop("{}")
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let foreign = #"{"mcpServers":{"aistats":{"command":"/other/aistats","args":["mcp"]}}}"#
        r.afterInspect = { t in if t == .claudeDesktop { try? foreign.write(to: f.desktopConfig, atomically: true, encoding: .utf8) } }
        let o = r.install(.claudeDesktop)
        #expect(!o.ok, "\(o.message)")
        #expect(try String(contentsOf: f.desktopConfig, encoding: .utf8) == foreign)

        // Same for a CLI agent: the entry is re-read right before the change.
        r.afterInspect = { t in
            if t == .claudeCode { try? #"{"mcpServers":{"aistats":{"command":"/other/aistats","args":["mcp"]}}}"#.write(to: f.claudeConfig, atomically: true, encoding: .utf8) }
        }
        let c = r.install(.claudeCode)
        #expect(!c.ok && c.message.contains("changed"), "\(c.message)")
        #expect(!f.calls().contains { $0.hasPrefix("claude mcp add") })
    }

    /// Review HIGH 4b: a write landing between the last check and the rename is detected and kept.
    @Test func concurrentWriteDuringCommitWins() throws {
        let f = try FakeAgents()
        try f.writeDesktop(#"{"mcpServers":{}}"#)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let theirs = #"{"mcpServers":{"theirs":{"command":"/t"}}}"#
        let mine = f.desktopConfig.path
        JSONConfigEditor.beforeCommit(mine) { url in try? theirs.write(to: url, atomically: true, encoding: .utf8) }
        defer { JSONConfigEditor.beforeCommit(mine, nil) }
        let o = r.install(.claudeDesktop)
        JSONConfigEditor.beforeCommit(mine, nil)
        #expect(!o.ok && o.message.contains("changed"), "\(o.message)")
        #expect(try String(contentsOf: f.desktopConfig, encoding: .utf8) == theirs, "the other writer's file is kept")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.desktopConfig.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".claude_desktop_config.json.aistats-") && !$0.hasSuffix("-lock") }
        #expect(leftovers.isEmpty, "\(leftovers)")
        #expect(f.backups(.claudeDesktop).isEmpty, "the aborted edit's backup is removed")
        // The next attempt works on the new document.
        #expect(r.install(.claudeDesktop).ok)
        #expect(((try json(f.desktopConfig)["mcpServers"] as? [String: Any])?["theirs"]) != nil)
    }

    /// Review HIGH 4c: remove succeeded, add failed — the old registration must come back.
    @Test func failedAddRestoresThePreviousEntry() throws {
        let f = try FakeAgents()
        let old = AgentRegistrar(binaryPath: "/old/aistats", environment: f.environment())
        #expect(old.install(.claudeCode).ok)
        #expect(old.install(.codex).ok)
        let before = try entry(f.claudeConfig)
        let new = AgentRegistrar(binaryPath: "/new/aistats", environment: f.environment(["FAKE_FAIL_CLAUDE_ADD": "1", "FAKE_FAIL_CODEX_ADD": "1"]))
        let o = new.install(.claudeCode)
        #expect(!o.ok)
        #expect(o.message.contains("restored"), "\(o.message)")
        #expect(NSDictionary(dictionary: try #require(try entry(f.claudeConfig))).isEqual(to: try #require(before)))
        #expect(new.status(.claudeCode).state == .pathUpdateNeeded(registered: "/old/aistats"))
        #expect(f.calls().contains { $0.hasPrefix("claude mcp add-json --scope user aistats") })
        #expect(o.backup != nil)
        // Codex overwrites in one step: a failed add leaves the old entry as it was.
        let c = new.install(.codex)
        #expect(!c.ok && c.message.contains("unchanged"), "\(c.message)")
        #expect(new.status(.codex).state == .pathUpdateNeeded(registered: "/old/aistats"))
    }

    @Test func corruptJSONIsRefusedAndKept() throws {
        let f = try FakeAgents()
        let broken = "{ \"mcpServers\": { oops"
        try FileManager.default.createDirectory(at: f.cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try broken.write(to: f.cursorConfig, atomically: true, encoding: .utf8)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        guard case .checkFailed = r.status(.cursor).state else { Issue.record("expected check failed"); return }
        let o = r.install(.cursor)
        #expect(!o.ok)
        #expect(try String(contentsOf: f.cursorConfig, encoding: .utf8) == broken)
        // mcpServers of the wrong type is refused too.
        try #"{"mcpServers":[1,2]}"#.write(to: f.cursorConfig, atomically: true, encoding: .utf8)
        #expect(!r.install(.cursor).ok)
        #expect(try String(contentsOf: f.cursorConfig, encoding: .utf8) == #"{"mcpServers":[1,2]}"#)
        // Claude Code's file unreadable → check_failed, never "not installed".
        try "{ nope".write(to: f.claudeConfig, atomically: true, encoding: .utf8)
        guard case .checkFailed = r.status(.claudeCode).state else { Issue.record("claude: expected check failed"); return }
        #expect(!r.install(.claudeCode).ok)
        #expect(!f.calls().contains { $0.hasPrefix("claude mcp") })
    }

    @Test func jsonMergeKeepsOtherKeysAndBacksUp() throws {
        let f = try FakeAgents()
        let original = #"{"globalShortcut":"Cmd+K","mcpServers":{"other":{"command":"/bin/other","args":["a"]}}}"#
        try f.writeDesktop(original)
        chmod(f.desktopConfig.path, 0o644)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        #expect(r.install(.claudeDesktop).ok)
        let obj = try json(f.desktopConfig)
        #expect(obj["globalShortcut"] as? String == "Cmd+K")
        let servers = try #require(obj["mcpServers"] as? [String: Any])
        #expect((servers["other"] as? [String: Any])?["command"] as? String == "/bin/other")
        #expect((servers["aistats"] as? [String: Any])?["args"] as? [String] == ["mcp"])
        let backup = try #require(f.backups(.claudeDesktop).first)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600, "backup is owner-only")
        let mode = try FileManager.default.attributesOfItem(atPath: f.desktopConfig.path)[.posixPermissions] as? Int
        #expect(mode == 0o644, "original permissions kept")
        // Updating an owned entry keeps its other fields.
        var withType = try json(f.desktopConfig)
        var s = try #require(withType["mcpServers"] as? [String: Any])
        s["aistats"] = ["command": "/old/aistats", "args": ["mcp"], "type": "stdio", "env": ["AISTATS_MANAGED": "1"]]
        withType["mcpServers"] = s
        try JSONSerialization.data(withJSONObject: withType).write(to: f.desktopConfig)
        let u = r.install(.claudeDesktop)
        #expect(u.ok && u.action == "updated", "\(u.message)")
        #expect(try entry(f.desktopConfig)?["type"] as? String == "stdio")
        #expect(try entry(f.desktopConfig)?["command"] as? String == "/x/aistats")
        #expect(r.uninstall(.claudeDesktop).ok)
        let after = try json(f.desktopConfig)
        #expect(((after["mcpServers"] as? [String: Any])?.keys).map(Array.init) == ["other"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.desktopConfig.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".claude_desktop_config.json.aistats-") && !$0.hasSuffix("-lock") }
        #expect(leftovers.isEmpty, "no temp files left: \(leftovers)")
    }

    @Test func symlinksFollowedOnlyWhenSafe() throws {
        let f = try FakeAgents()
        let real = f.root.appendingPathComponent("dotfiles/mcp.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.cursorConfig, withDestinationURL: real)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        #expect(r.install(.cursor).ok)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.cursorConfig.path)) == real.path, "link kept")
        #expect(try String(contentsOf: real, encoding: .utf8).contains("/x/aistats"))

        try FileManager.default.removeItem(at: f.cursorConfig)
        try FileManager.default.createSymbolicLink(at: f.cursorConfig, withDestinationURL: f.root.appendingPathComponent("missing.json"))
        let o = r.install(.cursor)
        #expect(!o.ok)
        #expect(o.message.contains("symlink") || o.message.contains("could not read"))
    }

    @Test func partialFailureAndMissingAgents() throws {
        let f = try FakeAgents(clis: ["claude", "codex"], apps: ["Claude.app"])
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment(["FAKE_FAIL_CODEX_ADD": "1"]))
        let results = AgentTarget.allCases.map { r.install($0) }
        let byTarget = Dictionary(uniqueKeysWithValues: results.map { ($0.target, $0) })
        #expect(byTarget[.claudeCode]?.ok == true)
        #expect(byTarget[.claudeDesktop]?.ok == true)
        #expect(byTarget[.codex]?.ok == false)
        #expect(byTarget[.codex]?.message.contains("simulated add failure") == true)
        #expect(r.status(.codex).state == .notInstalled)
        #expect(byTarget[.gemini]?.status.state == .agentNotFound)
        #expect(byTarget[.cursor]?.status.state == .agentNotFound)
        #expect(!FileManager.default.fileExists(atPath: f.cursorConfig.path), "nothing written for a missing agent")
        #expect(r.status(.claudeCode).cliPath == f.bin.appendingPathComponent("claude").path, "status says which CLI was used")
    }

    /// Review LOW 18 / re-review L1: inherited PATH first, then the usual install dirs including every
    /// nvm node version (newest first) and asdf.
    @Test func cliSearchPathsPreferInheritedPATH() throws {
        let home = tempDir()
        for v in ["v9.11.2", "v20.10.0", "v20.9.1"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/\(v)/bin"), withIntermediateDirectories: true)
        }
        let dirs = RegistrationEnvironment.searchPaths(home: home, path: "/custom/bin:/opt/homebrew/bin")
        #expect(dirs.first == "/custom/bin")
        #expect(dirs.firstIndex(of: "/opt/homebrew/bin")! < dirs.firstIndex(of: home.appendingPathComponent(".local/bin").path)!)
        let node = { (v: String) in dirs.firstIndex(of: home.appendingPathComponent(".nvm/versions/node/\(v)/bin").path) }
        #expect(node("v20.10.0")! < node("v20.9.1")! && node("v20.9.1")! < node("v9.11.2")!, "every version, newest first")
        // NVM_DIR is honoured, and a CLI that only an older version has is found.
        let custom = home.appendingPathComponent("nvm-elsewhere/versions/node/v18.0.0/bin")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: custom.appendingPathComponent("old-agent"), atomically: true, encoding: .utf8)
        chmod(custom.appendingPathComponent("old-agent").path, 0o755)
        let withNVM = RegistrationEnvironment.searchPaths(home: home, path: "/usr/bin", nvmDir: home.appendingPathComponent("nvm-elsewhere").path)
        let env = RegistrationEnvironment(home: home, variables: [:], cliSearchPaths: withNVM, appSearchPaths: [])
        #expect(env.findCLI("old-agent") == custom.appendingPathComponent("old-agent").path)
        #expect(dirs.contains(home.appendingPathComponent(".asdf/shims").path))
        #expect(dirs.contains(home.appendingPathComponent(".volta/bin").path))
        #expect(Set(dirs).count == dirs.count, "no duplicates")
    }
}
