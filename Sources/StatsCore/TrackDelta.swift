import CryptoKit
import Darwin
import Foundation

enum TrackDelta {
    typealias Object = [String: Any]

    private static let sections = [
        ("config", ["selector", "match", "includeChildren", "scope", "startedAt", "endsAt", "durationSeconds", "intervalSeconds", "argsFilter"]),
        ("instances", ["instances", "instancesOmitted"]), ("members", ["members", "membersOmitted"]),
        ("spawn", ["spawn"]), ("notes", ["notes", "notesOmitted"])
    ]

    private struct Base: Codable {
        var cursor: String
        var sections: [String: String]
        var events: Int
        var spikes: Int
        var spikeDigests: [Int: String]
    }

    private static func digest(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    static func directory(_ id: String, home: URL) -> URL {
        TrackManager.tracksDir(home).appendingPathComponent(id + ".cursors", isDirectory: true)
    }

    static func response(report: TrackReport, home: URL, since: String?,
                         measure: @escaping (Object) throws -> Int) throws -> Object {
        let id = report.trackId
        guard TrackManager.isValidID(id) else { throw ToolError("Invalid track identity") }
        return try withStoreLock(home, exclusive: false) {
            guard FileManager.default.fileExists(atPath: TrackManager.tracksDir(home).appendingPathComponent(id + ".json").path) else {
                throw TrackError.notFound(id)
            }
            return try storedResponse(id: id, report: report, home: home, since: since, measure: measure)
        }
    }

    static func withStoreLock<T>(_ home: URL, exclusive: Bool, _ body: () throws -> T) throws -> T {
        let fd = open(TrackManager.tracksDir(home).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ToolError("Could not open track storage") }
        defer { close(fd) }
        guard flock(fd, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw ToolError("Could not lock track storage") }
        return try body()
    }

    private static func storedResponse(id: String, report: TrackReport, home: URL, since: String?,
                                       measure: @escaping (Object) throws -> Int) throws -> Object {
        let directory = directory(id, home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ToolError("Could not open track cursor index") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ToolError("Could not lock track cursor index") }
        let index = directory.appendingPathComponent("index.json")
        let decoder = JSONDecoder()
        var bases: [Base] = []
        if FileManager.default.fileExists(atPath: index.path) {
            let data = try Data(contentsOf: index)
            bases = (try? decoder.decode([Base].self, from: data)) ?? []
        }
        let base = bases.first { $0.cursor == since }
        let target = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let prefix = "t-" + target + "."
        let cursor = prefix + UUID().uuidString
        func project(_ r: TrackReport) throws -> (Object, Base) {
            var out = try JSONSerialization.jsonObject(with: MCPServer.encoder.encode(r)) as! Object
            out["cursor"] = cursor
            var next = Base(cursor: cursor, sections: [:], events: r.events.count + (r.eventsOmitted ?? 0),
                            spikes: r.spikes.count + (r.spikesOmitted ?? 0), spikeDigests: [:])
            var unchanged: [String] = []
            for (section, keys) in sections {
                let fields = out.filter { keys.contains($0.key) }
                let hash = try digest(fields)
                next.sections[section] = hash
                if let base, base.sections[section] != hash, fields.isEmpty, (section == "notes" || section == "spawn") { out[keys[0]] = NSNull() }
                if base?.sections[section] == hash {
                    unchanged.append(section)
                    for key in keys { out.removeValue(forKey: key) }
                }
            }
            let spikes = out["spikes"] as? [Object] ?? []
            var changedSpikes: [Object] = []
            for (i, spike) in spikes.enumerated() {
                let ordinal = next.spikes - spikes.count + i + 1
                let hash = try digest(spike)
                next.spikeDigests[ordinal] = hash
                if ordinal > (base?.spikes ?? 0) || base?.spikeDigests[ordinal] != hash { changedSpikes.append(spike) }
            }
            if let base {
                out["delta"] = true
                let events = out["events"] as? [Object] ?? []
                let added = max(0, next.events - base.events)
                if added == 0 {
                    unchanged.append("events")
                    out.removeValue(forKey: "events")
                    out.removeValue(forKey: "eventsOmitted")
                } else {
                    let recent = Array(events.suffix(added))
                    out["events"] = recent
                    out["eventsOmitted"] = added > recent.count ? added - recent.count : nil
                }
                let missing = max(0, next.spikes - spikes.count - base.spikes)
                out["spikesOmitted"] = missing == 0 ? nil : missing
                if changedSpikes.isEmpty && missing == 0 {
                    unchanged.append("spikes")
                    out.removeValue(forKey: "spikes")
                } else { out["spikes"] = changedSpikes }
                out["unchanged"] = unchanged
            } else if let since {
                out["delta"] = false
                if since.hasPrefix(prefix), UUID(uuidString: String(since.dropFirst(prefix.count))) != nil {
                    out["deltaReset"] = "expired"
                } else if since.hasPrefix("s-") || since.hasPrefix("t-") {
                    out["deltaReset"] = "other_target"
                } else { out["deltaReset"] = "unknown_cursor" }
            }
            return (out, next)
        }
        let trimmed = report.fitting(maxBytes: MCPServer.maxResponseBytes) { row in
            (try? measure(project(row).0)) ?? Int.max
        }
        let (output, next) = try project(trimmed)
        guard try measure(output) <= MCPServer.maxResponseBytes else { throw ToolError("Track cursor result exceeds budget") }
        bases = Array(bases.suffix(7)) + [next]
        try JSONEncoder().encode(bases).write(to: index, options: .atomic)
        guard chmod(index.path, 0o600) == 0 else { throw ToolError("Could not protect track cursor index") }
        return output
    }
}
