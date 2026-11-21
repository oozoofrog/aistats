import Darwin
import Foundation
import StatsCore

func diagnosticCommand(_ command: String, raw: [String]) throws {
    let selectors: Set<String> = ["pid", "name", "path", "port", "start-token", "match", "args-contain"]
    let values: Set<String>
    var flags: Set<String> = ["json"]
    var input = raw[...]
    var wire: [String: Any] = [:]
    switch command {
    case "wait":
        guard let condition = input.popFirst(), !condition.hasPrefix("-") else { throw CLIError("wait requires a condition") }
        wire["condition"] = condition
        values = selectors.union(["below", "timeout", "above-gib", "volume-path", "track-id"])
        flags.insert("new-instances-only")
    case "find":
        values = selectors.union(["limit"])
        flags.formUnion(["probe-free", "include-baseline"])
    case "diagnose": values = ["purpose"]
    default: values = []; flags.insert("no-toolchain")
    }
    let args = try Arguments(input, valueOptions: values)
    if command == "wait", args.flags.contains("track-id") || args.options["track-id"] != nil {
        throw CLIError("tracks exist only in an MCP session")
    }
    if let bad = Set(args.options.keys).subtracting(values).union(args.flags.subtracting(flags)).sorted().first {
        throw CLIError("unsupported option --" + bad)
    }
    let names = ["start-token": "startToken", "args-contain": "argsContain", "new-instances-only": "newInstancesOnly",
                 "probe-free": "probeFree", "include-baseline": "includeBaseline", "volume-path": "volumePath", "above-gib": "aboveGiB",
                 "below": "belowPercent", "timeout": "timeoutSeconds"]
    for (key, value) in args.options {
        let field = names[key] ?? key
        switch key {
        case "port", "pid", "limit":
            guard let number = Int(value) else { throw CLIError("--" + key + " requires an integer") }
            wire[field] = number
        case "above-gib", "timeout", "below":
            guard let number = Double(value), number.isFinite else { throw CLIError("--" + key + " requires a finite number") }
            wire[field] = number
        default: wire[field] = value
        }
    }
    for flag in args.flags where names[flag] != nil { wire[names[flag]!] = true }
    let json = args.flags.contains("json")
    switch command {
    case "find":
        let result = try Args.find(wire)
        if result.note == "process table could not be read" || result.scanAvailable == false { throw CLIError("process table could not be read") }
        if json { try printJSON(result) } else {
            print(result.summaryLine)
            let path = result.selector == "path"
            print("PID\tSTART TOKEN\tPPID\tMEMORY\tNAME" + (path ? "\tPATH" : ""))
            for row in result.processes {
                var fields = [String(row.pid), row.startToken ?? "?", row.ppid.map(String.init) ?? "?",
                              row.footprintBytes.map(Format.bytes) ?? "?", row.name ?? "?"]
                if path { fields.append(row.path ?? "?") }
                print(fields.joined(separator: "\t"))
            }
            for (i, baseline) in (result.baselines ?? []).enumerated() { print("baseline \(i): \(baseline.summaryLine)") }
        }
        if result.matched == 0 { exit(3) }
    case "diagnose":
        let purpose = args.options["purpose"] ?? "slowdown"
        guard ["slowdown", "heavy_work"].contains(purpose) else { throw CLIError("--purpose must be slowdown or heavy_work") }
        let report = Diagnosis.run(purpose: purpose)
        if json { try printJSON(report) } else { print(report.summaryLine) }
        switch report.readiness ?? report.status {
        case "issue_detected", "caution": exit(3)
        case "insufficient_data", "unknown": exit(4)
        default: break
        }
    case "env":
        let report = EnvironmentProbe.collect(includeToolchain: !args.flags.contains("no-toolchain"))
        if json { try printJSON(report) } else { print(report.summaryLine) }
    default:
        let condition = try Args.waitCondition(wire)
        let timeout = try Args.waitTimeout(wire, condition: condition)
        signal(SIGINT) { _ in _exit(130) }
        let report = Waiter(condition: condition, timeout: timeout, durations: .forHome(AIStatsPaths.home)).runToExit()
        if json { try printJSON(report) } else { print(report.summaryLine) }
        if report.state == "timed_out" { exit(3) }
        if report.state == "unavailable" { exit(4) }
    }
}
