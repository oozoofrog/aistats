import Darwin
import Foundation
import Testing
@testable import StatsCore

private typealias Object = [String: Any]

private func tree(_ rows: [(Int32, Int32, String)], unread: Set<Int32> = [], unpaired: Set<Int32> = [], cpu: [Int32: Double] = [:],
                  sessions: [(agent: Int32, server: Int32)] = [], devices: Bool = true) -> ProcessTree {
    let date = Date()
    let entries = rows.map { Proc.Entry(pid: $0.0, ppid: $0.1, comm: $0.2, startSec: Int($0.0), startUsec: 0) }
    let processes = rows.filter { !unread.contains($0.0) }.map { pid, _, name in
        ProcessUsage(cpuPaired: !unpaired.contains(pid), diskRate: 0, startToken: String(pid),
                     pid: pid, name: name, cpuPercent: cpu[pid] ?? Double(pid), memoryBytes: UInt64(pid) * 100)
    }
    let presences = sessions.map { s in
        var p = ActivityStore.Presence(name: "session", pid: s.server, client: nil, connectedAt: date, lastSeen: date, startToken: String(s.server))
        p.agentPid = s.agent
        p.agentStartToken = String(s.agent)
        return p
    }
    return ProcessTree(entries: entries, processes: processes, sessions: presences, at: date, deviceRoots: devices) { _, _ in true }
}

private let fixture: [(Int32, Int32, String)] = [
    (2, 1, "CoreSimulatorService"), (3, 1, "SimLaunchHost"),
    (10, 1, "launchd_sim"), (11, 10, "SpringBoard"), (12, 11, "app"), (20, 11, "launchd_sim"), (21, 20, "backboardd"),
    (30, 1, "launchd_sim"), (31, 30, "unpaired"), (50, 1, "launchd_sim"), (51, 50, "unreadable"),
    (60, 1, "agent"), (61, 60, "shell"), (62, 61, "launchd_sim"), (63, 62, "sim"), (64, 60, "server"),
]

private func usage() -> SimulatorUsage {
    SimulatorUsage(tree(fixture, unread: [50, 51], unpaired: [31], sessions: [(60, 64)]))
}

private func json(_ value: some Encodable) throws -> Object {
    try #require(JSONSerialization.jsonObject(with: MCPServer.encoder.encode(value)) as? Object)
}

@Test func deviceRowsSumOwnReadingsAndStopAtNestedRootsAndAgents() throws {
    let report = usage()
    #expect(report.bootedCount == 5 && report.devices.count == 5 && !report.truncated)
    let rows = Dictionary(uniqueKeysWithValues: report.devices.map { ($0.rootPid, $0) })
    let outer = try #require(rows[10]), nested = try #require(rows[20])
    #expect(outer.processCount == 3 && outer.cpuPercent == 33 && outer.memoryBytes == 3300 && outer.partial.isEmpty)
    #expect(nested.processCount == 2 && nested.cpuPercent == 41 && nested.memoryBytes == 4100)
    #expect(outer.top.map(\.pid) == [12, 11, 10] && outer.top[0].cpuPercent == 12 && outer.top[0].memoryBytes == 1200)
    #expect(!outer.top.contains { [20, 21].contains($0.pid) })
    #expect(rows[30]?.cpuPercent == 30 && rows[30]?.memoryBytes == 6100 && rows[30]?.partial == ["cpu"])
    #expect(rows[30]?.top.map(\.pid) == [30], "an unpaired CPU reading gives no top member (SIM-009)")
    #expect(rows[50]?.top.isEmpty == true && rows[50]?.topOmitted == nil)
    #expect(rows[62]?.processCount == 2 && rows[62]?.cpuPercent == 125)
    let devices = report.devices.reduce(0) { $0 + $1.processCount }
    #expect(devices == 3 + 2 + 2 + 2 + 2)
    #expect(report.devices.allSatisfy { $0.ownerUnknown == "no_source" && $0.top.count <= 3 })
    #expect(report.devices.map(\.rootPid) == [62, 20, 10, 30, 50])

    let measured = tree(fixture, unread: [50, 51], unpaired: [31], sessions: [(60, 64)])
    #expect(measured.agents == [60] && measured.nodes[60]?.total.cpuPercent == 60 + 61 + 64)
    #expect(measured.nodes[61]?.owner == 60 && measured.nodes[62]?.owner == 60)
    #expect(measured.nodes[2]?.total.cpuPercent == 2 && measured.nodes[3]?.count == 1)
    let plain = tree(fixture, unread: [50, 51], unpaired: [31], sessions: [(60, 64)], devices: false)
    #expect(plain.deviceRoots.isEmpty && plain.nodes[10]?.count == 5 && plain.nodes[10]?.total.cpuPercent == 74)
    #expect(SimulatorUsage(plain).bootedCount == 0)
}

@Test func deviceRowsOmitUnreadableTotalsAndUnknownIdentity() throws {
    let body = try json(usage())
    #expect(Set(body.keys) == ["observedAt", "bootedCount", "devices", "truncated", "devicesOmitted"])
    let rows = try #require(body["devices"] as? [Object])
    for row in rows {
        #expect(Set(row.keys).isSuperset(of: ["rootPid", "bootedAt", "processCount", "partial", "top", "ownerUnknown"]))
        if row["rootPid"] as? Int != 50 { #expect(row["startToken"] as? String == (row["rootPid"] as? Int).map(String.init)) }
        #expect(row["ownerUnknown"] as? String == "no_source")
        for key in ["udid", "name", "runtime", "owner", "hostServices"] { #expect(row[key] == nil) }
    }
    let blind = try #require(rows.first { $0["rootPid"] as? Int == 50 })
    // SIM-051: no sample row and no direct read, so the token is absent, never empty or 0.
    #expect(blind["cpuPercent"] == nil && blind["memoryBytes"] == nil && blind["startToken"] == nil)
    #expect(blind["rootPid"] != nil && blind["bootedAt"] is String)
    #expect(blind["partial"] as? [String] == ["cpu", "memory"])
    #expect((blind["top"] as? [Object])?.isEmpty == true)
    for row in rows {
        for member in row["top"] as? [Object] ?? [] {
            #expect(Set(member.keys) == ["pid", "name", "cpuPercent", "memoryBytes"], "SIM-009 member fields")
        }
    }
    #expect(body["hostServices"] == nil)
    let empty = try json(SimulatorUsage(tree([(2, 1, "CoreSimulatorService"), (5, 1, "zsh")])))
    #expect(empty["bootedCount"] as? Int == 0 && (empty["devices"] as? [Any])?.isEmpty == true && empty["truncated"] as? Bool == false)
    #expect(SimulatorUsage(tree([])).summaryLine == "No booted simulator devices.")
}

@Test func simulatorReportFitsBudgetAndCountsOmittedDevices() throws {
    let h = MCPHarness()
    defer { h.close() }
    let name = String(repeating: "n", count: 32)
    func rows(_ devices: Int) -> [(Int32, Int32, String)] {
        (0..<devices).flatMap { d -> [(Int32, Int32, String)] in
            let root = Int32(1000 * (d + 1))
            return [(root, 1, "launchd_sim")] + (1..<300).map { (root + Int32($0), root, name) }
        }
    }
    func body(_ devices: Int) throws -> Object {
        let line = MCPServer.line(try h.server.simulatorResponse(SimulatorUsage(tree(rows(devices))), id: 1), toolCall: true)
        #expect(line.count <= 9216)
        let result = try #require((try JSONSerialization.jsonObject(with: line) as? Object)?["result"] as? Object)
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["structuredContent"] as? Object)
        #expect(try JSONSerialization.data(withJSONObject: content).count <= MCPServer.maxResponseBytes)
        return content
    }
    let four = try body(4)
    #expect((four["devices"] as? [Object])?.count == 4 && four["truncated"] as? Bool == false)
    #expect((four["devices"] as? [Object])?.allSatisfy { $0["processCount"] as? Int == 300 } == true)
    let many = try body(40)
    let shown = (many["devices"] as? [Object])?.count ?? 0
    #expect(many["bootedCount"] as? Int == 40 && many["truncated"] as? Bool == true)
    #expect(shown > 0 && shown + (many["devicesOmitted"] as? Int ?? 0) == 40)
}

@Test func simulatorToolIsListedAndAnswersOverStdio() throws {
    let h = MCPHarness()
    h.initialize()
    h.send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
    let tools = try #require((h.response(1)?["result"] as? Object)?["tools"] as? [Object])
    let tool = try #require(tools.first { $0["name"] as? String == "get_simulator_usage" })
    #expect(tool["annotations"] as? [String: Bool] == ["readOnlyHint": true, "openWorldHint": false])
    let schema = try #require(tool["outputSchema"] as? Object)
    let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
    #expect(schemaText.contains("Sum of footprints") && schemaText.contains("counted more than once") && !schemaText.contains("hostServices"))
    #expect(!["budget", "limit", "slot", "claim"].contains { schemaText.lowercased().contains($0) })
    h.call(2, "get_simulator_usage")
    let result = try #require(h.response(2)?["result"] as? Object)
    #expect(result["isError"] as? Bool == false)
    let body = try #require(result["structuredContent"] as? Object)
    #expect(Set(body.keys).isSuperset(of: ["observedAt", "bootedCount", "devices", "truncated"]) && body["hostServices"] == nil)
    let roots = (Proc.currentUserTable() ?? []).filter { $0.comm == ProcessTree.deviceRootName }.count
    #expect(abs((body["bootedCount"] as? Int ?? -1) - roots) <= 1)
    #expect((h.line(2) ?? "").contains("/Users/") == false)
    h.call(3, "get_simulator_usage", ["limit": 1])
    #expect((h.response(3)?["result"] as? Object)?["isError"] as? Bool == true)
    h.close()
    #expect(h.finished.wait(timeout: .now() + 5) == .success)
}

@Test func syntheticDeviceRootGetsOneRowWithoutIdentityOrOwner() throws {
    let dir = TestTemp.dir()
    let binary = dir.appendingPathComponent(ProcessTree.deviceRootName)
    try FileManager.default.copyItem(atPath: "/bin/bash", toPath: binary.path)
    let signed = try Subprocess.run("/usr/bin/codesign", ["-f", "-s", "-", binary.path], timeout: 30)
    try #require(signed.succeeded)
    let marker = "aistats-sim-marker-\(getpid())"
    let root = try Child(binary.path, ["-c", "sleep 60 & sleep 60 & wait", marker])
    defer {
        for entry in Proc.currentUserTable() ?? [] where entry.ppid == root.pid { Darwin.kill(entry.pid, SIGTERM) }
        root.kill()
    }
    try #require(eventually(10) {
        (Proc.currentUserTable() ?? []).filter { $0.ppid == root.pid }.count == 2
            && (Proc.currentUserTable() ?? []).contains { $0.pid == root.pid && $0.comm == ProcessTree.deviceRootName }
    })
    let h = MCPHarness()
    h.initialize()
    h.call(1, "get_simulator_usage")
    let body = try #require((h.response(1)?["result"] as? Object)?["structuredContent"] as? Object)
    let line = h.line(1) ?? ""
    h.close()
    let row = try #require((body["devices"] as? [Object])?.first { $0["rootPid"] as? Int32 == root.pid })
    #expect(row["processCount"] as? Int == 3)
    #expect(row["startToken"] as? String == Proc.usage(root.pid).map { String($0.start) })
    for key in ["udid", "name", "runtime", "owner"] { #expect(row[key] == nil) }
    #expect(row["ownerUnknown"] as? String == "no_source")
    #expect((row["partial"] as? [String]) != nil && row["bootedAt"] is String)
    #expect(!line.contains(marker) && !line.contains(dir.path) && !line.contains("/Users/"))
}

@Test func deviceRootWithoutSampleRowGetsItsTokenFromADirectRead() throws {
    var asked: [Int32] = []
    let report = SimulatorUsage(tree(fixture, unread: [50, 51], unpaired: [31], sessions: [(60, 64)])) { node in
        asked.append(node.pid)
        return "direct-\(node.pid)"
    }
    #expect(asked == [50], "only a root without a verified sample row is read directly")
    let rows = Dictionary(uniqueKeysWithValues: report.devices.map { ($0.rootPid, $0) })
    #expect(rows[50]?.startToken == "direct-50" && rows[10]?.startToken == "10")

    let me = getpid()
    let table = try #require(Proc.currentUserTable())
    let own = try #require(table.first { $0.pid == me })
    var moved = own
    moved.startSec -= 1
    let live = ProcessTree(entries: [own], processes: [], sessions: [], at: Date())
    let reused = ProcessTree(entries: [moved], processes: [], sessions: [], at: Date())
    let node = try #require(live.nodes[me])
    #expect(node.startToken == nil)
    #expect(SimulatorUsage.directToken(node) == Proc.usage(me).map { String($0.start) })
    #expect(SimulatorUsage.directToken(try #require(reused.nodes[me])) == nil, "a start time that differs from the table is PID reuse")
}

@Test func deviceTotalsAreRoundedToOneDecimal() throws {
    let rows: [(Int32, Int32, String)] = [(10, 1, "launchd_sim")] + (11...30).map { ($0, 10, "p") }
    let cpu = Dictionary(uniqueKeysWithValues: ([10] + Array(11...30)).map { (Int32($0), 0.1) })
    let first = try MCPServer.encoder.encode(SimulatorUsage(tree(rows, cpu: cpu)))
    let row = try #require(SimulatorUsage(tree(rows, cpu: cpu)).devices.first)
    #expect(row.cpuPercent == 2.1)
    #expect(String(decoding: first, as: UTF8.self).contains("\"cpuPercent\":2.1,"))
    for _ in 0..<5 { #expect(try MCPServer.encoder.encode(SimulatorUsage(tree(rows, cpu: cpu))) == first, "RSZ-011") }
}

@Test func longTopNamesAreTrimmedBeforeAnyDeviceRow() throws {
    let h = MCPHarness()
    defer { h.close() }
    let name = String(repeating: "n", count: 255)
    let rows = (0..<4).flatMap { d -> [(Int32, Int32, String)] in
        let root = Int32(1000 * (d + 1))
        return [(root, 1, "launchd_sim")] + (1..<300).map { (root + Int32($0), root, name) }
    }
    let full = try json(SimulatorUsage(tree(rows)))
    #expect(try JSONSerialization.data(withJSONObject: full).count > MCPServer.maxResponseBytes, "the fixture needs Trimming")
    let line = MCPServer.line(try h.server.simulatorResponse(SimulatorUsage(tree(rows)), id: 1), toolCall: true)
    let result = try #require((try JSONSerialization.jsonObject(with: line) as? Object)?["result"] as? Object)
    let content = try #require(result["structuredContent"] as? Object)
    #expect(try JSONSerialization.data(withJSONObject: content).count <= MCPServer.maxResponseBytes && line.count <= 9216)
    let devices = try #require(content["devices"] as? [Object])
    #expect(devices.count == 4 && content["devicesOmitted"] as? Int == 0 && content["truncated"] as? Bool == true)
    for row in devices {
        #expect(row["processCount"] as? Int == 300 && row["cpuPercent"] != nil && row["memoryBytes"] != nil && row["startToken"] != nil)
        let shown = (row["top"] as? [Object])?.count ?? -1
        #expect(shown + (row["topOmitted"] as? Int ?? 0) == 3, "RSZ-007")
        for member in row["top"] as? [Object] ?? [] { #expect(member["name"] as? String == name, "RSZ-009: no shortened name") }
    }
    #expect(devices.contains { ($0["topOmitted"] as? Int ?? 0) > 0 })
}

private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

@Test func simulatorUsageStartsNoSubprocess() throws {
    let launches = Launches()
    let h = MCPHarness()
    defer { h.close() }
    let response = try Subprocess.$launchObserver.withValue({ launches.add($0) }) {
        try h.server.simulatorResponse(SimulatorUsage.measure(store: ActivityStore(directory: TestTemp.dir())), id: 1)
    }
    #expect(launches.all.isEmpty, "SIM-032, SIM-033: \(launches.all)")
    #expect(response["result"] != nil)
    try Subprocess.$launchObserver.withValue({ launches.add($0) }) { _ = try Subprocess.run("/usr/bin/true", [], timeout: 5) }
    #expect(launches.all == ["/usr/bin/true"], "the hook sees a launch")
}

private func aistatsBinary() throws -> String {
    let path = Bundle(for: MCPHarness.self).bundleURL.deletingLastPathComponent().appendingPathComponent("aistats").path
    try #require(FileManager.default.isExecutableFile(atPath: path), "build the aistats product next to the test bundle")
    return path
}

/// Runs the built CLI with `DEVELOPER_DIR` set to an empty folder, so no Xcode is selected (SIM-013).
private func runCLI(_ arguments: [String], stdin: String? = nil) throws -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try aistatsBinary())
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["DEVELOPER_DIR"] = TestTemp.dir().path
    environment["AISTATS_HOME"] = TestTemp.dir().path
    process.environment = environment
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
    try input.fileHandleForWriting.close()
    let out = output.fileHandleForReading.readDataToEndOfFile(), err = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
}

@Test func simsCommandPrintsTheToolObjectWithoutXcode() throws {
    let optional: Set<String> = ["startToken", "cpuPercent", "memoryBytes", "topOmitted"]
    func shape(_ body: Object) -> (top: Set<String>, row: Set<String>?) {
        (Set(body.keys), (body["devices"] as? [Object])?.first.map { Set($0.keys).subtracting(optional) })
    }
    let cli = try runCLI(["sims", "--json"])
    #expect(cli.status == 0, "\(cli.err)")
    let printed = try #require(try JSONSerialization.jsonObject(with: Data(cli.out.utf8)) as? Object)

    let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"sims-test","version":"1"}}}"#
    let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_simulator_usage","arguments":{}}}"#
    let stdio = try runCLI(["mcp"], stdin: [initialize, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, call, ""].joined(separator: "\n"))
    let reply = try #require(stdio.out.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? Object }
        .first { $0["id"] as? Int == 2 })
    let result = try #require(reply["result"] as? Object)
    #expect(result["isError"] as? Bool == false, "SIM-013")
    let structured = try #require(result["structuredContent"] as? Object)
    #expect(shape(printed).top == shape(structured).top, "SIM-040")
    if let a = shape(printed).row, let b = shape(structured).row { #expect(a == b, "SIM-040 row fields") }

    let text = try runCLI(["sims"])
    #expect(text.status == 0)
    let first = String(text.out.split(separator: "\n").first ?? "")
    #expect(first == "No booted simulator devices." || first.hasSuffix(" booted simulator device.") || first.hasSuffix(" booted simulator devices."))
    for bad in [["sims", "--bogus"], ["sims", "extra"], ["sims", "--sort", "cpu"]] {
        let r = try runCLI(bad)
        #expect(r.status == 1 && r.out.isEmpty && r.err.hasPrefix("aistats: "), "\(bad)")
    }
}

@Test func simsTextStartsWithTheSummaryLine() {
    let report = usage()
    #expect(report.text().split(separator: "\n").first.map(String.init) == report.summaryLine)
    #expect(SimulatorUsage(tree([])).text() == "No booted simulator devices.")
}
