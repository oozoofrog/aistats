import Foundation

/// One point-in-time reading of the machine. Field names carry their units so
/// agents can read the JSON without extra documentation.
public struct Snapshot: Codable, Sendable {
    public struct CPU: Codable, Sendable {
        public var usagePercent: Double
        public var userPercent: Double
        public var systemPercent: Double
        public var logicalCores: Int
        public var loadAverage1m: Double
        public var loadAverage5m: Double
        public var loadAverage15m: Double
    }

    public struct Memory: Codable, Sendable {
        public var totalBytes: UInt64
        public var usedBytes: UInt64
        public var appBytes: UInt64
        public var wiredBytes: UInt64
        public var compressedBytes: UInt64
        public var cachedBytes: UInt64
        public var swapUsedBytes: UInt64
        /// "normal", "warning", "critical" or "unknown" (kernel memory pressure level).
        public var pressure: String
        public var usedPercent: Double {
            totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
        }

        enum CodingKeys: String, CodingKey {
            case totalBytes, usedBytes, appBytes, wiredBytes, compressedBytes, cachedBytes, swapUsedBytes, pressure, usedPercent
        }

        public init(totalBytes: UInt64, usedBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64,
                    compressedBytes: UInt64, cachedBytes: UInt64, swapUsedBytes: UInt64, pressure: String) {
            self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.appBytes = appBytes
            self.wiredBytes = wiredBytes; self.compressedBytes = compressedBytes; self.cachedBytes = cachedBytes
            self.swapUsedBytes = swapUsedBytes; self.pressure = pressure
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(totalBytes: try c.decode(UInt64.self, forKey: .totalBytes),
                      usedBytes: try c.decode(UInt64.self, forKey: .usedBytes),
                      appBytes: try c.decode(UInt64.self, forKey: .appBytes),
                      wiredBytes: try c.decode(UInt64.self, forKey: .wiredBytes),
                      compressedBytes: try c.decode(UInt64.self, forKey: .compressedBytes),
                      cachedBytes: try c.decode(UInt64.self, forKey: .cachedBytes),
                      swapUsedBytes: try c.decode(UInt64.self, forKey: .swapUsedBytes),
                      pressure: try c.decode(String.self, forKey: .pressure))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(totalBytes, forKey: .totalBytes)
            try c.encode(usedBytes, forKey: .usedBytes)
            try c.encode(appBytes, forKey: .appBytes)
            try c.encode(wiredBytes, forKey: .wiredBytes)
            try c.encode(compressedBytes, forKey: .compressedBytes)
            try c.encode(cachedBytes, forKey: .cachedBytes)
            try c.encode(swapUsedBytes, forKey: .swapUsedBytes)
            try c.encode(pressure, forKey: .pressure)
            try c.encode((usedPercent * 10).rounded() / 10, forKey: .usedPercent)
        }
    }

    public struct Disk: Codable, Sendable {
        public var mountPath: String
        public var totalBytes: UInt64
        /// Free blocks reported by the file system right now.
        public var availableBytes: UInt64
        /// Space macOS can make available for important work (includes purgeable data).
        public var availableForImportantUsageBytes: UInt64?
    }

    public struct Network: Codable, Sendable {
        public var receivedBytesPerSecond: Double
        public var sentBytesPerSecond: Double
        public var receivedTotalBytes: UInt64
        public var sentTotalBytes: UInt64
        public var interfaces: [String]
    }

    public struct Battery: Codable, Sendable {
        public var percent: Int
        public var isCharging: Bool
        /// "AC Power" or "Battery Power".
        public var powerSource: String
        public var minutesRemaining: Int?
    }

    public var timestamp: Date
    public var sampleIntervalSeconds: Double
    public var cpu: CPU
    public var memory: Memory
    public var disk: Disk?
    public var network: Network
    public var battery: Battery?
    public var uptimeSeconds: Int
    /// "nominal", "fair", "serious" or "critical".
    public var thermalState: String
    public var topProcesses: [ProcessUsage]?
    /// Metrics that could not be read in this sample ("cpu", "memory", "memoryPressure", "swap",
    /// "network", "disk"). Their fields hold placeholders and must not be read as real zeros.
    public var unavailable: [String]?

    public func isAvailable(_ metric: String) -> Bool { !(unavailable ?? []).contains(metric) }
}

public struct ProcessUsage: Codable, Sendable, Hashable {
    public var startToken: String?
    public var ppid: Int32?
    public var pid: Int32
    public var name: String
    /// Share of one core; can exceed 100 for multi-threaded processes (same as Activity Monitor).
    public var cpuPercent: Double
    /// Physical footprint, the "Memory" column in Activity Monitor.
    public var memoryBytes: UInt64
}

public enum ProcessSort: String, Sendable, CaseIterable {
    case cpu, memory
}

public enum Format {
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(value) B" : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond))) + "/s"
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    public static func duration(_ seconds: Int) -> String {
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

public extension Snapshot {
    /// Compact, human-readable multi-line summary used by the CLI and MCP tools.
    var summary: String {
        var lines: [String] = []
        let load = "load \(String(format: "%.2f %.2f %.2f", cpu.loadAverage1m, cpu.loadAverage5m, cpu.loadAverage15m)) on \(cpu.logicalCores) cores"
        if isAvailable("cpu") {
            lines.append("CPU \(Format.percent(cpu.usagePercent)) (user \(Format.percent(cpu.userPercent)), system \(Format.percent(cpu.systemPercent))), \(load)")
        } else {
            lines.append("CPU usage could not be measured, \(load)")
        }
        let pressure = isAvailable("memoryPressure") ? memory.pressure : "unknown"
        let swap = isAvailable("swap") ? Format.bytes(memory.swapUsedBytes) : "unknown"
        if isAvailable("memory") {
            lines.append("Memory \(Format.bytes(memory.usedBytes)) / \(Format.bytes(memory.totalBytes)) (\(Format.percent(memory.usedPercent))), pressure \(pressure), swap \(swap)")
        } else {
            lines.append("Memory usage could not be read (total \(Format.bytes(memory.totalBytes))), pressure \(pressure), swap \(swap)")
        }
        if let disk, isAvailable("disk") {
            lines.append("Disk \(disk.mountPath): \(Format.bytes(disk.availableBytes)) free of \(Format.bytes(disk.totalBytes))")
        } else {
            lines.append("Disk free space could not be read")
        }
        if isAvailable("network") {
            lines.append("Network ↓ \(Format.rate(network.receivedBytesPerSecond)) ↑ \(Format.rate(network.sentBytesPerSecond))")
        } else {
            lines.append("Network throughput not measured")
        }
        if let battery {
            var s = "Battery \(battery.percent)% on \(battery.powerSource)"
            if battery.isCharging { s += ", charging" }
            if let m = battery.minutesRemaining { s += ", \(m) min remaining" }
            lines.append(s)
        }
        lines.append("Uptime \(Format.duration(uptimeSeconds)), thermal \(thermalState)")
        return lines.joined(separator: "\n")
    }
}
