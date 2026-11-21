#!/usr/bin/env swift
import Darwin
import Foundation

// Set AISTATS_CPU_MARKERS=1 on the target process and redirect its stderr to --markers.
// Prepare the isolated copies, signed builds, and input schedule from SDD 0001 before running.
let usage = """
Usage: scripts/measure-cpu.swift PID --scenario closed|window|popover|both --markers FILE
       --revision REV --display-scale SCALE --power-mode MODE [--baseline]
       [--workload LABEL] [--open-command COMMAND] [--smoke]
Open scenarios run COMMAND via /bin/sh immediately after the first reading.
The marker log must record a slow-sample and, for open scenarios, an open marker
within 20 ms of the first reading and a redesign boot marker in the first interval.
The default capture uses a 10 s warmup and sixty 1 s intervals. Smoke uses two
intervals without a warmup or budget verdict. Output is JSON, even on rejection.
"""

struct Options {
    var pid: pid_t
    var scenario = "closed"
    var markers: String?
    var command: String?
    var workload: String?
    var revision: String?
    var displayScale: Double?
    var powerMode: String?
    var baseline = false
    var smoke = false

    init?(_ arguments: [String]) {
        guard let first = arguments.first, let pid = pid_t(first), pid > 0 else { return nil }
        self.pid = pid
        var args = arguments.dropFirst().makeIterator()
        while let option = args.next() {
            switch option {
            case "--scenario":
                guard let value = args.next(), ["closed", "window", "popover", "both"].contains(value) else { return nil }
                scenario = value
            case "--markers": markers = args.next()
            case "--open-command": command = args.next()
            case "--workload": workload = args.next()
            case "--revision": revision = args.next()
            case "--display-scale": displayScale = args.next().flatMap(Double.init)
            case "--power-mode": powerMode = args.next()
            case "--baseline": baseline = true
            case "--smoke": smoke = true
            default: return nil
            }
        }
        if !smoke {
            guard markers != nil, revision != nil, let displayScale, displayScale.isFinite, displayScale > 0, powerMode != nil,
                  scenario == "closed" || command != nil else { return nil }
            guard scenario != "closed" || command == nil else { return nil }
        }
    }
}

struct Identity: Equatable, Encodable {
    let seconds: UInt64
    let microseconds: UInt64

    init?(_ pid: pid_t) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }
}

struct Reading: Encodable {
    let time: UInt64
    let cpu: UInt64

    init?(_ pid: pid_t, identity: Identity) {
        guard Identity(pid) == identity else { return nil }
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        time = DispatchTime.now().uptimeNanoseconds
        guard status == 0, Identity(pid) == identity else { return nil }
        cpu = usage.ri_user_time + usage.ri_system_time
    }
}

struct Marker: Encodable {
    let time: UInt64
    let name: String
    let host: String
}

struct Report: Encodable {
    let pid: pid_t
    let scenario: String
    let workload: String?
    let revision: String?
    let macModel: String
    let architecture: String
    let macOS: String
    let displayScale: Double?
    let powerMode: String?
    let baseline: Bool
    let smoke: Bool
    let identity: Identity?
    let frameLimitsFPS: [String: Double]
    let frameLimitHosts: [String]
    var readings: [Reading] = []
    var markers: [Marker] = []
    var elapsedSeconds: Double?
    var meanPercent: Double?
    var peakPercent: Double?
    var intervalsPercent: [Double] = []
    var rejected: [String] = []
    var passesBudget: Bool?
}

func sysctlString(_ key: String) -> String {
    var length = 0
    guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: length)
    guard sysctlbyname(key, &bytes, &length, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}

func wait(until deadline: UInt64) {
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return }
        let remaining = deadline - now
        var delay = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
        nanosleep(&delay, nil)
    }
}

func parseMarkers(_ path: String?, pid: pid_t, from start: UInt64, to end: UInt64) -> [Marker] {
    guard let path, let log = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return log.split(whereSeparator: \.isNewline).compactMap { line in
        let fields = line.split(separator: " ")
        guard fields.count >= 3, pid_t(fields[1]) == pid, let time = UInt64(fields[0]),
              time >= start, time <= end else { return nil }
        return Marker(time: time, name: String(fields[2]), host: fields.count >= 4 ? String(fields[3]) : "")
    }
}

func measure(_ options: Options) -> Report {
    let identity = Identity(options.pid)
    let limits: [String: Double] = options.baseline || options.scenario == "closed" ? [:] : [
        "clock": 30, "one-shot": 30, "grid-active": 15, "grid-quiet": 8, "chart-active": 15, "chart-quiet": 10,
        "shimmer-active": 15, "shimmer-quiet": 8, "hazard": 15, "busy-per-row": 15,
    ]
    let hosts = options.scenario == "both" ? ["window", "popover"] : options.scenario == "closed" ? [] : [options.scenario]
    var report = Report(pid: options.pid, scenario: options.scenario, workload: options.workload, revision: options.revision,
                        macModel: sysctlString("hw.model"), architecture: sysctlString("hw.machine"),
                        macOS: ProcessInfo.processInfo.operatingSystemVersionString, displayScale: options.displayScale,
                        powerMode: options.powerMode, baseline: options.baseline, smoke: options.smoke,
                        identity: identity, frameLimitsFPS: limits, frameLimitHosts: hosts)
    guard let identity else { report.rejected.append("PID unavailable before warmup"); return report }
    let second: UInt64 = 1_000_000_000
    if !options.smoke { wait(until: DispatchTime.now().uptimeNanoseconds + 10 * second) }
    guard let initial = Reading(options.pid, identity: identity) else {
        report.rejected.append("Initial reading missing or process changed")
        return report
    }
    report.readings.append(initial)
    var opener: pid_t = 0
    if let command = options.command {
        // Spawn directly so the first interval includes the Open.
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        defer { arguments.forEach { free($0) } }
        var actions: posix_spawn_file_actions_t?
        let setup = posix_spawn_file_actions_init(&actions)
        if setup == 0 {
            defer { posix_spawn_file_actions_destroy(&actions) }
            let redirect = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDOUT_FILENO)
            let status = redirect != 0 ? redirect : arguments.withUnsafeBufferPointer {
                posix_spawn(&opener, "/bin/sh", &actions, nil, $0.baseAddress!, environ)
            }
            if status != 0 { report.rejected.append("Open command could not start: \(status)") }
        } else {
            report.rejected.append("Open command could not start: \(setup)")
        }
    }
    let count = options.smoke ? 2 : 60
    var previous = initial
    for index in 1...count {
        wait(until: initial.time + UInt64(index) * second)
        guard let next = Reading(options.pid, identity: identity) else {
            report.rejected.append("Reading \(index) missing or process changed")
            break
        }
        report.readings.append(next)
        let elapsed = next.time - previous.time
        if elapsed < second - 20_000_000 || elapsed > second + 20_000_000 {
            report.rejected.append("Interval \(index) outside 1 s ± 20 ms")
        }
        if next.cpu < previous.cpu || elapsed == 0 {
            report.rejected.append("Invalid counters at interval \(index)")
        } else {
            report.intervalsPercent.append(100 * Double(next.cpu - previous.cpu) / Double(elapsed))
        }
        previous = next
    }

    let duration = previous.time - initial.time
    report.elapsedSeconds = Double(duration) / Double(second)
    if previous.cpu >= initial.cpu, duration > 0 {
        report.meanPercent = 100 * Double(previous.cpu - initial.cpu) / Double(duration)
    }
    report.peakPercent = report.intervalsPercent.max()
    report.markers = parseMarkers(options.markers, pid: options.pid, from: initial.time, to: previous.time)
    if opener > 0 {
        var status: Int32 = 0
        if waitpid(opener, &status, WNOHANG) != opener || status != 0 {
            report.rejected.append("Open command did not complete successfully during capture")
        }
    }
    if !options.smoke {
        if report.readings.count != 61 || duration < 60 * second { report.rejected.append("Capture incomplete") }
        if !report.markers.contains(where: { $0.name == "slow-sample" }) { report.rejected.append("No slow-sample marker in capture") }
        if options.scenario != "closed" {
            let target = options.scenario == "both" ? "popover" : options.scenario
            let open = report.markers.first { $0.name == "open" && $0.host == target }
            if open.map({ $0.time - initial.time <= 20_000_000 }) != true {
                report.rejected.append("Open not recorded within 20 ms")
            }
            if !options.baseline, report.readings.count > 1,
               !report.markers.contains(where: { $0.name == "boot" && $0.host == target &&
                   $0.time >= (open?.time ?? initial.time) && $0.time <= report.readings[1].time }) {
                report.rejected.append("Boot not recorded in the first interval")
            }
        }
        if !options.baseline, report.rejected.isEmpty, let mean = report.meanPercent, let peak = report.peakPercent {
            report.passesBudget = options.scenario == "closed" ? mean < 1 : mean <= 8 && peak <= 25
        }
    }
    return report
}

guard let options = Options(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
let report = measure(options)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(report), as: UTF8.self))
exit(report.rejected.isEmpty && report.passesBudget != false ? 0 : 1)
