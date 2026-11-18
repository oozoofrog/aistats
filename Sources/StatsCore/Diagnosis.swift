import Darwin
import Foundation

/// `diagnose_system`: one ~1 s measurement turned into a verdict with a few pieces of evidence.
public struct Diagnosis: Codable, Sendable {
    public struct Evidence: Codable, Sendable {
        public var metric: String
        public var observed: Double
        public var threshold: Double
        public var unit: String
        public var detail: String
    }

    public var purpose: String
    /// "issue_detected", "no_clear_issue" or "insufficient_data".
    public var status: String
    /// heavy_work only: "ready", "caution" or "unknown".
    public var readiness: String?
    public var evidence: [Evidence]
    /// 1, 5 and 15 minute load averages (runnable + running threads); nil if CPU couldn't be read.
    public var loadAverage: [Double]?
    public var topProcesses: [ProcessUsage]
    public var unavailable: [String]?
    public var observedAt: Date
    public var measuredSeconds: Double
    public var scope: String

    public static let cpuBusyPercent = 85.0
    public static let lowDiskBytes: UInt64 = 10 * 1024 * 1024 * 1024
    public static let lowBatteryPercent = 20
    /// Load average (1 min) at or above this many times the logical core count: work is queueing for CPU
    /// even when the busy percentage looks moderate (e.g. many short processes, or threads blocked in the kernel).
    public static let loadPerCore = 2.0

    public var summaryLine: String {
        var s = "\(purpose): \(status.replacingOccurrences(of: "_", with: " "))"
        if let readiness { s += ", readiness \(readiness)" }
        if !evidence.isEmpty { s += " — " + evidence.map(\.detail).joined(separator: "; ") }
        if let p = topProcesses.first { s += String(format: ". Busiest: %@ %.0f%%", p.name, p.cpuPercent) }
        return s
    }

    public static func make(purpose: String, snapshot s: Snapshot, top: [ProcessUsage]) -> Diagnosis {
        var evidence: [(rank: Int, e: Evidence)] = []
        let cpuOK = s.isAvailable("cpu")
        let memOK = s.isAvailable("memory")
        if cpuOK, s.cpu.usagePercent >= cpuBusyPercent {
            var d = String(format: "CPU %.0f%% busy across %d cores", s.cpu.usagePercent, s.cpu.logicalCores)
            if let p = top.first { d += String(format: " (top: %@ %.0f%%)", p.name, p.cpuPercent) }
            evidence.append((2, .init(metric: "cpu", observed: s.cpu.usagePercent, threshold: cpuBusyPercent, unit: "percent", detail: d)))
        }
        let cores = max(1, s.cpu.logicalCores)
        let load1 = s.cpu.loadAverage1m
        if cpuOK, load1 >= loadPerCore * Double(cores) {
            let ratio = load1 / Double(cores)
            evidence.append((ratio >= 2 * loadPerCore ? 1 : 2, .init(
                metric: "loadAverage", observed: (load1 * 100).rounded() / 100, threshold: loadPerCore * Double(cores),
                unit: "runnable threads (1 min average)",
                detail: String(format: "load average %.1f is %.1f× the %d logical cores: work is queueing for CPU", load1, ratio, cores))))
        }
        if s.isAvailable("memoryPressure") {
            let level = ["warning": 1.0, "critical": 2.0][s.memory.pressure]
            if let level {
                evidence.append((level > 1 ? 0 : 3, .init(metric: "memoryPressure", observed: level, threshold: 1, unit: "level (1 warning, 2 critical)",
                                     detail: "memory pressure \(s.memory.pressure), swap \(Format.bytes(s.memory.swapUsedBytes))")))
            }
        }
        let thermal = ["serious": 2.0, "critical": 3.0][s.thermalState]
        if let thermal {
            evidence.append((thermal > 2 ? 0 : 1, .init(metric: "thermal", observed: thermal, threshold: 2, unit: "level (2 serious, 3 critical)",
                                   detail: "thermal state \(s.thermalState): the Mac is throttling")))
        }
        if let d = s.disk {
            let free = d.availableForImportantUsageBytes ?? d.availableBytes
            if free < lowDiskBytes {
                evidence.append((free < lowDiskBytes / 4 ? 0 : 2, .init(metric: "diskFree", observed: Double(free), threshold: Double(lowDiskBytes), unit: "bytes",
                                      detail: "only \(Format.bytes(free)) free on \(d.mountPath)")))
            }
        }
        if let b = s.battery, !b.isCharging, b.powerSource == "Battery Power", b.percent < lowBatteryPercent {
            evidence.append((1, .init(metric: "battery", observed: Double(b.percent), threshold: Double(lowBatteryPercent), unit: "percent",
                                  detail: "on battery at \(b.percent)%")))
        }
        let sorted = evidence.sorted { $0.rank < $1.rank }.prefix(4).map(\.e)
        let status: String
        if !sorted.isEmpty { status = "issue_detected" }
        else if !cpuOK || !memOK { status = "insufficient_data" }
        else { status = "no_clear_issue" }
        var readiness: String?
        if purpose == "heavy_work" {
            // "ready" needs every reading it depends on; a missing one never counts as fine.
            let complete = cpuOK && s.isAvailable("memoryPressure") && s.isAvailable("disk") && s.disk != nil
            readiness = status == "issue_detected" ? "caution" : (complete && status == "no_clear_issue" ? "ready" : "unknown")
        }
        return Diagnosis(purpose: purpose, status: status, readiness: readiness, evidence: Array(sorted),
                         loadAverage: cpuOK ? [s.cpu.loadAverage1m, s.cpu.loadAverage5m, s.cpu.loadAverage15m] : nil,
                         topProcesses: Array(top.prefix(3)), unavailable: s.unavailable, observedAt: s.timestamp,
                         measuredSeconds: s.sampleIntervalSeconds, scope: "current_user")
    }

    /// Measures for about a second and diagnoses.
    public static func run(purpose: String, sampler: SystemSampler = SystemSampler()) -> Diagnosis {
        let snapshot = sampler.measure(interval: 1.0, includeProcesses: true)
        let top = sampler.processCPUIsFresh
            ? sampler.topProcesses(sortedBy: .cpu, limit: 3, from: snapshot.topProcesses ?? []) : []
        return make(purpose: purpose, snapshot: snapshot, top: top)
    }
}

// MARK: - Environment

public struct EnvironmentReport: Codable, Sendable {
    public struct Toolchain: Codable, Sendable {
        public var developerDir: String?
        public var developerDirSource: String?
        public var xcodeVersion: String?
        public var xcodeBuild: String?
        public var commandLineToolsPath: String?
        public var swiftVersion: String?
        public var toolchains: String?
        public var errors: [String]?
        public var checkedAt: Date
    }

    public var macOSVersion: String
    public var macOSBuild: String?
    public var arch: String
    public var chip: String?
    public var rosettaTranslated: Bool?
    public var memoryBytes: UInt64
    public var logicalCores: Int
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var toolchain: Toolchain?

    public var summaryLine: String {
        var s = "macOS \(macOSVersion)\(macOSBuild.map { " (\($0))" } ?? ""), \(chip ?? arch), \(Format.bytes(memoryBytes)) RAM, \(logicalCores) cores"
        if let t = toolchain {
            if let v = t.xcodeVersion { s += ", Xcode \(v)" } else if t.developerDir != nil { s += ", developer dir \(t.developerDir!)" }
            if let v = t.swiftVersion { s += ", Swift \(v)" }
        }
        return s
    }
}

public enum EnvironmentProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var system: EnvironmentReport?
    nonisolated(unsafe) private static var toolchainCache: (key: String, at: Date, value: EnvironmentReport.Toolchain)?
    public static let toolchainTTL: TimeInterval = 300

    public static func collect(includeToolchain: Bool, environment: [String: String] = ProcessInfo.processInfo.environment,
                               cancel: CancelToken? = nil) -> EnvironmentReport {
        lock.lock()
        var report = system ?? readSystem()
        system = report
        lock.unlock()
        if includeToolchain { report.toolchain = toolchain(environment: environment, cancel: cancel) }
        return report
    }

    static func readSystem() -> EnvironmentReport {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var version = sysctlString("kern.osproductversion") ?? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        if version.isEmpty { version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta: Bool? = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 ? translated == 1 : nil
        return EnvironmentReport(
            macOSVersion: version, macOSBuild: sysctlString("kern.osversion"),
            arch: sysctlString("hw.machine") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string"),
            rosettaTranslated: rosetta,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            logicalCores: ProcessInfo.processInfo.activeProcessorCount,
            performanceCores: sysctlInt("hw.perflevel0.logicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.logicalcpu"),
            toolchain: nil)
    }

    /// A cancelled probe stops its subprocesses and is not cached.
    static func toolchain(environment env: [String: String], cancel: CancelToken? = nil) -> EnvironmentReport.Toolchain {
        let key = "\(env["DEVELOPER_DIR"] ?? "")|\(env["TOOLCHAINS"] ?? "")"
        lock.lock()
        if let c = toolchainCache, c.key == key, Date().timeIntervalSince(c.at) < toolchainTTL {
            lock.unlock()
            return c.value
        }
        lock.unlock()

        var errors: [String] = []
        var t = EnvironmentReport.Toolchain(checkedAt: Date())
        t.toolchains = env["TOOLCHAINS"].flatMap { $0.isEmpty ? nil : $0 }
        if let dir = env["DEVELOPER_DIR"], !dir.isEmpty {
            t.developerDir = dir; t.developerDirSource = "DEVELOPER_DIR"
        } else if let r = try? Subprocess.run("/usr/bin/xcode-select", ["-p"], environment: env, timeout: 5, cancel: cancel), r.succeeded {
            t.developerDir = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            t.developerDirSource = "xcode-select"
        } else {
            errors.append("no developer directory selected (xcode-select -p failed)")
        }
        if let dir = t.developerDir, dir.hasSuffix("/Contents/Developer") {
            let plist = URL(fileURLWithPath: dir).deletingLastPathComponent().appendingPathComponent("version.plist")
            if let d = NSDictionary(contentsOf: plist) {
                t.xcodeVersion = d["CFBundleShortVersionString"] as? String
                t.xcodeBuild = d["ProductBuildVersion"] as? String
            }
        }
        let clt = "/Library/Developer/CommandLineTools"
        if FileManager.default.fileExists(atPath: clt) { t.commandLineToolsPath = clt }
        do {
            let r = try Subprocess.run("/usr/bin/xcrun", ["swift", "--version"], environment: env, timeout: 15, cancel: cancel)
            let text = r.stdout + "\n" + r.stderr
            if r.succeeded, let line = text.split(separator: "\n").first(where: { $0.contains("Swift version") }) {
                t.swiftVersion = parseSwiftVersion(String(line))
            } else {
                errors.append(r.timedOut ? "xcrun swift --version timed out" : "xcrun swift --version failed (status \(r.status))")
            }
        } catch {
            errors.append("\(error)")
        }
        t.errors = errors.isEmpty ? nil : errors
        if cancel?.isCancelled == true { return t }
        lock.lock()
        toolchainCache = (key, Date(), t)
        lock.unlock()
        return t
    }

    static func parseSwiftVersion(_ line: String) -> String {
        guard let r = line.range(of: "Swift version ") else { return line.trimmingCharacters(in: .whitespaces) }
        let rest = line[r.upperBound...]
        return String(rest.prefix { !$0.isWhitespace })
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buffer)
        return s.isEmpty ? nil : s
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
