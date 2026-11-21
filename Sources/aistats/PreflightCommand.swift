import CryptoKit
import Darwin
import Foundation
import StatsCore

func preflight(_ raw: [String]) throws {
    let args = try Arguments(raw[...], valueOptions: ["agent"])
    guard args.flags.isSubset(of: ["json"]), Set(args.options.keys).isSubset(of: ["agent"]) else {
        throw CLIError("preflight accepts --agent claude-code|codex and --json")
    }
    if let agent = args.options["agent"] {
        guard ["claude-code", "codex"].contains(agent) else {
            throw CLIError("no supported non-blocking pre-execution channel for this agent")
        }
        var session: String?
        if isatty(STDIN_FILENO) == 0 {
            var bytes = Data()
            let deadline = Proc.nowNs() + 20_000_000
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while bytes.count < 65536, Proc.nowNs() < deadline {
                let ready = poll(&fd, 1, 2)
                if ready == 0 { continue }
                if ready < 0 { break }
                let count = read(STDIN_FILENO, &buffer, min(buffer.count, 65536 - bytes.count))
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            if !bytes.isEmpty {
                guard let input = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
                    throw CLIError("invalid hook input")
                }
                session = input["session_id"] as? String
            }
        }
        let report = Preflight.measure()
        if report.readiness == "caution" {
            if let session, !session.isEmpty, try recentlyEmitted(session: session, report: report) { return }
            let value = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "additionalContext": report.context]]
            print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        }
        return
    }
    let report = Preflight.measure()
    if args.flags.contains("json") { try printJSON(report) }
    else {
        print("Readiness: " + report.readiness)
        for signal in report.signals { print(signal.detail) }
    }
    exit(report.readiness == "caution" ? 3 : report.readiness == "unknown" ? 4 : 0)
}

private struct HookEmission: Codable {
    var at: Date
    var metrics: [String]
}

private func recentlyEmitted(session: String, report: Preflight) throws -> Bool {
    let dir = AIStatsPaths.home
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = dir.appendingPathComponent("preflight-sessions.json")
    let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw CLIError("cannot open preflight session state") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(),
          fchmod(fd, 0o600) == 0 else { throw CLIError("invalid preflight session state file") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
    let data = try handle.read(upToCount: 65536) ?? Data()
    var entries = (try? JSONDecoder().decode([String: HookEmission].self, from: data)) ?? [:]
    entries = entries.filter { (0..<300).contains(report.observedAt.timeIntervalSince($0.value.at)) }
    let key = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
    let metrics = report.signals.map(\.metric).sorted()
    if entries[key]?.metrics == metrics { return true }
    if entries.count >= 128, let oldest = entries.min(by: { $0.value.at < $1.value.at }) { entries.removeValue(forKey: oldest.key) }
    entries[key] = HookEmission(at: report.observedAt, metrics: metrics)
    let updated = try JSONEncoder().encode(entries)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: updated)
    try handle.truncate(atOffset: UInt64(updated.count))
    return false
}
