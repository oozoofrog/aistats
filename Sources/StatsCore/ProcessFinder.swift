import Darwin
import Foundation

/// `find_processes`: resolve a pid, name or executable path to live process instances.
public struct FindResult: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public var pid: Int32
        /// From `ri_proc_start_abstime`; changes when the pid is reused. Nil if unreadable.
        public var startToken: String?
        public var name: String?
        public var ppid: Int32?
        public var footprintBytes: UInt64?
        /// Only when the caller matched by path.
        public var path: String?
        /// Fields that could not be read, e.g. ["footprintBytes", "startToken"]; never reported as 0.
        public var unreadable: [String]?
    }

    public var observedAt: Date
    public var scope: String
    public var selector: String
    public var match: String?
    public var processes: [Row]
    public var matched: Int
    public var truncated: Bool
    /// With argsContain: processes that matched by name/path but whose arguments couldn't be read
    /// (they are not in `processes` or `matched`).
    public var argsUnreadable: Int?
    /// For a pid owned by another user, or a scan that failed.
    public var note: String?

    public var summaryLine: String {
        let skipped = argsUnreadable.flatMap { $0 > 0 ? "; \($0) skipped, arguments unreadable" : nil } ?? ""
        if processes.isEmpty { return "No matching process\(note.map { " (\($0))" } ?? "")\(skipped)." }
        let shown = processes.prefix(3).map { r in
            "\(r.name ?? "?") pid \(r.pid)" + (r.footprintBytes.map { " \(Format.bytes($0))" } ?? "")
        }.joined(separator: ", ")
        return "\(matched) match\(matched == 1 ? "" : "es")\(truncated ? " (showing \(processes.count))" : ""): \(shown)\(processes.count > 3 ? ", …" : "")\(skipped)"
    }
}

public enum ProcessFinder {
    public static let maxLimit = 15

    public static func find(_ selector: ProcessSelector, limit: Int = 8, directory: ProcessDirectory = ProcessDirectory()) -> FindResult {
        let limit = min(maxLimit, max(1, limit))
        var result = FindResult(observedAt: Date(), scope: "current_user", selector: selector.kind,
                                match: selector.matchMode, processes: [], matched: 0, truncated: false)
        switch selector {
        case .pid(let pid, let token):
            guard Proc.exists(pid) else { result.note = "no process with this pid"; return result }
            let row = read(pid: pid, ppid: Proc.parent(pid), name: Proc.name(pid), path: nil)
            if row.startToken == nil {
                result.note = "pid exists but its usage can't be read (owned by another user; needs root)"
            } else if let token, row.startToken != token {
                result.note = "pid was reused: startToken differs, the original process exited"
                return result
            }
            result.processes = [row]
            result.matched = 1

        case .name, .path:
            guard let rows = directory.scan(refreshPath: selector.pathRefreshFilter) else {
                result.note = "process table could not be read"
                return result
            }
            let (matches, unreadable) = directory.select(rows, selector)
            if selector.argsContain != nil { result.argsUnreadable = unreadable.count }
            result.matched = matches.count
            var out: [FindResult.Row] = []
            for m in matches {
                out.append(read(pid: m.pid, ppid: m.ppid, name: m.name, path: selector.isPath ? m.path : nil))
            }
            // Biggest first: the process an agent is looking for is usually the heavy one.
            out.sort { ($0.footprintBytes ?? 0, $0.pid) > ($1.footprintBytes ?? 0, $1.pid) }
            result.truncated = out.count > limit
            result.processes = Array(out.prefix(limit))
        }
        return result
    }

    static func read(pid: Int32, ppid: Int32?, name: String?, path: String?) -> FindResult.Row {
        let usage = Proc.usage(pid)
        var unreadable: [String] = []
        if usage == nil { unreadable += ["startToken", "footprintBytes"] }
        if name == nil { unreadable.append("name") }
        if ppid == nil { unreadable.append("ppid") }
        return FindResult.Row(pid: pid, startToken: usage.map { String($0.start) }, name: name, ppid: ppid,
                              footprintBytes: usage?.footprint, path: path,
                              unreadable: unreadable.isEmpty ? nil : unreadable)
    }
}
