import Darwin
import Foundation
import IOKit.ps

/// Reads system metrics. CPU, network and per-process CPU are rates, so they
/// need two readings: the first `sample()` primes the counters and reports zero
/// for those fields. Use `measure(interval:)` for a one-shot reading.
///
/// Not thread-safe; use one instance per queue.
public final class SystemSampler: @unchecked Sendable {
    private static let host = mach_host_self()
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    private var lastCPU: CPUTicks?
    private var lastNet: (rx: UInt64, tx: UInt64)?
    private var netBuffer: [UInt8] = []
    /// Per pid: process start time (detects pid reuse), CPU time at the last sample, cached name.
    private var procCache: [Int32: (start: UInt64, cpuNs: UInt64, name: String)] = [:]
    var readParent: (Int32) -> Int32? = Proc.parent
    private var lastProcTime: UInt64?
    /// Process CPU percentages are only meaningful when the previous process sample is recent.
    public static let maxProcessInterval: Double = 10
    public static let minProcessInterval: Double = 0.25
    /// False when the last `sample(includeProcesses: true)` only primed per-process CPU counters
    /// (first call, or the previous one was more than `maxProcessInterval` seconds ago).
    public private(set) var processCPUIsFresh = false
    private var lastSampleTime: UInt64?

    public let diskPath: String
    /// Battery and disk change slowly and are the costliest reads (IOKit, volume queries).
    /// When > 0 they are re-read at most this often and reused in between.
    public var slowMetricsInterval: TimeInterval
    private var slowCache: (at: UInt64, disk: Snapshot.Disk?, battery: Snapshot.Battery?)?
    /// How many times disk and battery were actually read (the rest came from the cache).
    package private(set) var slowMetricReads = 0
    /// Metrics that failed during the current `sample()`.
    private var failed: [String] = []

    public init(diskPath: String = "/", slowMetricsInterval: TimeInterval = 0) {
        self.diskPath = diskPath
        self.slowMetricsInterval = slowMetricsInterval
    }

    /// Takes a priming reading, waits `interval`, and returns the second reading.
    public func measure(interval: TimeInterval = 0.5, includeProcesses: Bool = false) -> Snapshot {
        _ = sample(includeProcesses: includeProcesses)
        Thread.sleep(forTimeInterval: interval)
        return sample(includeProcesses: includeProcesses)
    }

    public func sample(includeProcesses: Bool = false) -> Snapshot {
        sample { enumerate in includeProcesses ? enumerate() : nil }
    }

    package func sample(enumerateProcesses: (() -> [pid_t]) -> [pid_t]?) -> Snapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastSampleTime.map { Double(now &- $0) / 1e9 } ?? 0
        lastSampleTime = now

        failed = []
        processCPUIsFresh = false
        let processes = enumerateProcesses(Proc.allPids).map { sampleProcesses($0, now: now) }

        let disk: Snapshot.Disk?, battery: Snapshot.Battery?
        if slowMetricsInterval > 0, let c = slowCache, Double(now &- c.at) / 1e9 < slowMetricsInterval {
            disk = c.disk; battery = c.battery
        } else {
            disk = Self.readDisk(at: diskPath); battery = sampleBattery()
            slowCache = (now, disk, battery)
            slowMetricReads += 1
        }
        let cpu = sampleCPU(), memory = sampleMemory(), network = sampleNetwork(elapsed: elapsed)
        if disk == nil { failed.append("disk") }
        return Snapshot(
            timestamp: Date(),
            sampleIntervalSeconds: (elapsed * 1000).rounded() / 1000,
            cpu: cpu,
            memory: memory,
            disk: disk,
            network: network,
            battery: battery,
            uptimeSeconds: Int(ProcessInfo.processInfo.systemUptime),
            thermalState: Self.thermalName(ProcessInfo.processInfo.thermalState),
            topProcesses: processes,
            unavailable: failed.isEmpty ? nil : failed
        )
    }

    /// Processes owned by the current user (others need root), sorted.
    public func topProcesses(sortedBy sort: ProcessSort, limit: Int, from list: [ProcessUsage], includeParent: Bool = true) -> [ProcessUsage] {
        let sorted: [ProcessUsage]
        switch sort {
        case .cpu: sorted = list.sorted { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }
        case .memory: sorted = list.sorted { $0.memoryBytes > $1.memoryBytes }
        }
        // Names are cached per process; re-read them for the few we return, since exec() keeps the
        // pid and start time but changes the program.
        return sorted.prefix(max(0, limit)).compactMap { p in
            var p = p
            let name = Self.processName(p.pid)
            let parent = includeParent ? readParent(p.pid) : nil
            guard let token = p.startToken else { return p }
            guard let usage = Proc.usage(p.pid), String(usage.start) == token else { return nil }
            p.name = name
            p.ppid = parent.flatMap { $0 > 0 ? $0 : nil }
            return p
        }
    }

    // MARK: CPU

    struct CPUTicks { var user, system, idle, nice: UInt64 }

    private func sampleCPU() -> Snapshot.CPU {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var result = Snapshot.CPU(usagePercent: 0, userPercent: 0, systemPercent: 0, logicalCores: cores,
                                  loadAverage1m: Self.round2(load[0]), loadAverage5m: Self.round2(load[1]),
                                  loadAverage15m: Self.round2(load[2]))
        guard let ticks = Self.readCPUTicks() else { failed.append("cpu"); return result }
        defer { lastCPU = ticks }
        // The first reading only primes the counters: report the rate as unavailable, not 0.
        guard let prev = lastCPU else { failed.append("cpu"); return result }
        let user = Double(ticks.user &- prev.user) + Double(ticks.nice &- prev.nice)
        let system = Double(ticks.system &- prev.system)
        let idle = Double(ticks.idle &- prev.idle)
        let total = user + system + idle
        guard total > 0 else { failed.append("cpu"); return result }
        result.userPercent = Self.round1(user / total * 100)
        result.systemPercent = Self.round1(system / total * 100)
        result.usagePercent = Self.round1((user + system) / total * 100)
        return result
    }

    static func readCPUTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    // MARK: Memory

    private func sampleMemory() -> Snapshot.Memory {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(Self.host, HOST_VM_INFO64, $0, &count)
            }
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        if !swapOK { failed.append("swap") }
        let swapUsed: UInt64 = swapOK ? swap.xsu_used : 0
        let pressure = Self.memoryPressure()
        if pressure == "unknown" { failed.append("memoryPressure") }

        guard kr == KERN_SUCCESS else {
            failed.append("memory")
            return Snapshot.Memory(totalBytes: total, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0,
                                   cachedBytes: 0, swapUsedBytes: swapUsed, pressure: pressure)
        }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = (UInt64(stats.external_page_count) + purgeable) * page
        return Snapshot.Memory(totalBytes: total, usedBytes: min(total, app + wired + compressed), appBytes: app,
                               wiredBytes: wired, compressedBytes: compressed, cachedBytes: cached,
                               swapUsedBytes: swapUsed, pressure: pressure)
    }

    static func memoryPressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "unknown" }
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "unknown"
        }
    }

    // MARK: Disk

    static func readDisk(at diskPath: String) -> Snapshot.Disk? {
        var fs = statfs()
        guard statfs(diskPath, &fs) == 0 else { return nil }
        let block = UInt64(fs.f_bsize)
        let url = URL(fileURLWithPath: diskPath)
        let important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let mount = withUnsafePointer(to: fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return Snapshot.Disk(mountPath: mount, totalBytes: UInt64(fs.f_blocks) * block,
                             availableBytes: UInt64(fs.f_bavail) * block,
                             availableForImportantUsageBytes: important.map { UInt64(max(0, $0)) })
    }

    // MARK: Network

    /// Counts physical interfaces only (Ethernet/Wi-Fi `en*`, cellular `pdp_ip*`), so VPN
    /// tunnels and loopback do not double-count traffic.
    /// `buffer` is reused between calls so a periodic reader makes one sysctl call, not a size probe plus a read.
    static func readNetworkCounters(buffer: inout [UInt8]) -> (rx: UInt64, tx: UInt64, interfaces: [String])? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = buffer.count
        if length == 0 || sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) != 0 {
            guard buffer.isEmpty || errno == ENOMEM else { return nil }
            length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
            // Interfaces can appear between the two calls; leave headroom.
            buffer = [UInt8](repeating: 0, count: length + 4096)
            length = buffer.count
            guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var names = Set<String>()
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            rx &+= h2.ifm_data.ifi_ibytes
                            tx &+= h2.ifm_data.ifi_obytes
                            if h2.ifm_data.ifi_ibytes > 0 || h2.ifm_data.ifi_obytes > 0 { names.insert(name) }
                        }
                    }
                }
                offset += messageLength
            }
        }
        return (rx, tx, names.sorted())
    }

    private func sampleNetwork(elapsed: Double) -> Snapshot.Network {
        guard let counters = Self.readNetworkCounters(buffer: &netBuffer) else {
            failed.append(contentsOf: ["network", "networkCounters"])
            lastNet = nil
            return Snapshot.Network(receivedBytesPerSecond: 0, sentBytesPerSecond: 0, receivedTotalBytes: 0,
                                    sentTotalBytes: 0, interfaces: [])
        }
        defer { lastNet = (counters.rx, counters.tx) }
        var inRate = 0.0, outRate = 0.0
        if let prev = lastNet, elapsed > 0 {
            // Counters can reset when an interface goes away; treat a decrease as zero.
            inRate = counters.rx >= prev.rx ? Double(counters.rx - prev.rx) / elapsed : 0
            outRate = counters.tx >= prev.tx ? Double(counters.tx - prev.tx) / elapsed : 0
        } else {
            failed.append("network")
        }
        return Snapshot.Network(receivedBytesPerSecond: inRate.rounded(), sentBytesPerSecond: outRate.rounded(),
                                receivedTotalBytes: counters.rx, sentTotalBytes: counters.tx,
                                interfaces: counters.interfaces)
    }

    // MARK: Battery

    private func sampleBattery() -> Snapshot.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (desc[minutesKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return Snapshot.Battery(percent: Int((Double(current) / Double(max) * 100).rounded()),
                                    isCharging: charging, powerSource: state, minutesRemaining: minutes)
        }
        return nil
    }

    // MARK: Processes

    private func sampleProcesses(_ pids: [pid_t], now: UInt64) -> [ProcessUsage] {
        guard !pids.isEmpty else { return [] }

        let wall = lastProcTime.map { Double(now &- $0) } ?? 0
        // Over a very short window (e.g. a refresh right after the timer fired) a few
        // milliseconds of CPU read as huge percentages, so such readings are not "fresh".
        processCPUIsFresh = wall >= Self.minProcessInterval * 1e9 && wall <= Self.maxProcessInterval * 1e9
        var next: [Int32: (start: UInt64, cpuNs: UInt64, name: String)] = [:]
        next.reserveCapacity(procCache.count)
        var result: [ProcessUsage] = []
        for pid in pids {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            guard ok else { continue } // other users' processes need root
            // rusage CPU times are in Mach absolute time units.
            let cpuNs = (info.ri_user_time &+ info.ri_system_time) &* Self.timebase.numer / Self.timebase.denom
            let start = info.ri_proc_start_abstime
            let cached = procCache[pid].flatMap { $0.start == start ? $0 : nil } // nil if the pid was reused
            let name = cached?.name ?? Self.processName(pid)
            next[pid] = (start, cpuNs, name)
            var percent = 0.0
            if processCPUIsFresh, let prev = cached?.cpuNs, cpuNs >= prev {
                percent = Double(cpuNs - prev) / wall * 100
            }
            result.append(ProcessUsage(startToken: start == 0 ? nil : String(start), pid: pid, name: name, cpuPercent: Self.round1(percent),
                                       memoryBytes: info.ri_phys_footprint))
        }
        procCache = next
        lastProcTime = now
        return result
    }

    static func processName(_ pid: pid_t) -> String {
        Proc.name(pid) ?? "pid \(pid)"
    }

    // MARK: Helpers

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}
