import Foundation

public struct Preflight: Encodable {
    public let readiness: String
    public let signals: [Diagnosis.Evidence]
    public let unavailable: [String]?
    public let cpuSource: String
    public let observedAt: Date
    public let elapsedMs: Double

    public static func measure() -> Preflight {
        let start = Proc.nowNs()
        let now = Date()
        let snapshot = SystemSampler().sample()
        let cpu = HistoryStore().recentCPU(now: now)
        return assess(snapshot, cpu: cpu, at: now, start: start)
    }

    static func assess(_ reading: Snapshot, cpu: Double?, at now: Date, start: UInt64) -> Preflight {
        var snapshot = reading
        if let cpu { snapshot.cpu.usagePercent = cpu }
        var missing: [String] = []
        if cpu == nil { missing.append("cpu") }
        if !snapshot.isAvailable("loadAverage") { missing.append("loadAverage") }
        if !snapshot.isAvailable("memoryPressure") { missing.append("memoryPressure") }
        if snapshot.disk == nil { missing.append("diskFree") }
        if snapshot.battery == nil { missing.append("battery") }
        if snapshot.thermalState == "unknown" { missing.append("thermal") }
        let signals = Diagnosis.signals(snapshot: snapshot, top: [], cpuOK: cpu != nil,
                                        loadOK: snapshot.isAvailable("loadAverage"))
        let required: Set<String> = ["loadAverage", "memoryPressure", "diskFree"]
        let readiness = signals.isEmpty ? (required.isDisjoint(with: missing) ? "ready" : "unknown") : "caution"
        return Preflight(readiness: readiness, signals: signals, unavailable: missing.isEmpty ? nil : missing,
                         cpuSource: cpu == nil ? "none" : "app_sample", observedAt: now,
                         elapsedMs: Double(Proc.nowNs() - start) / 1e6)
    }

    public var context: String {
        let readings = signals.map { signal in
            let comparison = ["battery", "diskFree"].contains(signal.metric) ? "<" : ">="
            return "\(signal.metric) \(signal.observed) (\(comparison)\(signal.threshold) \(signal.unit))"
        }.joined(separator: ", ")
        return readings + ". Before heavy work you can use wait_for or aistats wait. For busy processes use diagnose_system or aistats diagnose."
    }
}
