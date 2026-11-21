import Foundation

final class SnapshotDelta {
    typealias Object = [String: Any]
    private struct Base {
        var cursor: String
        var issued: TimeInterval
        var fields: Object
    }
    private let namespace = "s-" + UUID().uuidString + "-"
    private var serial: UInt64 = 0
    private var bases: [Base] = []

    func response(_ current: Object, since: String?, now: TimeInterval,
                  fits: (Object) throws -> Bool) throws -> Object {
        serial += 1
        let cursor = namespace + String(serial)
        bases.removeAll { now - $0.issued >= 600 }
        let base = bases.first { $0.cursor == since }
        var next = current
        var out = current
        if since != nil { out["delta"] = base != nil }
        out["cursor"] = cursor
        var unchanged: [String] = []
        if let base {
            let oldMissing = Set(base.fields["unavailable"] as? [String] ?? [])
            let newMissing = Set(current["unavailable"] as? [String] ?? [])
            out["unavailable"] = newMissing.sorted()
            for section in ["cpu", "memory", "disk", "network", "battery", "thermalState", "topProcesses"] {
                let relevant: Set<String>
                switch section {
                case "memory": relevant = ["memory", "memoryPressure", "swap"]
                case "network": relevant = ["network", "networkCounters"]
                case "cpu": relevant = ["cpu", "loadAverage"]
                default: relevant = [section]
                }
                if current[section] == nil, base.fields[section] != nil { out[section] = NSNull() }
                guard oldMissing.intersection(relevant) == newMissing.intersection(relevant),
                      Self.close(section: section, old: base.fields[section], new: current[section]) else { continue }
                unchanged.append(section)
                out.removeValue(forKey: section)
                next[section] = base.fields[section]
                if section == "network", let values = current[section] as? Object {
                    let totals = values.filter { ["receivedTotalBytes", "sentTotalBytes"].contains($0.key) }
                    out[section] = totals
                    next[section] = (next[section] as? Object ?? [:]).merging(totals) { _, new in new }
                }
            }
            out["unchanged"] = unchanged
        } else if let since {
            if since.hasPrefix(namespace), let number = UInt64(since.dropFirst(namespace.count)), number > 0, number < serial {
                out["deltaReset"] = "expired"
            } else { out["deltaReset"] = since.hasPrefix("t-") ? "other_target" : "unknown_cursor" }
        }
        while try !fits(out), var rows = out["topProcesses"] as? [Object], !rows.isEmpty {
            rows.removeLast()
            out["topProcesses"] = rows
            out["topProcessesOmitted"] = (out["topProcessesOmitted"] as? Int ?? 0) + 1
            next["topProcesses"] = rows
        }
        bases.append(Base(cursor: cursor, issued: now, fields: next))
        if bases.count > 8 { bases.removeFirst() }
        return out
    }

    private static func close(section: String, old: Any?, new: Any?) -> Bool {
        if old == nil && new == nil { return true }
        if let a = old as? NSObject, let b = new as? NSObject, a.isEqual(b) { return true }
        if section == "topProcesses" {
            guard let a = old as? [Object], let b = new as? [Object], a.count == b.count else { return false }
            return zip(a, b).allSatisfy { left, right in
                sameFields(left, right) { field in
                    switch field {
                    case "cpuPercent": return 10
                    case "memoryBytes": return ((left[field] as? NSNumber)?.doubleValue ?? 0) * 0.1
                    default: return 0
                    }
                }
            }
        }
        guard let a = old as? Object, let b = new as? Object else { return false }
        return sameFields(a, b) { field in
            switch section {
            case "cpu":
                if field.hasPrefix("loadAverage") { return 0.5 }
                return field.hasSuffix("Percent") ? 2 : 0
            case "memory":
                if field == "usedPercent" { return 1 }
                return field.hasSuffix("Bytes") ? ((a["totalBytes"] as? NSNumber)?.doubleValue ?? 0) * 0.01 : 0
            case "disk": return field.hasPrefix("available") ? 1_073_741_824 : 0
            case "network":
                if field.hasSuffix("TotalBytes") { return .infinity }
                return field.hasSuffix("BytesPerSecond") ? max(65536, ((a[field] as? NSNumber)?.doubleValue ?? 0) * 0.25) : 0
            case "battery": return field == "percent" ? 2 : field == "minutesRemaining" ? 15 : 0
            default: return 0
            }
        }
    }

    private static func sameFields(_ a: Object, _ b: Object, tolerance: (String) -> Double) -> Bool {
        guard a.keys == b.keys else { return false }
        return a.keys.allSatisfy { key in
            guard let left = a[key] as? NSObject, let right = b[key] as? NSObject else { return false }
            if left.isEqual(right) { return true }
            let allowed = tolerance(key)
            guard allowed > 0, let x = left as? NSNumber, let y = right as? NSNumber else { return false }
            return abs(x.doubleValue - y.doubleValue) <= allowed
        }
    }
}
