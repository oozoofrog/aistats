import Foundation

public struct SimulatorUsage: Encodable, Sendable {
    public struct Member: Encodable, Sendable {
        public var pid: Int32
        public var name: String
        public var cpuPercent: Double
        public var memoryBytes: UInt64
    }
    public struct Device: Encodable, Sendable {
        public var rootPid: Int32
        public var startToken: String?
        public var bootedAt: Date
        public var processCount: Int
        public var cpuPercent: Double?
        public var memoryBytes: UInt64?
        public var partial: [String]
        public var top: [Member]
        public var topOmitted: Int?
        public var ownerUnknown = "no_source"
    }
    public var observedAt: Date
    public var bootedCount: Int
    public var devices: [Device]
    public var truncated = false
    public var devicesOmitted = 0

    public static func measure(store: ActivityStore) -> Self {
        Self(ProcessTree.measure(store: store, deviceRoots: true), token: directToken)
    }

    /// Reads the start token of a Device Root that has no verified sample row, for example a root that
    /// started after the sample. The kernel start time must match the table entry before and after the read.
    static func directToken(_ node: ProcessTree.Node) -> String? {
        guard Proc.matches(node.pid, startSec: node.startSec, startUsec: node.startUsec), let usage = Proc.usage(node.pid),
              Proc.matches(node.pid, startSec: node.startSec, startUsec: node.startUsec) else { return nil }
        return String(usage.start)
    }

    /// `token` gives the start token of a Device Root whose sample row is missing; nil omits it (SIM-051).
    public init(_ tree: ProcessTree, token: (ProcessTree.Node) -> String? = { _ in nil }) {
        observedAt = tree.observedAt
        bootedCount = tree.deviceRoots.count
        let boundary = tree.deviceRoots.union(tree.agents)
        devices = tree.deviceRoots.compactMap { pid in
            guard let root = tree.nodes[pid] else { return nil }
            var members: [Int32] = [], pending = [pid]
            while let next = pending.popLast() {
                members.append(next)
                pending += (tree.children[next] ?? []).filter { !boundary.contains($0) }
            }
            // A member needs a readable CPU reading (SIM-009). A paired CPU reading implies a sample row, so memory is readable too.
            let top = members.compactMap { tree.nodes[$0] }.compactMap { node -> Member? in
                guard let cpu = node.own.cpuPercent, let memory = node.own.memoryBytes else { return nil }
                return Member(pid: node.pid, name: node.name, cpuPercent: cpu, memoryBytes: memory)
            }.sorted { $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent }.prefix(3)
            // Round the sum: the summation order follows dictionary order, so unrounded low bits can differ per run.
            return Device(rootPid: pid, startToken: root.startToken ?? token(root), bootedAt: root.started, processCount: root.count,
                          cpuPercent: root.total.cpuPercent.map(Proc.round1), memoryBytes: root.total.memoryBytes,
                          partial: root.total.partial.filter { $0 != OriginMetric.disk.rawValue }, top: Array(top))
        }.sorted {
            let a = $0.cpuPercent ?? -1, b = $1.cpuPercent ?? -1
            return a == b ? $0.rootPid < $1.rootPid : a > b
        }
    }

    /// One Trimming step. `top` members go first, so every Device Root keeps its row and totals (RSZ-008):
    /// the last member of the longest list, the lowest-CPU device first on a tie. Rows go only when no
    /// member is left. No string is shortened, because list Trimming always makes the result fit (RSZ-009).
    mutating func trim() -> Bool {
        if let i = devices.indices.reversed().max(by: { devices[$0].top.count < devices[$1].top.count }), !devices[i].top.isEmpty {
            devices[i].top.removeLast()
            devices[i].topOmitted = (devices[i].topOmitted ?? 0) + 1
        } else if !devices.isEmpty {
            devices.removeLast()
            devicesOmitted += 1
        } else {
            return false
        }
        truncated = true
        return true
    }

    public var summaryLine: String {
        bootedCount == 0 ? "No booted simulator devices." : "\(bootedCount) booted simulator device\(bootedCount == 1 ? "" : "s")."
    }

    public func text() -> String {
        var lines = [summaryLine]
        for d in devices {
            let cpu = d.cpuPercent.map { (d.partial.contains("cpu") ? "≥" : "") + String(format: "%.1f%%", $0) } ?? "—"
            let mem = d.memoryBytes.map { (d.partial.contains("memory") ? "≥" : "") + Format.bytes($0) } ?? "—"
            lines.append("launchd_sim(\(d.rootPid))  \(cpu)  \(mem)  \(d.processCount) processes  booted \(ISO8601DateFormatter().string(from: d.bootedAt))")
            lines += d.top.map { "  ├─ \($0.name)(\($0.pid))  " + String(format: "%.1f%%", $0.cpuPercent) + "  " + Format.bytes($0.memoryBytes) }
        }
        if devicesOmitted > 0 { lines.append("+\(devicesOmitted) more") }
        return lines.joined(separator: "\n")
    }
}
