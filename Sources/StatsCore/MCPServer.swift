import Foundation

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0, no batches).
///
/// The main thread only reads stdin. Tool calls run one at a time on `work`; `wait_for` runs on its own
/// timer so `ping` and `notifications/cancelled` are answered while it waits. Every request can be
/// cancelled: a cancelled request gets no response. Every write to stdout goes through the serial `out`
/// queue, so messages never interleave. Memory stays bounded: requests are admitted only up to fixed
/// limits, input lines are capped, and the reader stops reading while too much output is waiting to be
/// written (a client that doesn't read stdout gets backpressure, not an ever-growing queue).
public final class MCPServer: @unchecked Sendable {
    static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    /// Every tool response (the whole JSON-RPC line) stays within this many bytes.
    public static let maxResponseBytes = 4096
    /// Requests waiting for or running on the work queue, and pending `wait_for` calls, per session.
    static let maxQueuedCalls = 32
    static let maxPendingWaits = 8
    /// Longest accepted request id (string ids), in UTF-8 bytes.
    static let maxIDBytes = 256
    /// Longest accepted input line; longer messages are rejected unparsed.
    static let maxLineBytes = 1 << 20
    /// Output waiting to be written beyond which the reader pauses.
    static let maxPendingOutputBytes = 256 * 1024
    /// Returned by the stdin reader for a line over `maxLineBytes`.
    static let oversizedLine = "\u{0}aistats-oversized-line"

    private let history: HistoryStore
    private let activity: ActivityStore
    private let tracks: TrackManager
    private let sampler = SystemSampler()
    private let directory = ProcessDirectory()
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let fixedName: String?
    private var agentName: String
    private var clientName: String?
    private let connectedAt = Date()

    private let work = DispatchQueue(label: "aistats.mcp.work", qos: .userInitiated)
    private let out = DispatchQueue(label: "aistats.mcp.out")

    /// A request that has not been answered yet; `cancelled` suppresses its response.
    private final class Pending {
        let isWait: Bool
        var cancelled = false
        var waiter: Waiter?
        /// Cancels a subprocess the call runs (get_environment's toolchain probe).
        var token: CancelToken?
        init(isWait: Bool) { self.isWait = isWait }
    }
    private let pendingLock = NSLock()
    private var pending: [String: Pending] = [:]
    private var queuedCalls = 0
    private let shutdownLock = NSLock()
    private var didShutdown = false

    private let write: (Data) -> Void
    private let outputLock = NSCondition()
    private var pendingOutputBytes = 0

    /// `write` receives one complete message (with its trailing newline) at a time, in order.
    public init(history: HistoryStore, activity: ActivityStore, tracks: TrackManager, name: String?,
                write: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) }) {
        self.history = history
        self.activity = activity
        self.tracks = tracks
        self.fixedName = name.map { Self.cleanName($0) }
        self.agentName = self.fixedName ?? "agent"
        self.write = write
    }

    /// Where this server's tracks save their summaries.
    public var tracksHome: URL { tracks.home }

    /// Serves until `readLine` returns nil (stdin closed).
    public func run(readLine: (() -> String?)? = nil) {
        let reader = StdinLineReader(maxLine: Self.maxLineBytes)
        let next = readLine ?? { reader.next() }
        while true {
            waitForOutputRoom()
            guard let line = next() else { break }
            if line == Self.oversizedLine {
                send(errorResponse(id: NSNull(), code: -32600, message: "Invalid Request: message longer than \(Self.maxLineBytes) bytes"))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                send(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
                continue
            }
            if object is [Any] {
                send(errorResponse(id: NSNull(), code: -32600, message: "Invalid Request: JSON-RPC batches are not supported; send one message per line"))
            } else if let request = object as? [String: Any] {
                dispatch(request)
            } else {
                send(errorResponse(id: NSNull(), code: -32600, message: "Invalid Request: a message must be a JSON object"))
            }
        }
        shutdown()
    }

    /// Ends the session: drops pending waits without answering, lets queued calls finish, saves and
    /// stops tracks (reaping their captures), removes the presence record. Safe to call more than once
    /// and from a signal handler's queue.
    public func shutdown() {
        shutdownLock.lock(); defer { shutdownLock.unlock() }
        guard !didShutdown else { return }
        didShutdown = true
        pendingLock.lock()
        // Waits are dropped unanswered; calls already queued still run and answer.
        let waiters = pending.values.compactMap(\.waiter)
        let tokens = pending.values.compactMap(\.token)
        // Only waits that are actually waiting; a wait rejected for bad arguments is answered like any queued call.
        for (key, entry) in pending where entry.waiter != nil {
            entry.cancelled = true
            pending[key] = nil
        }
        pendingLock.unlock()
        waiters.forEach { $0.cancel() }
        // Queued calls still answer, but a slow toolchain probe doesn't hold up the exit.
        tokens.forEach { $0.cancel() }
        work.sync {}
        tracks.stopAll(reason: "session_ended")
        activity.removePresence(name: agentName, pid: pid)
        out.sync {}
    }

    // MARK: Dispatch

    /// JSON-RPC ids: a string (at most `maxIDBytes`) or an integer. MCP forbids null; booleans and
    /// fractions are not integers. Every id check (requests, responses, cancellations) uses this.
    static func validID(_ id: Any) -> Bool {
        if let n = id as? NSNumber {
            return CFGetTypeID(n) != CFBooleanGetTypeID() && !CFNumberIsFloatType(n)
        }
        if let s = id as? String { return s.utf8.count <= maxIDBytes }
        return false
    }

    /// Type-exact key for a valid id: the string "1" and the integer 1 are different requests.
    static func requestKey(_ id: Any?) -> String? {
        guard let id, validID(id) else { return nil }
        if let n = id as? NSNumber { return "n:\(n.stringValue)" }
        return "s:\(id as! String)"
    }

    private func dispatch(_ request: [String: Any]) {
        let rawID = request["id"]
        let echoID: Any = rawID.flatMap { Self.validID($0) ? $0 : nil } ?? NSNull()
        func invalid(_ why: String) { send(errorResponse(id: echoID, code: -32600, message: "Invalid Request: \(why)")) }

        guard request["jsonrpc"] as? String == "2.0" else { return invalid("jsonrpc must be \"2.0\"") }
        let hasResult = request["result"] != nil, hasError = request["error"] != nil
        guard let methodValue = request["method"] else {
            // A response (to a request we never sent): exactly one of result/error and a valid id; ignored.
            guard hasResult || hasError else { return invalid("method is required") }
            guard hasResult != hasError else { return invalid("a response has either result or error, not both") }
            guard let id = rawID, Self.validID(id) || (hasError && id is NSNull) else {
                return invalid("id must be a string (at most \(Self.maxIDBytes) bytes) or an integer")
            }
            return
        }
        guard !hasResult && !hasError else { return invalid("a request or notification can't carry result or error") }
        guard let method = methodValue as? String else { return invalid("method must be a string") }
        if let params = request["params"], !(params is [String: Any]) {
            return invalid("params must be an object")
        }
        let params = request["params"] as? [String: Any] ?? [:]

        guard let id = rawID else {
            // Notification: never answered. A cancellation names a request by a valid id of the same type.
            if method == "notifications/cancelled", let key = Self.requestKey(params["requestId"]) { cancel(key) }
            return
        }
        guard let key = Self.requestKey(id) else {
            return invalid("id must be a string (at most \(Self.maxIDBytes) bytes) or an integer")
        }

        if method == "ping" {
            send(result(id: id, [:]))
            return
        }
        // Every request counts against the limits before its arguments are looked at.
        let isWait = method == "tools/call" && params["name"] as? String == "wait_for"
        let entry = Pending(isWait: isWait)
        pendingLock.lock()
        if pending[key] != nil {
            pendingLock.unlock()
            send(errorResponse(id: id, code: -32600, message: "Invalid Request: id \(id) is already in use by a pending request"))
            return
        }
        let waits = pending.values.filter(\.isWait).count
        if isWait ? waits >= Self.maxPendingWaits : queuedCalls >= Self.maxQueuedCalls {
            pendingLock.unlock()
            send(errorResponse(id: id, code: -32000, message: isWait
                ? "too many pending wait_for calls (\(Self.maxPendingWaits)); cancel one or wait for it to finish"
                : "too many requests in progress (\(Self.maxQueuedCalls)); retry later"))
            return
        }
        pending[key] = entry
        if !isWait { queuedCalls += 1 }
        pendingLock.unlock()

        if isWait {
            startWait(id: id, key: key, entry: entry, params: params)
            return
        }
        work.async { [self] in
            let response: [String: Any]? = isCancelled(entry) ? nil : handle(method: method, id: id, params: params, entry: entry)
            pendingLock.lock()
            pending[key] = nil
            queuedCalls -= 1
            let drop = entry.cancelled
            pendingLock.unlock()
            if let response, !drop { send(response, toolCall: method == "tools/call") }
        }
    }

    private func isCancelled(_ entry: Pending) -> Bool {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return entry.cancelled
    }

    /// `notifications/cancelled`: the request's response is suppressed; a pending wait stops at once.
    private func cancel(_ key: String) {
        pendingLock.lock()
        let entry = pending[key]
        entry?.cancelled = true
        if entry?.isWait == true { pending[key] = nil }
        let waiter = entry?.waiter, token = entry?.token
        pendingLock.unlock()
        waiter?.cancel()
        token?.cancel()
    }

    private func handle(method: String, id: Any, params: [String: Any], entry: Pending) -> [String: Any] {
        switch method {
        case "initialize":
            return result(id: id, initialize(params))
        case "tools/list":
            return result(id: id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return errorResponse(id: id, code: -32602, message: "Invalid params: name (string) is required")
            }
            guard Self.toolNames.contains(name) else {
                return errorResponse(id: id, code: -32602, message: "Unknown tool: \(String(name.prefix(64)))")
            }
            if let a = params["arguments"], !(a is [String: Any]) {
                return errorResponse(id: id, code: -32602, message: "Invalid params: arguments must be an object")
            }
            return callTool(name: name, args: params["arguments"] as? [String: Any] ?? [:], id: id, entry: entry)
        case "resources/list":
            return result(id: id, ["resources": []])
        case "prompts/list":
            return result(id: id, ["prompts": []])
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(String(method.prefix(64)))")
        }
    }

    /// Client-supplied names end up in files and the app's UI: printable, at most 64 characters.
    static func cleanName(_ s: String) -> String {
        let printable = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        var out = String(printable.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        while out.utf8.count > 128 { out.removeLast() }
        return out
    }

    private func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String ?? ""
        let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[2]
        if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
            let cleaned = Self.cleanName(name)
            clientName = cleaned.isEmpty ? nil : cleaned
        }
        agentName = activity.uniqueAgentName(fixedName ?? clientName ?? "agent", pid: pid)
        touchPresence()
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "aistats", "version": AIStatsVersion.current],
            "instructions": Self.instructions,
        ]
    }


    static let instructions = """
    AIStats inspects this Mac in one call instead of ps/top/lsof/sample/sleep loops. Which tool first:
    - Slow Mac, or about to build/test/run heavy work: diagnose_system.
    - What uses CPU or memory now: get_top_processes (full machine numbers: get_system_stats).
    - Find a process by name, executable path or pid (and get its startToken): find_processes.
    - Watch processes over time (CPU/memory min/avg/max, restarts, child spawns, CPU spikes): track_processes start, later status.
    - Instead of sleeping or polling: wait_for (cpu_idle, process_exit, memory_pressure_normal; up to 55 s per call).
    - OS, chip, Xcode/Swift versions: get_environment. Last hour's trend: get_stats_history (needs the AIStats app).
    Only the current user's processes are readable; others need root.
    """

    private func touchPresence() {
        activity.updatePresence(.init(name: agentName, pid: pid, client: clientName,
                                      connectedAt: connectedAt, lastSeen: Date(),
                                      startToken: Proc.usage(pid).map { String($0.start) }))
    }

    // MARK: Tools

    private static let selectorProperties: [String: Any] = [
        "pid": ["type": "integer", "minimum": 1, "description": "Process id."],
        "startToken": ["type": "string", "description": "From find_processes; with pid, guards against pid reuse."],
        "name": ["type": "string", "minLength": 1, "maxLength": 64, "description": "Executable file name, case-insensitive."],
        "path": ["type": "string", "description": "Absolute executable path."],
        "match": ["type": "string", "enum": ["exact", "glob"], "default": "exact", "description": "How name/path are compared."],
        "argsContain": ["type": "string", "minLength": 1, "maxLength": 128,
                        "description": "With name or path: only processes with an argument (after argv[0]) containing this text, case-sensitive, e.g. --daemon. Processes whose arguments can't be read don't match (counted in argsUnreadable)."],
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "get_system_stats",
            "title": "System stats",
            "description": "Current CPU, memory (with pressure and swap), disk free space, network throughput, battery and thermal state of this Mac, measured over about half a second, plus the top 5 processes by CPU. For a yes/no 'is something wrong' answer use diagnose_system instead.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_top_processes",
            "title": "Top processes",
            "description": "Processes owned by the current user, ranked by CPU (percent of one core, measured over about a second) or by memory footprint. Use instead of ps/top. To look up one process by name or path use find_processes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "sort": ["type": "string", "enum": ["cpu", "memory"], "default": "cpu"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10],
                ],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_stats_history",
            "title": "Stats history",
            "description": "How CPU, memory, network and free disk space changed over the last N minutes (up to 60): min/average/max plus up to maxPoints evenly spaced points (0 = summary only). Recorded every 2 seconds by the AIStats menu bar app; if the app is not running, the result says so.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "minimum": 1, "maximum": 60, "default": 10],
                    "maxPoints": ["type": "integer", "minimum": 0, "maximum": 60, "default": 20],
                ],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "diagnose_system",
            "title": "Diagnose system",
            "description": "Call first when the Mac feels slow (purpose slowdown) or before builds/tests/large jobs (purpose heavy_work). Measures ~1 s and returns status issue_detected|no_clear_issue|insufficient_data, up to 4 evidence items, most severe first (CPU ≥85%, load average ≥2× logical cores, memory pressure, thermal throttling, <10 GiB free, battery <20%), loadAverage [1,5,15 min], the 3 busiest processes, and for heavy_work a readiness of ready|caution|unknown.",
            "inputSchema": [
                "type": "object",
                "properties": ["purpose": ["type": "string", "enum": ["slowdown", "heavy_work"], "default": "slowdown"]],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "find_processes",
            "title": "Find processes",
            "description": "Look up processes by exactly one of pid, name (executable file name) or path (absolute executable path); name/path match exact (default, name case-insensitive) or glob. Returns pid, startToken (identifies the instance across pid reuse), name, ppid and memory footprint; path only when you matched by path. Use instead of ps | grep. Fields that can't be read are listed in unreadable, never reported as 0.",
            "inputSchema": [
                "type": "object",
                "properties": selectorProperties.merging(["limit": ["type": "integer", "minimum": 1, "maximum": 15, "default": 8]]) { a, _ in a },
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "track_processes",
            "title": "Track processes",
            "description": "Watch processes in the background for up to 2 hours instead of polling top. action start (selector: pid[+startToken], name or path; includeChildren counts child spawns per minute and per executable, including short-lived ones) returns a trackId; status returns CPU (percent of one core) and memory footprint min/avg/max/last summed over members, largestProcessLifetimePeakBytes (the highest lifetime peak of any single member, so not comparable with the summed footprint), for name/path targets restartCount (a matching instance started after all earlier ones had exited) and additionalInstances (started while another was running), recent events, CPU spikes with the busiest threads (optionally a `sample` capture). stop ends a track of this session; list shows tracks. Status keeps working after the session ends. Max 4 running tracks per session; responses stay under 4 KiB (lists trimmed, with …Omitted counts).",
            "inputSchema": [
                "type": "object",
                "properties": selectorProperties.merging([
                    "action": ["type": "string", "enum": ["start", "status", "stop", "list"]],
                    "trackId": ["type": "string", "description": "For status and stop."],
                    "includeChildren": ["type": "boolean", "default": false],
                    "durationSeconds": ["type": "integer", "minimum": 10, "maximum": 7200, "default": 300],
                    "intervalSeconds": ["type": "number", "minimum": 1, "maximum": 60, "default": 2],
                    "spikeCpuPercent": ["type": "number", "minimum": 10, "maximum": 10000, "default": 150,
                                        "description": "A member at or above this CPU (percent of one core) records a spike with its busiest threads."],
                    "sampleOnSpike": ["type": "boolean", "default": false,
                                      "description": "Also run /usr/bin/sample for 1 s on a spike (at most once per 5 minutes); returns the file path and top frames."],
                ]) { a, _ in a },
                "required": ["action"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "wait_for",
            "title": "Wait for",
            "description": "Wait (up to timeoutSeconds, max 55) until a condition holds instead of sleeping or polling. cpu_idle: CPU below belowPercent for two consecutive 1 s readings — system-wide (percent of all cores) by default, or for a running trackId or a pid(+startToken)/name/path selector (percent of one core, summed; only readings of live matching processes count, so no match never means idle — unavailable if nothing matched, or once the pid or track is gone); on timeout returns the 3 busiest culprits. process_exit: pid (+startToken) exits; unavailable if not visible at the start. memory_pressure_normal: kernel memory pressure back to normal. Returns state met|timed_out|unavailable.",
            "inputSchema": [
                "type": "object",
                "properties": selectorProperties.merging([
                    "condition": ["type": "string", "enum": ["cpu_idle", "process_exit", "memory_pressure_normal"]],
                    "belowPercent": ["type": "number", "minimum": 0, "maximum": 10000, "default": 20],
                    "trackId": ["type": "string", "description": "cpu_idle for the members of a running track."],
                    "timeoutSeconds": ["type": "number", "minimum": 1, "maximum": 55, "default": 20],
                ]) { a, _ in a },
                "required": ["condition"],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_environment",
            "title": "Environment",
            "description": "macOS version and build, CPU architecture and chip, RAM, core counts, and (includeToolchain, default true) the selected Xcode or Command Line Tools path, Xcode version and Swift version. Cached, so cheap to call; use instead of sw_vers/sysctl/xcode-select/swift --version.",
            "inputSchema": [
                "type": "object",
                "properties": ["includeToolchain": ["type": "boolean", "default": true]],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ]

    static let toolNames = Set(tools.compactMap { $0["name"] as? String })

    private func callTool(name: String, args: [String: Any], id: Any, entry: Pending) -> [String: Any] {
        touchPresence()
        do {
            switch name {
            case "get_system_stats":
                record(name)
                var snapshot = sampler.measure(interval: 0.5, includeProcesses: true)
                snapshot.topProcesses = sampler.topProcesses(sortedBy: .cpu, limit: 5, from: snapshot.topProcesses ?? [])
                return result(id: id, try toolResult(text: snapshot.summary, json: snapshot))

            case "get_top_processes":
                let sort = try ProcessSort(rawValue: Args.string(args, "sort") ?? "cpu").orThrow("sort must be cpu or memory")
                let limit = try Args.int(args, "limit", default: 10, in: 1...50)
                record(name, "\(sort.rawValue) \(limit)")
                let snapshot = sampler.measure(interval: 1.0, includeProcesses: true)
                let top = sampler.topProcesses(sortedBy: sort, limit: limit, from: snapshot.topProcesses ?? [])
                return result(id: id, try toolResult(text: ProcessTable.text(top), json: ProcessList(sort: sort.rawValue, processes: top)))

            case "get_stats_history":
                let minutes = try Args.int(args, "minutes", default: 10, in: 1...60)
                let maxPoints = try Args.int(args, "maxPoints", default: 20, in: 0...60)
                record(name, "\(minutes)m")
                let points = history.points(since: Date().addingTimeInterval(-Double(minutes) * 60))
                let recording = history.isRecording()
                guard let summary = HistorySummary.make(from: points, maxPoints: maxPoints) else {
                    let state = recording
                        ? "running but has not recorded this window yet"
                        : "not running (start it with: open -b \(AIStatsPaths.appBundleIdentifier))"
                    return result(id: id, try toolResult(
                        text: "No history for the last \(minutes) minutes. The AIStats menu bar app records history while it runs; it is \(state). get_system_stats works without it.",
                        json: HistoryResult(recording: recording, summary: nil)))
                }
                var text = summary.text
                if !recording { text += "\nThe AIStats app is not recording now; this history ends at the last recorded sample." }
                return result(id: id, try toolResult(text: text, json: HistoryResult(recording: recording, summary: summary)))

            case "diagnose_system":
                let purpose = Args.string(args, "purpose") ?? "slowdown"
                guard ["slowdown", "heavy_work"].contains(purpose) else { throw ToolError("purpose must be slowdown or heavy_work") }
                record(name, purpose)
                let d = Diagnosis.run(purpose: purpose, sampler: sampler)
                return result(id: id, try leanResult(d.summaryLine, d))

            case "find_processes":
                let selector = try Args.selector(args)
                let limit = try Args.int(args, "limit", default: 8, in: 1...ProcessFinder.maxLimit)
                record(name, "by \(selector.kind)" + Self.argsNote(selector))
                var r = ProcessFinder.find(selector, limit: limit, directory: directory)
                // Long paths can push the rows past the budget: drop the smallest rows until it fits.
                while r.processes.count > 1, (try fittedSize(id: id, r.summaryLine, r)) > Self.maxResponseBytes {
                    r.processes.removeLast()
                    r.truncated = true
                }
                return result(id: id, try leanResult(r.summaryLine, r))

            case "track_processes":
                return try trackTool(args, id: id)

            case "get_environment":
                let toolchain = try Args.bool(args, "includeToolchain", default: true)
                record(name)
                // The toolchain probe runs xcrun (up to 15 s): a cancellation stops it.
                let token = CancelToken()
                pendingLock.lock()
                entry.token = token
                let cancelled = entry.cancelled
                pendingLock.unlock()
                if cancelled { token.cancel() }
                let env = EnvironmentProbe.collect(includeToolchain: toolchain, cancel: token)
                return result(id: id, try leanResult(env.summaryLine, env))

            default:
                return errorResponse(id: id, code: -32602, message: "Unknown tool: \(String(name.prefix(64)))")
            }
        } catch {
            return result(id: id, errorToolResult("\(error)"))
        }
    }

    private func trackTool(_ args: [String: Any], id: Any) throws -> [String: Any] {
        let name = "track_processes"
        guard let action = Args.string(args, "action") else { throw ToolError("action is required: start, status, stop or list") }
        switch action {
        case "start":
            let selector = try Args.selector(args)
            let options = try TrackOptions(
                selector: selector,
                includeChildren: try Args.bool(args, "includeChildren", default: false),
                durationSeconds: try Args.int(args, "durationSeconds", default: 300, in: TrackOptions.durationRange),
                intervalSeconds: try Args.double(args, "intervalSeconds", default: 2, in: TrackOptions.intervalRange),
                spikeCpuPercent: try Args.double(args, "spikeCpuPercent", default: 150, in: TrackOptions.spikeRange),
                sampleOnSpike: try Args.bool(args, "sampleOnSpike", default: false))
            record(name, "start by \(selector.kind)" + Self.argsNote(selector))
            return try trackResponse(try tracks.start(options), id: id)
        case "status", "stop":
            guard let trackID = Args.string(args, "trackId") else { throw ToolError("trackId is required for \(action)") }
            record(name, action)
            if action == "stop" { return try trackResponse(try tracks.stop(trackID), id: id) }
            guard let r = tracks.status(trackID) else { throw TrackError.notFound(trackID) }
            return try trackResponse(r, id: id)
        case "list":
            record(name, "list")
            let rows = tracks.list()
            let line = rows.isEmpty ? "No tracks." : "\(rows.count) track(s): " + rows.prefix(4).map { "\($0.trackId) \($0.state)" }.joined(separator: ", ")
            return result(id: id, try leanResult(line, TrackList(tracks: rows)))
        default:
            throw ToolError("action must be start, status, stop or list")
        }
    }

    /// The whole JSON-RPC line for a track report, trimmed to `maxResponseBytes`.
    private func trackResponse(_ report: TrackReport, id: Any) throws -> [String: Any] {
        let fitted = report.fitting(maxBytes: Self.maxResponseBytes) { [self] r in
            (try? fittedSize(id: id, r.summaryLine, r)) ?? Int.max
        }
        return result(id: id, try leanResult(fitted.summaryLine, fitted))
    }

    /// Size in bytes of the final line (`leanResult` wrapped in a response, plus the newline).
    private func fittedSize<T: Encodable>(id: Any, _ line: String, _ value: T) throws -> Int {
        var data = Data()
        JSONWriter.write(result(id: id, try leanResult(line, value)), into: &data)
        return data.count + 1
    }

    // MARK: wait_for

    private func startWait(id: Any, key: String, entry: Pending, params: [String: Any]) {
        func finish(_ response: [String: Any]) {
            pendingLock.lock()
            let live = pending[key] === entry && !entry.cancelled
            if pending[key] === entry { pending[key] = nil }
            pendingLock.unlock()
            if live { send(response, toolCall: true) } // cancelled: no response
        }
        if let a = params["arguments"], !(a is [String: Any]) {
            finish(errorResponse(id: id, code: -32602, message: "Invalid params: arguments must be an object"))
            return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let condition: WaitCondition
        let timeout: Double
        do {
            timeout = try Args.double(args, "timeoutSeconds", default: 20, in: Waiter.timeoutRange)
            condition = try Args.waitCondition(args)
        } catch {
            let message = "\(error)"
            work.async { [self] in finish(result(id: id, errorToolResult(message))) }
            return
        }
        let waiter = Waiter(condition: condition, timeout: timeout, tracks: tracks)
        pendingLock.lock()
        entry.waiter = waiter
        let cancelledAlready = entry.cancelled
        pendingLock.unlock()
        if cancelledAlready { return }
        work.async { [self] in
            touchPresence()
            var note = ""
            if case .cpuIdle(.selector(let selector), _) = condition { note = Self.argsNote(selector) }
            record("wait_for", condition.name + note)
        }
        waiter.start { [weak self] r in
            guard let self else { return }
            let response = (try? self.leanResult(r.summaryLine, r)) ?? self.errorToolResult("could not encode the result")
            finish(self.result(id: id, response))
        }
    }

    // MARK: Helpers

    /// The activity log says only that an argument filter was used, never what it was.
    static func argsNote(_ selector: ProcessSelector) -> String { selector.argsContain != nil ? " with args filter" : "" }

    private func record(_ tool: String, _ detail: String? = nil) {
        activity.record(.init(agent: agentName, tool: tool, detail: detail))
    }

    private struct ProcessList: Encodable { var sort: String; var processes: [ProcessUsage] }
    private struct HistoryResult: Encodable { var recording: Bool; var summary: HistorySummary? }
    private struct TrackList: Encodable { var tracks: [TrackListRow] }

    private func toolResult<T: Encodable>(text: String, json: T) throws -> [String: Any] {
        let data = try Self.encoder.encode(json)
        var result: [String: Any] = [
            "content": [["type": "text", "text": text + "\n\n" + String(decoding: data, as: UTF8.self)]],
            "isError": false,
        ]
        if data.first == UInt8(ascii: "{") { result["structuredContent"] = RawJSON(data: data) }
        return result
    }

    /// One summary line, then compact JSON (for clients that ignore structuredContent), plus structuredContent.
    private func leanResult<T: Encodable>(_ line: String, _ json: T) throws -> [String: Any] {
        let data = try Self.encoder.encode(json)
        var result: [String: Any] = [
            "content": [["type": "text", "text": line + "\n" + String(decoding: data, as: UTF8.self)]],
            "isError": false,
        ]
        if data.first == UInt8(ascii: "{") { result["structuredContent"] = RawJSON(data: data) }
        return result
    }

    private func errorToolResult(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private func result(id: Any, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// Queues one message. Error messages, and every `tools/call` response, are cut to fit
    /// `maxResponseBytes` as a whole line.
    private func send(_ object: [String: Any], toolCall: Bool = false) {
        let data = Self.line(object, toolCall: toolCall)
        outputLock.lock()
        pendingOutputBytes += data.count
        outputLock.unlock()
        out.async { [self] in
            write(data)
            outputLock.lock()
            pendingOutputBytes -= data.count
            outputLock.broadcast()
            outputLock.unlock()
        }
    }

    /// Backpressure: the reader waits while the client is not reading what was already written.
    private func waitForOutputRoom() {
        outputLock.lock()
        while pendingOutputBytes > Self.maxPendingOutputBytes { outputLock.wait() }
        outputLock.unlock()
    }

    static func encodeLine(_ object: Any) -> Data {
        var data = Data()
        JSONWriter.write(object, into: &data)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The serialized line. Error text (a JSON-RPC error's message, or a tool error's text, which can
    /// echo long client input) is clipped so the whole line fits `maxResponseBytes`. Successful results
    /// are sized by the tools themselves.
    static func line(_ object: [String: Any], toolCall: Bool) -> Data {
        let data = encodeLine(object)
        guard data.count > maxResponseBytes else { return data }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return clipped(message) { m in
                var e = error; e["message"] = m
                var o = object; o["error"] = e
                return o
            }
        }
        guard toolCall, let result = object["result"] as? [String: Any], result["isError"] as? Bool == true,
              let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String else { return data }
        return clipped(text) { m in
            var o = object
            o["result"] = ["content": [["type": "text", "text": m]], "isError": true] as [String: Any]
            return o
        }
    }

    private static func clipped(_ message: String, _ build: (String) -> [String: Any]) -> Data {
        var keep = message.count
        var data = encodeLine(build(message))
        while data.count > maxResponseBytes, keep > 0 {
            keep = max(0, min(keep - 1, keep * 3 / 4))
            data = encodeLine(build(String(message.prefix(keep)) + "…"))
        }
        return data
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let self else { throw ToolError(message) }
        return self
    }
}

/// Typed access to tool arguments. Wrong types are errors, not silently defaulted.
enum Args {
    static func string(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            guard d.isFinite, d.rounded() == d, abs(d) < 1e12 else { return nil }
            return Int(d)
        }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func int(_ args: [String: Any], _ key: String, default value: Int, in range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key], !(raw is NSNull) else { return value }
        guard let n = int(raw), range.contains(n) else { throw ToolError("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)") }
        return n
    }

    static func double(_ args: [String: Any], _ key: String, default value: Double, in range: ClosedRange<Double>) throws -> Double {
        guard let raw = args[key], !(raw is NSNull) else { return value }
        var d: Double?
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { d = n.doubleValue } else if let s = raw as? String { d = Double(s) }
        guard let d, d.isFinite, range.contains(d) else { throw ToolError("\(key) must be a number from \(range.lowerBound) to \(range.upperBound)") }
        return d
    }

    static func bool(_ args: [String: Any], _ key: String, default value: Bool) throws -> Bool {
        guard let raw = args[key], !(raw is NSNull) else { return value }
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        throw ToolError("\(key) must be true or false")
    }

    static func optionalString(_ args: [String: Any], _ key: String) throws -> String? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        guard let s = raw as? String else { throw ToolError("\(key) must be a string") }
        return s
    }

    static func selector(_ args: [String: Any]) throws -> ProcessSelector {
        var pid: Int?
        if let raw = args["pid"], !(raw is NSNull) {
            guard let p = int(raw) else { throw ToolError("pid must be an integer") }
            pid = p
        }
        return try ProcessSelector.parse(pid: pid, startToken: optionalString(args, "startToken"),
                                         name: optionalString(args, "name"), path: optionalString(args, "path"),
                                         match: optionalString(args, "match"), argsContain: optionalString(args, "argsContain"))
    }

    static func waitCondition(_ args: [String: Any]) throws -> WaitCondition {
        guard let condition = string(args, "condition") else {
            throw ToolError("condition is required: cpu_idle, process_exit or memory_pressure_normal")
        }
        if args["argsContain"] != nil, !(args["argsContain"] is NSNull),
           condition != "cpu_idle" || !["name", "path"].contains(where: { args[$0] != nil && !(args[$0] is NSNull) }) {
            throw ToolError("argsContain goes with a name or path selector of cpu_idle")
        }
        switch condition {
        case "cpu_idle":
            let below = try double(args, "belowPercent", default: 20, in: 0...10_000)
            let hasSelector = ["pid", "name", "path"].contains { args[$0] != nil && !(args[$0] is NSNull) }
            if let track = try optionalString(args, "trackId") {
                if hasSelector { throw ToolError("give trackId or a pid/name/path selector, not both") }
                return .cpuIdle(.track(track), belowPercent: below)
            }
            if hasSelector { return .cpuIdle(.selector(try selector(args)), belowPercent: below) }
            return .cpuIdle(.system, belowPercent: below)
        case "process_exit":
            guard let raw = args["pid"], let pid = int(raw), pid > 0, pid <= Int(Int32.max) else {
                throw ToolError("process_exit needs pid")
            }
            let token = try optionalString(args, "startToken")
            if let token, UInt64(token) == nil { throw ToolError("startToken must be the string returned by find_processes") }
            return .processExit(pid: Int32(pid), startToken: token)
        case "memory_pressure_normal":
            return .memoryPressureNormal
        default:
            throw ToolError("condition must be cpu_idle, process_exit or memory_pressure_normal")
        }
    }
}

public enum ProcessTable {
    public static func text(_ processes: [ProcessUsage]) -> String {
        func pad(_ s: String, _ width: Int) -> String { String(repeating: " ", count: max(0, width - s.count)) + s }
        var lines = ["\(pad("PID", 7))  \(pad("CPU", 6))  \(pad("MEMORY", 9))  NAME"]
        for p in processes {
            lines.append("\(pad(String(p.pid), 7))  \(pad(String(format: "%.1f%%", p.cpuPercent), 6))  \(pad(Format.bytes(p.memoryBytes), 9))  \(p.name)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Already-encoded JSON (from JSONEncoder) embedded as-is in a response.
struct RawJSON { let data: Data }

public enum AIStatsVersion { public static let current = "0.3.0" }

/// Serializes JSON-RPC messages. Unlike JSONSerialization it writes doubles in shortest form
/// (34.7, not 34.700000000000003) and can embed `RawJSON`, which keeps responses small.
enum JSONWriter {
    static func write(_ value: Any, into out: inout Data) {
        switch value {
        case let raw as RawJSON:
            out.append(raw.data)
        case let s as String:
            writeString(s, into: &out)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out.append(contentsOf: Array((n.boolValue ? "true" : "false").utf8))
            } else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                if !d.isFinite { out.append(contentsOf: Array("null".utf8)) }
                else if d == d.rounded(), abs(d) < 1e15 { out.append(contentsOf: Array(String(Int64(d)).utf8)) }
                else { out.append(contentsOf: Array(String(d).utf8)) }
            } else {
                out.append(contentsOf: Array(n.stringValue.utf8))
            }
        case let dict as [String: Any]:
            out.append(UInt8(ascii: "{"))
            var first = true
            for key in dict.keys.sorted() {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                write(dict[key]!, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        case let array as [Any]:
            out.append(UInt8(ascii: "["))
            for (i, item) in array.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                write(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        default:
            out.append(contentsOf: Array("null".utf8))
        }
    }

    static func writeString(_ s: String, into out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for u in s.unicodeScalars {
            switch u {
            case "\"": out.append(contentsOf: [0x5C, 0x22])
            case "\\": out.append(contentsOf: [0x5C, 0x5C])
            case "\n": out.append(contentsOf: [0x5C, 0x6E])
            case "\r": out.append(contentsOf: [0x5C, 0x72])
            case "\t": out.append(contentsOf: [0x5C, 0x74])
            default:
                if u.value < 0x20 {
                    out.append(contentsOf: Array(String(format: "\\u%04x", u.value).utf8))
                } else {
                    out.append(contentsOf: Array(String(u).utf8))
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// Reads newline-delimited lines from stdin with a length cap: a longer line is skipped to its newline
/// and reported as `MCPServer.oversizedLine`, so one huge message can't grow memory without bound.
final class StdinLineReader {
    private let fd: Int32
    private let maxLine: Int
    private var buffer: [UInt8] = []
    private var start = 0
    private var eof = false
    private var discarding = false

    init(fd: Int32 = 0, maxLine: Int) { self.fd = fd; self.maxLine = maxLine }

    func next() -> String? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer[start...].firstIndex(of: 0x0A) {
                let line = buffer[start..<nl]
                start = nl + 1
                if start > 64 * 1024 && start * 2 > buffer.count { buffer.removeFirst(start); start = 0 }
                if discarding { discarding = false; return MCPServer.oversizedLine }
                return line.count > maxLine ? MCPServer.oversizedLine : String(decoding: line, as: UTF8.self)
            }
            if buffer.count - start > maxLine {
                // No newline within the limit: drop what we have and skip to the next newline.
                discarding = true
                buffer.removeAll(keepingCapacity: true)
                start = 0
            }
            if eof {
                defer { buffer.removeAll(); start = 0; discarding = false }
                if discarding { return MCPServer.oversizedLine }
                return buffer.count > start ? String(decoding: buffer[start...], as: UTF8.self) : nil
            }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
            else if n == 0 || errno != EINTR { eof = true }
        }
    }
}
