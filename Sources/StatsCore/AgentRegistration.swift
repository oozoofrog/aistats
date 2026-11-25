import CryptoKit
import Darwin
import Foundation

/// Registers the `aistats mcp` server with agent apps. AppKit-free, shared by the CLI and the menu bar app.
///
/// Guarantees (users' configs are not ours):
/// - G1: AIStats never creates, changes or deletes a file it didn't create, except the `aistats` entry of
///   the target config (and a same-folder temp file that becomes it). Antigravity / Claude Desktop / Cursor JSON is
///   edited textually: only the `mcpServers.aistats` member's bytes change, every other byte stays.
///   Backups and locks live in AIStats's own data folder, in folders that must be real directories owned
///   by the user (never a symlink); a folder AIStats creates is 0700, an existing one keeps its mode.
///   Pruning deletes only backups listed in AIStats's manifest (`backups/<agent>/manifest.jsonl`) whose
///   content still matches the listed SHA-256.
/// - G2: an `aistats` entry is ours only when its command (no NUL; compared on `realpath`, both sides
///   must resolve) is this binary, the `aistats` binary inside an AIStats.app bundle (bundle id
///   `com.oozoofrog.aistats`, checked on real paths), or it carries `AISTATS_MANAGED=1`; and its args are
///   exactly ["mcp"] with no other settings (for Codex also none in the TOML that `codex mcp get` hides).
///   Any other entry is only replaced with consent bound to that exact entry: its fingerprint, the full
///   SHA-256 of the entry's exact source bytes (JSON member text; for Codex the full `codex mcp get --json`
///   output with sorted keys plus the TOML statements of the entry). The first 12 hex digits are shown
///   and named in `--replace`; every later comparison uses the full hash. Ambiguous configs (duplicate
///   keys, comments where the format has none, a Codex file the agent itself can't parse, a
///   Codex config that defines `aistats` while Codex says it doesn't) are check_failed, never
///   "not installed".
/// - G3: before a config changes, a byte-exact copy is written to `$AISTATS_HOME/backups/<agent>/`.
/// - G4: a failed change either leaves the previous entry as it was, restores it exactly, or says what the
///   entry is now and where the backup is.
/// - Relative `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `AISTATS_HOME` are resolved once
///   against this process's working directory, and the agent CLIs get that same absolute value.
///
/// Residual risk (documented, not handled):
/// - another program rewriting the same config file in the few milliseconds between our final check and
///   the rename (AIStats processes serialize among themselves with locks);
/// - wrappers that rewrite the config right before the agent's own CLI runs;
/// - side effects of the agents' own CLIs on their own files, which AIStats runs but does not control:
///   Claude Code adds its own keys to `.claude.json` and rotates `backups/.claude.json.backup.*` next to
///   it; Codex creates
///   `$CODEX_HOME/tmp/arg0-*` even for `codex mcp get`.
public enum AgentTarget: String, CaseIterable, Sendable, Codable {
    case claudeCode = "claude-code"
    case codex
    case antigravity
    case claudeDesktop = "claude-desktop"
    case cursor

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        }
    }

    var cliName: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .antigravity, .claudeDesktop, .cursor: return nil
        }
    }

    var appName: String? {
        switch self {
        case .claudeDesktop: return "Claude.app"
        case .antigravity: return "Antigravity.app"
        case .cursor: return "Cursor.app"
        default: return nil
        }
    }
}

public enum RegistrationState: Equatable, Sendable {
    case notInstalled
    case installed
    /// Our entry points at another aistats binary (the app moved or was rebuilt elsewhere).
    case pathUpdateNeeded(registered: String)
    /// An `aistats` entry that isn't provably ours; it is left alone unless a replace is confirmed.
    case nameConflict(registered: String)
    case checkFailed(String)
    case agentNotFound

    public var code: String {
        switch self {
        case .notInstalled: return "not_installed"
        case .installed: return "installed"
        case .pathUpdateNeeded: return "path_update_needed"
        case .nameConflict: return "name_conflict"
        case .checkFailed: return "check_failed"
        case .agentNotFound: return "agent_not_found"
        }
    }

    public var detail: String? {
        switch self {
        case .pathUpdateNeeded(let p), .nameConflict(let p): return p
        case .checkFailed(let r): return r
        default: return nil
        }
    }
}

public struct RegistrationStatus: Sendable {
    public var target: AgentTarget
    public var state: RegistrationState
    /// Where the entry lives (config file), for display.
    public var location: String?
    /// The agent CLI that was used to check or change the entry (CLI agents only).
    public var cliPath: String?
    /// Fingerprint of the existing `aistats` entry, if any; a replace must name it.
    public var entryFingerprint: String?
}

public struct RegistrationOutcome: Sendable {
    public var target: AgentTarget
    public var ok: Bool
    /// "registered", "already_registered", "updated", "replaced", "removed", "not_registered", or "failed".
    public var action: String
    public var message: String
    public var status: RegistrationStatus
    /// Byte-exact copy of the config file taken before it changed, if one was made.
    public var backup: String?
}

/// Paths, environment and search directories. `current()` reads the real ones; tests inject temp dirs.
public struct RegistrationEnvironment: Sendable {
    public var home: URL
    public var variables: [String: String]
    /// Directories searched for the agent CLIs, in order.
    public var cliSearchPaths: [String]
    /// Directories searched for Claude.app / Cursor.app.
    public var appSearchPaths: [String]
    public var timeout: TimeInterval
    /// AIStats's own data folder (`$AISTATS_HOME` or ~/Library/Application Support/AIStats): locks and backups.
    public var dataDirectory: URL
    public var lockDirectory: URL { dataDirectory.appendingPathComponent("locks", isDirectory: true) }
    public var backupDirectory: URL { dataDirectory.appendingPathComponent("backups", isDirectory: true) }

    /// Config-folder overrides that may be relative; they are made absolute once (see `absolute`).
    public static let pathVariables = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "AISTATS_HOME"]

    /// `currentDirectory` (default: this process's) is what relative overrides are resolved against.
    public init(home: URL, variables: [String: String], cliSearchPaths: [String], appSearchPaths: [String],
                timeout: TimeInterval = 30, dataDirectory: URL? = nil, currentDirectory: String? = nil) {
        // Resolve each override once, so AIStats and the agent CLIs it runs (in another directory) agree.
        var vars = variables
        let cwd = currentDirectory ?? FileManager.default.currentDirectoryPath
        for key in Self.pathVariables {
            if let v = vars[key], !v.isEmpty { vars[key] = Self.absolute(v, cwd: cwd, home: home.path) }
        }
        self.home = home; self.variables = vars; self.cliSearchPaths = cliSearchPaths
        self.appSearchPaths = appSearchPaths; self.timeout = timeout
        if let dataDirectory {
            self.dataDirectory = dataDirectory
        } else if let custom = vars["AISTATS_HOME"], !custom.isEmpty {
            self.dataDirectory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            self.dataDirectory = home.appendingPathComponent("Library/Application Support/AIStats", isDirectory: true)
        }
    }

    public static func current() -> RegistrationEnvironment {
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(), isDirectory: true)
        return RegistrationEnvironment(home: home, variables: env, cliSearchPaths: searchPaths(home: home, path: env["PATH"], nvmDir: env["NVM_DIR"]),
                                       appSearchPaths: ["/Applications", home.appendingPathComponent("Applications").path])
    }

    /// Inherited PATH entries first (what the user's shell would run), then the usual install locations
    /// a GUI app's minimal PATH misses, including every nvm node version (newest first).
    static func searchPaths(home: URL, path: String?, nvmDir: String? = nil) -> [String] {
        var dirs: [String] = []
        func add(_ d: String) { if !d.isEmpty, !dirs.contains(d) { dirs.append(d) } }
        for p in (path ?? "").split(separator: ":") { add(String(p)) }
        add(home.appendingPathComponent(".local/bin").path)
        add("/opt/homebrew/bin")
        add("/usr/local/bin")
        add(home.appendingPathComponent(".volta/bin").path)
        add(home.appendingPathComponent(".bun/bin").path)
        let nvm = nvmDir.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".nvm")
        for bin in nodeBins(nvm.appendingPathComponent("versions/node")) { add(bin) }
        add(home.appendingPathComponent(".asdf/shims").path)
        add(home.appendingPathComponent(".npm-global/bin").path)
        add(home.appendingPathComponent(".claude/local").path)
        add("/usr/bin")
        add("/bin")
        return dirs
    }

    /// `<nvm>/versions/node/*/bin`, newest version first, comparing numerically (v20.10.0 > v9.11.2).
    static func nodeBins(_ dir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        func parts(_ s: String) -> [Int] {
            s.drop { $0 == "v" }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        return names.filter { $0.hasPrefix("v") }
            .sorted { parts($1).lexicographicallyPrecedes(parts($0)) }
            .map { dir.appendingPathComponent($0).appendingPathComponent("bin").path }
    }

    /// `~` / `~/…` → under `home`; relative → `cwd/…` (joined, not normalized, so `..` resolves the way
    /// the kernel does); absolute stays.
    static func absolute(_ path: String, cwd: String, home: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return (cwd.hasSuffix("/") ? cwd : cwd + "/") + path
    }

    func value(_ key: String) -> String? { variables[key].flatMap { $0.isEmpty ? nil : $0 } }

    /// Child environment: ours plus a PATH that includes the search directories.
    var childEnvironment: [String: String] {
        var env = variables
        env["HOME"] = home.path
        var path = cliSearchPaths
        for p in (variables["PATH"] ?? "").split(separator: ":").map(String.init) where !p.isEmpty && !path.contains(p) { path.append(p) }
        for p in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !path.contains(p) { path.append(p) }
        env["PATH"] = path.joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }

    func findCLI(_ name: String) -> String? {
        for dir in cliSearchPaths {
            let p = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func configURL(_ target: AgentTarget) -> URL {
        switch target {
        case .claudeCode:
            if let dir = value("CLAUDE_CONFIG_DIR") { return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json") }
            return home.appendingPathComponent(".claude.json")
        case .codex:
            return URL(fileURLWithPath: value("CODEX_HOME") ?? home.appendingPathComponent(".codex").path).appendingPathComponent("config.toml")
        case .antigravity:
            return home.appendingPathComponent(".gemini/config/mcp_config.json")
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        }
    }

    func agentPresent(_ target: AgentTarget) -> Bool {
        if target == .antigravity, findCLI("agy") != nil { return true }
        if let cli = target.cliName { return findCLI(cli) != nil }
        if let app = target.appName, appSearchPaths.contains(where: { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(app)) }) {
            return true
        }
        // Antigravity shares the .gemini tree with other tools.
        if target == .antigravity { return FileManager.default.fileExists(atPath: configURL(target).path) }
        // The app may live elsewhere; its config folder shows it was used here.
        return FileManager.default.fileExists(atPath: configURL(target).deletingLastPathComponent().path)
    }
}

// MARK: - Entries and ownership

/// An `aistats` server entry as the agent stores it, normalized across config formats.
public struct RegistrationEntry: Equatable, Sendable {
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    /// Settings we don't manage (non-default values), sorted, e.g. "cwd", "timeout", "transport.type=sse".
    public var extras: [String]
    /// The full entry as canonical JSON (sorted keys), to compare and fingerprint it.
    public var raw: Data
    /// The entry's exact bytes in the config file (JSON configs), used to restore it verbatim.
    public var source: Data?
    /// Full SHA-256 of the entry's exact source: the JSON member's value bytes, or for Codex its full
    /// `codex mcp get --json` output (sorted keys) plus the entry's TOML statements. Identity and consent.
    public var digest: Data

    public init(command: String?, args: [String], env: [String: String], extras: [String], raw: Data, source: Data? = nil,
                hashInput: Data? = nil) {
        self.command = command; self.args = args; self.env = env; self.extras = Array(Set(extras)).sorted(); self.raw = raw
        self.source = source
        self.digest = Data(SHA256.hash(data: hashInput ?? source ?? raw))
    }

    /// Two entries are the same when their exact source bytes are (every field, every digit, env values).
    public static func == (a: RegistrationEntry, b: RegistrationEntry) -> Bool { a.digest == b.digest }

    /// Same meaning, ignoring formatting (canonical JSON), e.g. after an agent CLI rewrote its file.
    func sameSettings(_ other: RegistrationEntry) -> Bool { raw == other.raw }

    /// First 12 hex digits of `digest`, for display. `--replace` names this (or more of the digest).
    public var fingerprint: String { String(fullFingerprint.prefix(12)) }
    public var fullFingerprint: String { digest.map { String(format: "%02x", $0) }.joined() }

    /// True when `consent` (12–64 hex digits, as shown) names this entry's digest.
    func matches(consent: String) -> Bool {
        let c = consent.lowercased()
        return (12...64).contains(c.count) && c.allSatisfy(\.isHexDigit) && fullFingerprint.hasPrefix(c)
    }

    /// Short hash of a string, for lock file names.
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// For display: command, args, env names (values hidden) and other settings.
    public var summary: String {
        var s = ([command ?? "(no command)"] + args).joined(separator: " ")
        if !env.isEmpty { s += " [env " + env.keys.sorted().map { "\($0)=…" }.joined(separator: ",") + "]" }
        if !extras.isEmpty { s += " [+ " + extras.joined(separator: ", ") + "]" }
        return String(s.prefix(400))
    }

    static func encodeRaw(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }

    /// Claude Code, Antigravity, Claude Desktop, Cursor: `{"command": …, "args": […], "env": {…}}`.
    static func fromJSONConfig(_ value: Any, source: Data? = nil) -> RegistrationEntry {
        guard let dict = value as? [String: Any] else {
            return RegistrationEntry(command: nil, args: [], env: [:], extras: ["(not an object)"], raw: encodeRaw(value), source: source)
        }
        var command: String?, args: [String] = [], env: [String: String] = [:], extras: [String] = []
        for (key, v) in dict {
            switch key {
            case "command":
                if let s = v as? String { command = s } else { extras.append("command") }
            case "args":
                if let a = v as? [String] { args = a } else if !(v is NSNull) { extras.append("args") }
            case "env":
                if let d = v as? [String: String] { env = d } else if !(v is NSNull) { extras.append("env") }
            case "type":
                if (v as? String) != "stdio" { extras.append("type") }
            default:
                extras.append(key)
            }
        }
        return RegistrationEntry(command: command, args: args, env: env, extras: extras, raw: encodeRaw(dict), source: source)
    }

    /// `codex mcp get <name> --json` plus what config.toml says about the entry. Codex prints every field
    /// it knows, so defaults (null, empty, enabled) are ignored for ownership, but the fingerprint covers
    /// the full output and the entry's TOML statements (Codex doesn't print e.g. `required`). Settings
    /// found only in the TOML count as extras; a config AIStats can't analyze counts as one too.
    static func fromCodexJSON(_ value: Any, config: Data? = nil) -> RegistrationEntry? {
        guard var entry = fromCodexOutput(value) else { return nil }
        var hashInput = entry.raw
        hashInput.append(0x0A)
        if let config {
            if let toml = CodexTOMLScan.scan(config) {
                hashInput.append(toml.source)
                entry.extras = Array(Set(entry.extras + toml.extras.map { "toml:\($0)" })).sorted()
            } else {
                hashInput.append(config)
                entry.extras = Array(Set(entry.extras + ["(config.toml not analyzable)"])).sorted()
            }
        }
        entry.digest = Data(SHA256.hash(data: hashInput))
        return entry
    }

    private static func fromCodexOutput(_ value: Any) -> RegistrationEntry? {
        guard let dict = value as? [String: Any] else { return nil }
        var command: String?, args: [String] = [], env: [String: String] = [:], extras: [String] = []
        func isDefault(_ v: Any) -> Bool {
            if v is NSNull { return true }
            if let a = v as? [Any] { return a.isEmpty }
            if let d = v as? [String: Any] { return d.isEmpty }
            return false
        }
        for (key, v) in dict {
            switch key {
            case "name": continue
            case "enabled":
                if (v as? NSNumber)?.boolValue != true { extras.append("enabled=false") }
            case "transport":
                guard let t = v as? [String: Any] else { extras.append("transport"); continue }
                for (tk, tv) in t {
                    switch tk {
                    case "type": if (tv as? String) != "stdio" { extras.append("transport.type=\(tv)") }
                    case "command": if let s = tv as? String { command = s } else { extras.append("command") }
                    case "args": if let a = tv as? [String] { args = a } else if !isDefault(tv) { extras.append("args") }
                    case "env":
                        if let d = tv as? [String: String] { env = d } else if !isDefault(tv) { extras.append("env") }
                    default: if !isDefault(tv) { extras.append(tk) }
                    }
                }
            default:
                if !isDefault(v) { extras.append(key) }
            }
        }
        return RegistrationEntry(command: command, args: args, env: env, extras: extras, raw: encodeRaw(dict))
    }
}

public final class AgentRegistrar: @unchecked Sendable {
    public static let serverName = "aistats"
    public static let marker = (key: "AISTATS_MANAGED", value: "1")
    public static let bundleIdentifier = "com.oozoofrog.aistats"
    public static let maxBackups = 5

    /// Absolute path of the `aistats` binary to register; args are always ["mcp"].
    public let binaryPath: String
    public let environment: RegistrationEnvironment
    private let locks: [AgentTarget: NSLock] = Dictionary(uniqueKeysWithValues: AgentTarget.allCases.map { ($0, NSLock()) })
    /// Test hooks: after the status that install/uninstall decide on, and right before a CLI agent's
    /// config is changed (after the final re-check and the backup).
    var afterInspect: ((AgentTarget) -> Void)?
    var beforeCLIChange: ((AgentTarget) -> Void)?

    public init(binaryPath: String, environment: RegistrationEnvironment = .current()) {
        self.binaryPath = binaryPath
        self.environment = environment
    }

    func backups(_ target: AgentTarget) -> BackupStore {
        BackupStore(directory: environment.backupDirectory.appendingPathComponent(target.rawValue, isDirectory: true), keep: Self.maxBackups)
    }

    // MARK: Status

    public func status(_ target: AgentTarget) -> RegistrationStatus {
        locks[target]!.lock(); defer { locks[target]!.unlock() }
        return inspect(target).status
    }

    private struct Inspection {
        var status: RegistrationStatus
        var entry: RegistrationEntry?
    }

    private func inspect(_ target: AgentTarget) -> Inspection {
        let url = environment.configURL(target)
        let cli = target.cliName.flatMap { environment.findCLI($0) }
        var status = RegistrationStatus(target: target, state: .notInstalled, location: url.path, cliPath: cli)
        guard environment.agentPresent(target) else {
            status.state = .agentNotFound
            let entry = try? readEntry(target, url: url)
            status.entryFingerprint = entry?.fingerprint
            return Inspection(status: status, entry: entry)
        }
        do {
            let entry = try readEntry(target, url: url)
            status.state = classify(entry)
            status.entryFingerprint = entry?.fingerprint
            return Inspection(status: status, entry: entry)
        } catch {
            status.state = .checkFailed("\(error)")
            return Inspection(status: status, entry: nil)
        }
    }

    func classify(_ entry: RegistrationEntry?) -> RegistrationState {
        guard let entry else { return .notInstalled }
        let managed = entry.env[Self.marker.key]
        // A NUL can't be part of a path; C calls would see only the part before it.
        guard let command = entry.command, !command.contains("\0"), entry.args == ["mcp"], entry.extras.isEmpty,
              entry.env.keys.allSatisfy({ $0 == Self.marker.key }), managed == nil || managed == Self.marker.value else {
            return .nameConflict(registered: entry.summary)
        }
        if Self.samePath(command, binaryPath) { return .installed }
        if managed == Self.marker.value || Self.isOurBundleBinary(command) { return .pathUpdateNeeded(registered: command) }
        return .nameConflict(registered: entry.summary)
    }

    static func realPath(_ p: String) -> String? {
        guard let r = realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// The same string, or two paths that both resolve (`realpath`) to the same file. A path that doesn't
    /// resolve (e.g. `missing/../x`) is never "the same" by normalizing it.
    static func samePath(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.contains("\0"), !b.contains("\0"), let ra = realPath(a), let rb = realPath(b) else { return false }
        return ra == rb
    }

    /// `<…>.app/Contents/MacOS/aistats` of an AIStats bundle, judged on real paths: the command must be
    /// that bundle's own binary (a regular file inside the bundle, not a link out of it) and the bundle's
    /// identifier must be ours.
    static func isOurBundleBinary(_ command: String) -> Bool {
        let url = URL(fileURLWithPath: command)
        guard url.lastPathComponent == "aistats" else { return false }
        let macOS = url.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent(), app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app",
              let bundle = realPath(app.path), let binary = realPath(command),
              realPath(bundle + "/Contents/MacOS/aistats") == binary, binary.hasPrefix(bundle + "/") else { return false }
        var st = stat()
        guard lstat(binary, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        guard let info = NSDictionary(contentsOf: URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")) else { return false }
        return info["CFBundleIdentifier"] as? String == bundleIdentifier
    }

    /// Reads the entry the agent will use. Throws when that can't be determined (never "not installed" on doubt).
    private func readEntry(_ target: AgentTarget, url: URL) throws -> RegistrationEntry? {
        switch target {
        case .codex: return try readCodex(url).entry
        default: return try entry(from: try Self.readConfigData(url), name: url.lastPathComponent)
        }
    }

    /// Codex's own reading of its config is authoritative (TOML has many equivalent spellings); the file's
    /// bytes must be the same before and after it, and they are what the entry is judged (and backed up) on.
    /// "Not installed" only for Codex's plain not-found answer, and only if the file doesn't define the
    /// entry anyway (Codex can fail on a file and still print that phrase inside its error).
    private func readCodex(_ url: URL) throws -> (entry: RegistrationEntry?, bytes: Data?) {
        let before = try Self.readConfigData(url)
        let r = try runCLI(.codex, ["mcp", "get", Self.serverName, "--json"], check: false)
        let bytes = try Self.readConfigData(url)
        guard bytes == before else { throw ConfigError("\(url.lastPathComponent) changed while it was being checked; try again") }
        if r.succeeded {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)),
                  let entry = RegistrationEntry.fromCodexJSON(obj, config: bytes) else {
                throw ConfigError("codex mcp get returned output that isn't the expected JSON")
            }
            return (entry, bytes)
        }
        guard !r.timedOut, Self.isCodexNotFound(r) else { throw ConfigError("codex mcp get failed: \(Self.firstLine(r))") }
        if let bytes {
            if let toml = CodexTOMLScan.scan(bytes) {
                if toml.defined {
                    throw ConfigError("codex reports no aistats server, but \(url.lastPathComponent) defines one; left unchanged")
                }
            } else if Self.containsToken(bytes, Self.serverName) {
                throw ConfigError("codex reports no aistats server, but \(url.lastPathComponent) mentions aistats in a way AIStats can't check; left unchanged")
            }
        }
        return (nil, bytes)
    }

    /// Exactly Codex's not-found message (warnings aside), nothing else on stdout or stderr.
    static func isCodexNotFound(_ r: Subprocess.Result) -> Bool {
        guard r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let lines = r.stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("WARNING:") }
        let expected = "No MCP server named '\(serverName)' found"
        return lines.count == 1 && [expected, expected + ".", "Error: " + expected, "Error: " + expected + "."].contains(lines[0])
    }

    /// `token` in `data` not directly preceded or followed by a key character (letters, digits, `_`, `-`).
    static func containsToken(_ data: Data, _ token: String) -> Bool {
        let b = [UInt8](data), t = [UInt8](token.utf8)
        func keyChar(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D
        }
        guard b.count >= t.count, !t.isEmpty else { return false }
        for i in 0...(b.count - t.count) where b[i..<(i + t.count)].elementsEqual(t) {
            if (i == 0 || !keyChar(b[i - 1])) && (i + t.count == b.count || !keyChar(b[i + t.count])) { return true }
        }
        return false
    }

    /// The `aistats` entry of a JSON config's bytes (duplicate keys on the way to it are an error).
    private func entry(from data: Data?, name: String) throws -> RegistrationEntry? {
        let doc = try ConfigDocument.parse(data, name: name)
        return doc.entry.map { RegistrationEntry.fromJSONConfig($0, source: doc.entrySource) }
    }

    /// The config's bytes, nil if it doesn't exist. Only regular files (or links to them) are read, so a
    /// FIFO or device at the config path can't block us.
    static func readConfigData(_ url: URL) throws -> Data? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            if errno == ENOENT { return nil }
            throw ConfigError("can't read \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            guard stat(url.path, &st) == 0 else {
                if errno == ENOENT { throw ConfigError("\(url.lastPathComponent) is a broken symlink") }
                throw ConfigError("can't read \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ConfigError("\(url.lastPathComponent) is not a regular file") }
        do { return try Data(contentsOf: url) } catch {
            throw ConfigError("can't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Install / uninstall

    /// Registers this binary. An entry that isn't ours (a name conflict) is replaced only when `replacing`
    /// is its fingerprint (`RegistrationStatus.entryFingerprint`), i.e. the user confirmed exactly that entry.
    public func install(_ target: AgentTarget, replacing: String? = nil) -> RegistrationOutcome {
        install(target, replacing: replacing, requireConflict: false)
    }

    /// Applies GUI consent to a name conflict only. The ordinary install contract can also create
    /// or update an owned registration when there is no conflict.
    package func replaceConfirmedConflict(_ target: AgentTarget, fingerprint: String) -> RegistrationOutcome {
        install(target, replacing: fingerprint, requireConflict: true)
    }

    private func install(_ target: AgentTarget, replacing: String?, requireConflict: Bool) -> RegistrationOutcome {
        locks[target]!.lock(); defer { locks[target]!.unlock() }
        return withProcessLock(target) {
            let before = inspect(target)
            afterInspect?(target)
            if requireConflict {
                guard case .nameConflict = before.status.state,
                      let entry = before.entry, entry.fingerprint == replacing else {
                    return outcome(target, false, "failed", Self.changedMessage(before.entry), before.status)
                }
            }
            var replacing_ = false
            switch before.status.state {
            case .agentNotFound:
                return outcome(target, false, "failed", "\(target.displayName) was not found on this Mac", before.status)
            case .checkFailed(let why):
                return outcome(target, false, "failed", "could not read the current configuration: \(why)", before.status)
            case .installed:
                return outcome(target, true, "already_registered", "already registered", before.status)
            case .nameConflict(let other):
                let fp = before.entry?.fingerprint ?? "?"
                guard let replacing else {
                    return outcome(target, false, "failed",
                                   "another MCP server named aistats is registered (\(other); entry \(fp)); left unchanged. To overwrite exactly this entry (a backup is kept): aistats install \(target.rawValue) --replace \(fp)",
                                   before.status)
                }
                guard let entry = before.entry, entry.matches(consent: replacing) else {
                    return outcome(target, false, "failed",
                                   "the aistats entry is not the one confirmed (now: \(other); entry \(fp)); left unchanged", before.status)
                }
                replacing_ = true
            case .notInstalled, .pathUpdateNeeded:
                break
            }
            let updating = before.entry != nil
            let result = target.cliName != nil
                ? changeWithCLI(target, expected: before.entry, install: true)
                : changeJSON(target, expected: before.entry, install: true)
            let after = inspect(target).status
            if let error = result.error {
                return outcome(target, false, "failed", error, after, backup: result.backup)
            }
            guard after.state == .installed else {
                return outcome(target, false, "failed", "registration did not take effect (now: \(after.state.code))" + Self.backupNote(result.backup),
                               after, backup: result.backup)
            }
            let action = replacing_ ? "replaced" : (updating ? "updated" : "registered")
            let message = replacing_ ? "replaced the other aistats entry" : (updating ? "updated to the current binary" : "registered")
            return outcome(target, true, action, message + result.note + (result.backup.map { "; backup: \($0)" } ?? ""), after, backup: result.backup)
        }
    }

    public func uninstall(_ target: AgentTarget) -> RegistrationOutcome {
        locks[target]!.lock(); defer { locks[target]!.unlock() }
        return withProcessLock(target) {
            let before = inspect(target)
            afterInspect?(target)
            switch before.status.state {
            case .notInstalled:
                return outcome(target, true, "not_registered", "not registered", before.status)
            case .nameConflict(let other):
                return outcome(target, false, "failed", "the aistats entry is not ours (\(other)); left unchanged", before.status)
            case .checkFailed(let why):
                return outcome(target, false, "failed", "could not read the current configuration: \(why)", before.status)
            case .agentNotFound:
                // The JSON-config agents can still be cleaned up without the app installed, if the entry is ours.
                guard target.cliName == nil, before.entry != nil, Self.isOurs(classify(before.entry)) else {
                    return outcome(target, false, "failed", "\(target.displayName) was not found on this Mac", before.status)
                }
            case .installed, .pathUpdateNeeded:
                break
            }
            let result = target.cliName != nil ? changeWithCLI(target, expected: before.entry, install: false)
                                                : changeJSON(target, expected: before.entry, install: false)
            let after = inspect(target).status
            if let error = result.error { return outcome(target, false, "failed", error, after, backup: result.backup) }
            guard after.state == .notInstalled || after.state == .agentNotFound else {
                return outcome(target, false, "failed", "removal did not take effect (now: \(after.state.code))" + Self.backupNote(result.backup),
                               after, backup: result.backup)
            }
            return outcome(target, true, "removed", "removed" + result.note + (result.backup.map { "; backup: \($0)" } ?? ""), after, backup: result.backup)
        }
    }

    private func outcome(_ t: AgentTarget, _ ok: Bool, _ action: String, _ message: String, _ status: RegistrationStatus,
                         backup: String? = nil) -> RegistrationOutcome {
        RegistrationOutcome(target: t, ok: ok, action: action, message: message, status: status, backup: backup)
    }

    static func backupNote(_ backup: String?) -> String {
        backup.map { "; the configuration from before the change is saved at \($0)" } ?? ""
    }

    private struct Change { var error: String?; var backup: String?; var note = "" }

    /// Our entry, in the order it is written: an owned entry's `type` (if any) is kept.
    private func ourEntry(type: String? = nil) -> JSONText {
        var pairs: [JSONText.Pair] = []
        if let type { pairs.append(.init(key: "type", value: .string(type))) }
        pairs += [.init(key: "command", value: .string(binaryPath)), .init(key: "args", value: .array([.string("mcp")])),
                  .init(key: "env", value: .object([.init(key: Self.marker.key, value: .string(Self.marker.value))]))]
        return .object(pairs)
    }

    static func changedMessage(_ now: RegistrationEntry?) -> String {
        "the aistats entry changed after it was checked (now: \(now.map { "\($0.summary); entry \($0.fingerprint)" } ?? "none")); left unchanged"
    }

    /// Antigravity / Claude Desktop / Cursor: one locked, checked edit of `mcpServers.aistats`.
    private func changeJSON(_ target: AgentTarget, expected: RegistrationEntry?, install: Bool) -> Change {
        let url = environment.configURL(target)
        do {
            let r = try JSONConfigEditor.edit(url, lockDirectory: environment.lockDirectory, backups: backups(target)) { current, source in
                // Decide on exactly the bytes read under the lock: they must hold the entry that was checked.
                let entry = current.map { RegistrationEntry.fromJSONConfig($0, source: source) }
                guard entry == expected else { throw ConfigError(Self.changedMessage(entry)) }
                switch classify(entry) {
                case .installed: return install ? .keep : .remove
                case .notInstalled: return install ? .set(ourEntry()) : .keep
                case .pathUpdateNeeded:
                    guard install else { return .remove }
                    // An owned entry has nothing but command, args ["mcp"], the marker and maybe `"type": "stdio"`;
                    // keep its type, point it here.
                    return .set(ourEntry(type: (current as? [String: Any])?["type"] as? String))
                case .nameConflict(let other):
                    // Only reached for a confirmed replace (install checked the fingerprint against `expected`).
                    guard install else { throw ConfigError("the aistats entry is not ours (\(other)); left unchanged") }
                    return .set(ourEntry())
                case .checkFailed(let why): throw ConfigError(why)
                case .agentNotFound: return .keep
                }
            }
            let note = r.changed && r.target.path != url.path ? " (edited \(r.target.path), the file \(url.lastPathComponent) links to)" : ""
            return Change(error: nil, backup: r.backup?.path, note: note)
        } catch {
            return Change(error: "\(error)", backup: nil)
        }
    }

    /// Claude Code, Codex: their own CLI writes the config. Right before it runs, the config's bytes
    /// are read once, the entry is re-checked on exactly those bytes, and those bytes are the backup.
    private func changeWithCLI(_ target: AgentTarget, expected: RegistrationEntry?, install: Bool) -> Change {
        let url = environment.configURL(target)
        let snapshot: Data?
        do {
            let current: RegistrationEntry?
            if target == .codex {
                // Codex reads its own config: the bytes it judged (unchanged around it) are the ones we keep.
                (current, snapshot) = try readCodex(url)
            } else {
                snapshot = try Self.readConfigData(url)
                current = try entry(from: snapshot, name: url.lastPathComponent)
            }
            guard current == expected else { return Change(error: Self.changedMessage(current)) }
        } catch {
            return Change(error: "could not re-read the configuration: \(error); left unchanged")
        }
        var backupURL: URL?
        if let snapshot {
            do { backupURL = try backups(target).create(contents: snapshot, name: url.lastPathComponent) } catch {
                return Change(error: "could not back up \(url.lastPathComponent): \(error); left unchanged")
            }
        }
        let backup = backupURL?.path
        beforeCLIChange?(target)
        let saved = Self.backupNote(backup)
        func now() -> String {
            do { return try readEntry(target, url: url).map { "entry now: \($0.summary)" } ?? "no aistats entry now" } catch {
                return "the aistats entry could not be read back"
            }
        }
        if !install {
            do { try remove(target) } catch { return Change(error: "\(error); \(now())\(saved)", backup: backup) }
            backups(target).prune(except: backupURL)
            return Change(error: nil, backup: backup)
        }
        // Codex overwrites an existing name in one write; Claude refuses, so remove first.
        if target == .claudeCode, expected != nil {
            do { try remove(target) } catch { return Change(error: "\(error); \(now())\(saved)", backup: backup) }
        }
        do {
            try add(target)
            backups(target).prune(except: backupURL)
            return Change(error: nil, backup: backup)
        } catch {
            let addError = "\(error)"
            let after = try? readEntry(target, url: url)
            guard let old = expected else { return Change(error: "\(addError); \(now())\(saved)", backup: backup) }
            if after == old { return Change(error: "\(addError); the previous entry is unchanged", backup: backup) }
            guard target == .claudeCode else { return Change(error: "\(addError); \(now())\(saved)", backup: backup) }
            // Claude: we removed the entry; put back exactly what the file held (any entry type).
            let json = String(decoding: old.source ?? old.raw, as: UTF8.self)
            let restoreError: String?
            do { try runCLI(target, ["mcp", "add-json", "--scope", "user", Self.serverName, json]); restoreError = nil } catch {
                restoreError = "\(error)"
            }
            let restored = try? readEntry(target, url: url)
            if let restored, restored == old || restored.sameSettings(old) {
                // Claude Code rewrites its file in its own format; same settings is a full restore.
                return Change(error: "\(addError); the previous entry was restored", backup: backup)
            }
            if restoreError == nil, let restored {
                return Change(error: "\(addError); the previous entry was put back without some settings Claude Code didn't accept (differs in: \(Self.differences(old, restored)))\(saved)",
                              backup: backup)
            }
            return Change(error: "\(addError); restoring the previous entry failed\(restoreError.map { " (\($0))" } ?? ""); \(now())\(saved)",
                          backup: backup)
        }
    }

    /// Top-level fields of two entries that differ (added, removed or changed), for messages.
    static func differences(_ a: RegistrationEntry, _ b: RegistrationEntry) -> String {
        let x = (try? JSONSerialization.jsonObject(with: a.raw) as? [String: Any]) ?? [:]
        let y = (try? JSONSerialization.jsonObject(with: b.raw) as? [String: Any]) ?? [:]
        let keys = Set(x.keys).union(y.keys).filter { k in
            guard let u = x[k], let v = y[k] else { return true }
            return !(u as AnyObject).isEqual(v)
        }
        return keys.isEmpty ? "formatting only" : keys.sorted().joined(separator: ", ")
    }

    private func add(_ target: AgentTarget) throws {
        let name = Self.serverName, marker = "\(Self.marker.key)=\(Self.marker.value)"
        switch target {
        case .claudeCode: try runCLI(target, ["mcp", "add", "--scope", "user", name, "-e", marker, "--", binaryPath, "mcp"])
        case .codex: try runCLI(target, ["mcp", "add", name, "--env", marker, "--", binaryPath, "mcp"])
        case .antigravity, .claudeDesktop, .cursor: break
        }
    }

    private func remove(_ target: AgentTarget) throws {
        let name = Self.serverName
        switch target {
        case .claudeCode: try runCLI(target, ["mcp", "remove", name, "--scope", "user"])
        case .codex: try runCLI(target, ["mcp", "remove", name])
        case .antigravity, .claudeDesktop, .cursor: break
        }
    }

    @discardableResult
    private func runCLI(_ target: AgentTarget, _ args: [String], check: Bool = true) throws -> Subprocess.Result {
        guard let cli = target.cliName, let path = environment.findCLI(cli) else {
            throw ConfigError("\(target.displayName) command not found")
        }
        let r = try Subprocess.run(path, args, environment: environment.childEnvironment, timeout: environment.timeout,
                                   currentDirectory: environment.home)
        guard !check || r.succeeded else {
            if r.timedOut { throw ConfigError("\(cli) timed out after \(Int(environment.timeout)) s") }
            throw ConfigError("\(cli) failed: \(Self.firstLine(r))")
        }
        return r
    }

    static func firstLine(_ r: Subprocess.Result) -> String {
        if r.timedOut { return "timed out" }
        let line = (r.stderr + "\n" + r.stdout).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("WARNING:") } ?? "exit status \(r.status)"
        return String(line.prefix(200))
    }

    static func isOurs(_ state: RegistrationState) -> Bool {
        if case .installed = state { return true }
        if case .pathUpdateNeeded = state { return true }
        return false
    }

    /// Serializes changes to one agent's config across AIStats processes (app + CLI).
    private func withProcessLock(_ target: AgentTarget, _ body: () -> RegistrationOutcome) -> RegistrationOutcome {
        let path = environment.configURL(target).path
        let lockURL = environment.lockDirectory.appendingPathComponent("\(target.rawValue)-\(RegistrationEntry.fingerprint(Data(path.utf8))).lock")
        let lock: FileLock
        do { lock = try FileLock(lockURL, timeout: environment.timeout) } catch {
            let status = RegistrationStatus(target: target, state: .checkFailed("\(error)"), location: path,
                                            cliPath: target.cliName.flatMap { environment.findCLI($0) })
            return outcome(target, false, "failed", "\(error)", status)
        }
        defer { lock.release() }
        return body()
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

