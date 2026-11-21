import Foundation
import StatsCore

let usage = """
aistats — lets AI agents (and you) read this Mac's stats

USAGE
  aistats find (--pid N [--start-token T] | --name NAME | --path PATH | --port N [--probe-free])
              [--match exact|glob] [--args-contain TEXT] [--limit N] [--json]
  aistats diagnose [--purpose slowdown|heavy_work] [--json]
  aistats env [--no-toolchain] [--json]
  aistats wait CONDITION [--pid N] [--start-token T] [--name NAME | --path PATH] [--match exact|glob]
              [--args-contain TEXT] [--port N] [--new-instances-only] [--volume-path PATH] [--above-gib N]
              [--below P] [--timeout S] [--json]
              cpu_idle | process_exit | process_started | memory_pressure_normal | disk_free_above | port_listening
  aistats preflight [--agent claude-code|codex] [--json]
  aistats stats [--json]                          CPU, memory, disk, network, battery
  aistats top [--sort cpu|memory] [--limit N] [--json]
  aistats history [--minutes N] [--json]          trend recorded by the AIStats app (1–60 min)
  aistats tree [--sort cpu|mem|disk]               process tree and subtree totals
  aistats sims [--json]                           CPU and memory per booted simulator device
  aistats storage [--json]                        volume free space, developer folder sizes, drain rate
  aistats agents [--json] [--calls N] [--no-attribute]  connected agents and their recent calls
  aistats mcp [--name NAME]                       run the MCP server on stdio
  aistats status [AGENT|all] [--json]             is the MCP server registered with each agent
  aistats install AGENT|all [--replace ENTRY]     register this binary's MCP server with an agent
                                                  (--replace ENTRY overwrites another server named aistats, only
                                                  if it is still the entry with that fingerprint; see status;
                                                  'aistats install --help' says what is changed)
  aistats uninstall AGENT|all                     remove the registration
  aistats track (--pid N [--start-token T] | --name NAME | --path PATH) [--match exact|glob]
                [--args-contain TEXT] [--children] [--duration S] [--interval S] [--spike-cpu P] [--sample-on-spike]
                [--jsonl FILE]                    track processes in the foreground, print the summary
  aistats setup                                   print commands that register the MCP server by hand

AGENT is one of: claude-code, codex, gemini, claude-desktop, cursor.

Data (including backups of agent configs taken before a change) lives in $AISTATS_HOME
or ~/Library/Application Support/AIStats.
"""

struct Arguments {
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: ArraySlice<String>, valueOptions: Set<String>) throws {
        var it = raw.makeIterator()
        while let arg = it.next() {
            guard arg.hasPrefix("--") else { throw CLIError("unexpected argument '\(arg)'") }
            let key = String(arg.dropFirst(2))
            if let eq = key.firstIndex(of: "=") {
                options[String(key[..<eq])] = String(key[key.index(after: eq)...])
            } else if valueOptions.contains(key) {
                guard let value = it.next() else { throw CLIError("--\(key) needs a value") }
                options[key] = value
            } else {
                flags.insert(key)
            }
        }
    }

    func int(_ key: String, default value: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let raw = options[key] else { return value }
        guard let n = Int(raw), range.contains(n) else {
            throw CLIError("--\(key) must be a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return n
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}


let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
}()

func printJSON<T: Encodable>(_ value: T) throws {
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func executablePath() -> String {
    let arg0 = CommandLine.arguments[0]
    if arg0.contains("/") {
        return URL(fileURLWithPath: arg0).standardizedFileURL.resolvingSymlinksInPath().path
    }
    return Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? arg0
}

func run() throws {
    let all = CommandLine.arguments
    guard all.count > 1 else { print(usage); return }
    let command = all[1]
    if ["find", "diagnose", "env", "wait"].contains(command) {
        try diagnosticCommand(command, raw: Array(all.dropFirst(2)))
        return
    }
    if command == "preflight" {
        try preflight(Array(all.dropFirst(2)))
        return
    }
    if ["install", "uninstall", "status"].contains(command) {
        try registration(command, Array(all.dropFirst(2)))
        return
    }
    let args = try Arguments(all.dropFirst(2), valueOptions: ["sort", "calls", "limit", "minutes", "name", "pid", "start-token", "path",
                                                              "match", "duration", "interval", "spike-cpu", "jsonl", "args-contain"])

    switch command {
    case "stats":
        let sampler = SystemSampler()
        var snapshot = sampler.measure(interval: 0.5, includeProcesses: true)
        snapshot.topProcesses = sampler.topProcesses(sortedBy: .cpu, limit: 5, from: snapshot.topProcesses ?? [])
        if args.flags.contains("json") { try printJSON(snapshot) } else { print(snapshot.summary) }

    case "top":
        guard let sort = ProcessSort(rawValue: args.options["sort"] ?? "cpu") else { throw CLIError("--sort must be cpu or memory") }
        let limit = try args.int("limit", default: 10, in: 1...200)
        let sampler = SystemSampler()
        let snapshot = sampler.measure(interval: 1.0, includeProcesses: true)
        let top = sampler.topProcesses(sortedBy: sort, limit: limit, from: snapshot.topProcesses ?? [])
        if args.flags.contains("json") { try printJSON(top) } else { print(ProcessTable.text(top)) }

    case "history":
        let minutes = try args.int("minutes", default: 10, in: 1...60)
        let store = HistoryStore()
        let summary = HistorySummary.make(from: store.points(since: Date().addingTimeInterval(-Double(minutes) * 60)),
                                          maxPoints: args.flags.contains("json") ? 10 : 60)
        if args.flags.contains("json") {
            try printJSON(HistoryResult(minutes: minutes, recording: store.isRecording(), summary: summary))
        } else if let summary {
            print(summary.text)
            if !store.isRecording() { print("The AIStats app is not recording now.") }
        } else {
            print("No history for the last \(minutes) minutes. Start the AIStats app to record it: open -b \(AIStatsPaths.appBundleIdentifier)")
        }

    case "tree":
        guard args.flags.isEmpty, Set(args.options.keys).isSubset(of: ["sort"]),
              let metric = OriginMetric.treeSort(args.options["sort"] ?? "cpu") else {
            throw CLIError("usage: aistats tree [--sort cpu|mem|disk]")
        }
        print(ProcessTree.measure(store: ActivityStore()).text(sort: metric))

    case "sims":
        guard args.options.isEmpty, args.flags.isSubset(of: ["json"]) else { throw CLIError("usage: aistats sims [--json]") }
        let report = SimulatorUsage.measure(store: ActivityStore())
        if args.flags.contains("json") { try printJSON(report) } else { print(report.text()) }

    case "storage":
        guard args.options.isEmpty, args.flags.isSubset(of: ["json"]) else { throw CLIError("usage: aistats storage [--json]") }
        let report = DeveloperStorage.collect()
        if args.flags.contains("json") { try printJSON(report) } else { print(report.text()) }

    case "agents":
        let activity = ActivityStore()
        let count = try args.int("calls", default: 5, in: 0...20)
        var report = AgentSessions.collect(store: activity, calls: count, attribute: !args.flags.contains("no-attribute"))
        if args.flags.contains("json") {
            let compact = JSONEncoder()
            compact.dateEncodingStrategy = .iso8601
            compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try report.fit { try compact.encode($0).count <= MCPServer.maxResponseBytes }
            try printJSON(report)
            return
        }
        let agents = report.sessions
        print(agents.isEmpty ? "No agents connected." : "Connected:")
        for a in agents { print("  \(a.name)\tpid \(a.serverPid)\t\(a.client ?? "")") }
        let calls = activity.recentCalls(limit: count)
        if !calls.isEmpty {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            print("Recent calls:")
            for c in calls { print("  \(f.string(from: c.date))  \(c.agent)  \(c.tool)\(c.detail.map { " (\($0))" } ?? "")") }
        }

        for row in report.busy ?? [] {
            print("  \(row.name) pid \(row.pid): " + (row.agentPid.map { "agent pid \($0)" } ?? "unattributed"))
        }

    case "mcp":
        let server = MCPServer(history: HistoryStore(), activity: ActivityStore(), tracks: TrackManager(),
                               name: args.options["name"] ?? ProcessInfo.processInfo.environment["AISTATS_AGENT_NAME"])
        // A client that kills the server (instead of closing stdin) still gets tracks saved and the
        // presence record removed.
        let signalQueue = DispatchQueue(label: "aistats.mcp.signals")
        let sources = [SIGTERM, SIGINT, SIGHUP].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            s.setEventHandler { server.shutdown(); exit(0) }
            s.resume()
            return s
        }
        signal(SIGPIPE, SIG_IGN)
        server.run()
        sources.forEach { $0.cancel() }

    case "track":
        try track(args)

    case "setup":
        let path = executablePath()
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let handler = ["type": "command", "if": "Bash(xcodebuild *)", "command": quoted + " preflight --agent claude-code"]
        let hooks = ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [handler]] as [String: Any]]]]
        let snippet = try JSONSerialization.data(withJSONObject: hooks, options: [.sortedKeys, .withoutEscapingSlashes])
        print("""
        Claude Code:
          claude mcp add --scope user aistats -e AISTATS_MANAGED=1 -- "\(path)" mcp

        Codex:
          codex mcp add aistats --env AISTATS_MANAGED=1 -- "\(path)" mcp

        Gemini CLI:
          gemini mcp add -s user -e AISTATS_MANAGED=1 aistats "\(path)" mcp

        Other MCP clients (JSON config):
          { "mcpServers": { "aistats": { "command": "\(path)", "args": ["mcp"], "env": { "AISTATS_MANAGED": "1" } } } }

        Claude Code preflight hook:
          \(String(decoding: snippet, as: UTF8.self))

        AISTATS_MANAGED=1 marks the entry as AIStats's own, so 'aistats install' can update it later.
        """)

    case "help", "--help", "-h":
        print(usage)

    case "version", "--version":
        print(AIStatsVersion.current)

    default:
        throw CLIError("unknown command '\(command)'. Run 'aistats help'.")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("aistats: \(error)\n".utf8))
    let hook = CommandLine.arguments.dropFirst(2).contains { $0 == "--agent" || $0.hasPrefix("--agent=") }
    exit(CommandLine.arguments.dropFirst().first == "preflight" && hook ? 0 : 1)
}

// MARK: - Registration

func registration(_ command: String, _ rest: [String]) throws {
    var json = false
    var replacing: String?
    var names: [String] = []
    if rest.contains(where: { $0 == "--help" || $0 == "-h" }) { print(registrationHelp); return }
    var it = rest.makeIterator()
    while let a = it.next() {
        if a == "--json" { json = true }
        else if command == "install", a == "--replace" || a.hasPrefix("--replace=") {
            let value = a == "--replace" ? it.next() : String(a.dropFirst("--replace=".count))
            guard let value, !value.isEmpty, !value.hasPrefix("-") else {
                throw CLIError("--replace needs the fingerprint of the entry to overwrite (shown by 'aistats status' as entry …)")
            }
            replacing = value
        }
        else if a.hasPrefix("-") { throw CLIError("unknown option '\(a)'") }
        else { names.append(a) }
    }
    guard names.count <= 1 else { throw CLIError("give one agent or 'all'") }
    let all = AgentTarget.allCases.map(\.rawValue).joined(separator: ", ")
    let targets: [AgentTarget]
    if let name = names.first, name != "all" {
        guard let t = AgentTarget(rawValue: name) else { throw CLIError("unknown agent '\(name)'; use one of: \(all), or all") }
        targets = [t]
    } else if names.isEmpty && command != "status" {
        throw CLIError("\(command) needs an agent (\(all)) or 'all'")
    } else {
        targets = AgentTarget.allCases
    }
    if replacing != nil, targets.count != 1 { throw CLIError("--replace applies to one agent, not 'all'") }
    let registrar = AgentRegistrar(binaryPath: executablePath())

    if command == "status" {
        let rows = targets.map { registrar.status($0) }
        if json {
            try printJSON(rows.map { StatusRow(agent: $0.target.rawValue, state: $0.state.code, detail: $0.state.detail,
                                               config: $0.location, cli: $0.cliPath, entry: $0.entryFingerprint) })
        } else {
            for r in rows {
                let detail = r.state.detail.map { " (\($0))" } ?? ""
                var entry = ""
                if case .nameConflict = r.state, let fp = r.entryFingerprint { entry = " entry \(fp)" }
                let cli = r.cliPath.map { " via \($0)" } ?? ""
                print("\(r.target.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(r.state.code)\(detail)\(entry)\(cli)")
            }
            print("binary: \(registrar.binaryPath)")
        }
        return
    }

    var failed = false
    var results: [StatusRow] = []
    for t in targets {
        let o = command == "install" ? registrar.install(t, replacing: replacing) : registrar.uninstall(t)
        // `all` skips agents that aren't installed on this Mac instead of failing on them.
        if targets.count > 1, o.status.state == .agentNotFound, !o.ok {
            results.append(StatusRow(agent: t.rawValue, state: "skipped", detail: "agent not found", config: o.status.location, cli: nil))
            if !json { print("\(t.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) skipped (not found on this Mac)") }
            continue
        }
        if !o.ok { failed = true }
        results.append(StatusRow(agent: t.rawValue, state: o.ok ? o.action : "failed", detail: o.ok ? nil : o.message,
                                 config: o.status.location, cli: o.status.cliPath, backup: o.backup,
                                 entry: o.ok ? nil : o.status.entryFingerprint))
        if !json { print("\(t.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(o.ok ? o.action : "failed"): \(o.message)") }
    }
    if json { try printJSON(results) }
    if failed { exit(1) }
}

/// Computed: top-level code above runs before a stored global declared here would be initialized.
var registrationHelp: String {
    """
aistats status|install|uninstall AGENT|all — register this binary's MCP server with an agent

  aistats status [AGENT|all] [--json]
  aistats install AGENT|all [--replace ENTRY] [--json]
  aistats uninstall AGENT|all [--json]

AGENT is one of: claude-code, codex, gemini, claude-desktop, cursor.

What AIStats changes: only the "aistats" entry of the agent's config. Claude Desktop and Cursor JSON is
edited as text, so every byte outside that entry stays as it was; Claude Code, Codex and Gemini CLI are
changed through their own CLI (claude/codex/gemini mcp add|remove).
Before a change, a byte-exact copy of the config is saved in $AISTATS_HOME/backups/<agent>/ (default
~/Library/Application Support/AIStats); the newest 5 that AIStats made are kept.

An entry is AIStats's own only if it runs this binary (or an AIStats.app bundle's, or carries
AISTATS_MANAGED=1) with args ["mcp"] and nothing else. Any other "aistats" entry is left alone unless
you name it: 'aistats status' shows "entry <fingerprint>" (SHA-256 of the entry's exact text), and
--replace <fingerprint> overwrites it only while it is still exactly that entry. Configs AIStats can't
judge unambiguously (duplicate keys, comments in a format without them, a file the agent can't parse)
are reported as check_failed and not changed.

Relative CLAUDE_CONFIG_DIR, CODEX_HOME, GEMINI_CLI_HOME and AISTATS_HOME are resolved against the
current directory, and the agent CLIs get that same absolute path.

Not controlled by AIStats (the agents' own CLIs do this to their own files when AIStats runs them):
  - Claude Code adds its own keys to .claude.json and keeps backups/.claude.json.backup.* next to it.
  - Gemini CLI updates ~/.gemini/projects.json and creates ~/.gemini/history and ~/.gemini/tmp.
  - Codex creates $CODEX_HOME/tmp/arg0-* (even for a read like 'codex mcp get').
Also not handled: another program rewriting the same config in the few milliseconds between AIStats's
last check and its write, and wrappers that change the config right before the agent CLI runs.
"""
}

struct StatusRow: Encodable {
    var agent: String
    var state: String
    var detail: String?
    var config: String?
    var cli: String?
    var backup: String?
    /// Fingerprint of the existing aistats entry (what --replace must name).
    var entry: String?
}

// MARK: - Track

func track(_ args: Arguments) throws {
    var pid: Int?
    if let raw = args.options["pid"] {
        guard let p = Int(raw) else { throw CLIError("--pid must be a number") }
        pid = p
    }
    let selector = try ProcessSelector.parse(pid: pid, startToken: args.options["start-token"], name: args.options["name"],
                                             path: args.options["path"], match: args.options["match"],
                                             argsContain: args.options["args-contain"])
    func double(_ key: String, _ value: Double) throws -> Double {
        guard let raw = args.options[key] else { return value }
        guard let d = Double(raw) else { throw CLIError("--\(key) must be a number") }
        return d
    }
    let options = try TrackOptions(
        selector: selector, includeChildren: args.flags.contains("children"),
        durationSeconds: try args.int("duration", default: 300, in: TrackOptions.durationRange),
        intervalSeconds: try double("interval", 2), spikeCpuPercent: try double("spike-cpu", 150),
        sampleOnSpike: args.flags.contains("sample-on-spike"))
    let unknown = args.flags.subtracting(["children", "sample-on-spike"])
    if let f = unknown.first { throw CLIError("unknown option --\(f)") }

    var jsonl: FileHandle?
    if let path = args.options["jsonl"] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CLIError("can't create \(url.path)")
            }
        }
        jsonl = try FileHandle(forWritingTo: url)
        jsonl?.seekToEndOfFile()
    }
    let rowEncoder = JSONEncoder()
    rowEncoder.dateEncodingStrategy = .iso8601
    rowEncoder.outputFormatting = [.sortedKeys]

    let manager = TrackManager()
    let done = DispatchSemaphore(value: 0)
    var final: TrackReport?
    let report = try manager.start(options, onTick: { row in
        if let jsonl, var data = try? rowEncoder.encode(row) {
            data.append(UInt8(ascii: "\n"))
            jsonl.write(data)
        }
    }, onFinish: { r in
        final = r
        done.signal()
    })
    FileHandle.standardError.write(Data("aistats: tracking as \(report.trackId) for up to \(options.durationSeconds) s (Ctrl-C stops)\n".utf8))

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalQueue = DispatchQueue(label: "aistats.signals")
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        s.setEventHandler { _ = try? manager.stop(report.trackId) }
        s.resume()
        return s
    }
    if report.state != "running" { final = manager.status(report.trackId) } else { done.wait() }
    // Reap `sample` captures (they are cancelled with the track) before exiting, then print the summary
    // as saved after they finished.
    manager.stopAll(reason: "stopped_by_caller", captureWait: 5)
    if let saved = manager.status(report.trackId) { final = saved }
    sources.forEach { $0.cancel() }
    try? jsonl?.close()
    if let final { try printJSON(final) }
}
