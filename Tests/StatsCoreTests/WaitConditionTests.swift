import Foundation
import Testing
@testable import StatsCore

@Test func conditionMinimumsAndStartObservations() throws {
    let cases: [(WaitCondition, Double)] = [(WaitCondition.cpuIdle(.system, belowPercent: 10), 2.5),
                                 (.memoryPressureNormal, 1.5), (.portListening(12345), 1),
                                 (.diskFree(path: "/", bytes: 1), 1),
                                 (.processStarted(.name("sleep", glob: false, args: nil), newOnly: false), 1),
                                 (.processExit(pid: 1, startToken: nil), 1)]
    for (condition, minimum) in cases {
        #expect(try Args.waitTimeout(["timeoutSeconds": minimum], condition: condition) == minimum)
        #expect(throws: ToolError.self) { try Args.waitTimeout(["timeoutSeconds": minimum - 0.1], condition: condition) }
    }
    for invalid in [["condition": "cpu_idle", "startToken": "42"], ["condition": "cpu_idle", "trackId": "t", "startToken": "42"]] {
        #expect(throws: ToolError.self) { try Args.waitCondition(invalid) }
    }
    let child = try Child("/bin/sleep", ["728.41"])
    defer { child.kill() }
    let condition = try Args.waitCondition(["condition": "process_started", "name": "sleep", "argsContain": "728.41"])
    let match = Waiter(condition: condition, timeout: 1).run()
    #expect(match.state == "met" && match.processes?.first?.pid == child.pid)
    let newOnly = try Args.waitCondition(["condition": "process_started", "name": "sleep", "argsContain": "728.41", "newInstancesOnly": true])
    #expect(Waiter(condition: newOnly, timeout: 1).run().state == "timed_out")
    let disk = Waiter(condition: .diskFree(path: "/", bytes: 1), timeout: 1).run()
    #expect(disk.state == "met" && disk.thresholdBytes == 1 && disk.lastObservation?.diskAvailableBytes != nil)
    #expect(Waiter(condition: .diskFree(path: "/missing-aistats-test-volume", bytes: 1), timeout: 1).run().state == "unavailable")
}

@Test func allConditionMinimumsAdmitTwentyConsecutiveSuccessfulWaits() async throws {
    let child = try Child("/bin/sleep", ["871.31"])
    defer { child.kill() }
    let cases: [(WaitCondition, Double)] = [(.cpuIdle(.system, belowPercent: 10), 2.5),
        (.memoryPressureNormal, 1.5), (.processExit(pid: child.pid, startToken: nil), 1),
        (.processStarted(.name("test", glob: false, args: nil), newOnly: false), 1),
        (.diskFree(path: "/", bytes: 1), 1), (.portListening(1000), 1)]
    await withTaskGroup(of: Void.self) { group in
        for (condition, minimum) in cases {
            group.addTask {
                for _ in 0..<20 {
                    let waiter = Waiter(condition: condition, timeout: minimum)
                    defer { withExtendedLifetime(waiter) {} }
                    waiter.readObservation = { _ in .init(observation: .init(at: Date(), valid: true), satisfied: true) }
                    let result: WaitResult = await withCheckedContinuation { resume in
                        waiter.start { resume.resume(returning: $0) }
                    }
                    #expect(result.state == "met")
                    if condition.name == "cpu_idle" { #expect((1.9...2.4).contains(result.elapsedSeconds)) }
                    if condition.name == "memory_pressure_normal" { #expect((0.9...1.3).contains(result.elapsedSeconds)) }
                }
            }
        }
    }
}

@Test func lateAndUnknownObservationsCannotSatisfyAWait() {
    let late = Waiter(condition: .diskFree(path: "/", bytes: 1), timeout: 1)
    late.readObservation = { _ in
        Thread.sleep(forTimeInterval: 1.05)
        return .init(observation: .init(at: Date(), valid: true), satisfied: true)
    }
    #expect(late.run().state == "timed_out")
    let unknown = Waiter(condition: .memoryPressureNormal, timeout: 1.5)
    unknown.readObservation = { _ in .init(observation: .init(at: Date(), memoryPressure: "unknown", valid: false), satisfied: false) }
    #expect(unknown.run().state == "timed_out")
}

@Test func diskWaitUsesFreeBlocksAtTheExactByteBoundary() {
    for available: UInt64 in [99,100,101] {
        let waiter = Waiter(condition: .diskFree(path: "/", bytes: 100), timeout: 1)
        waiter.readDisk = { _ in .init(mountPath: "/", totalBytes: 300, availableBytes: available, availableForImportantUsageBytes: 250) }
        let result = waiter.run()
        #expect(result.state == (available >= 100 ? "met" : "timed_out"))
        #expect(result.lastObservation?.diskAvailableBytes == available && result.thresholdBytes == 100)
    }
}

@Test func processStartCountsEveryMatchAndSelectsOnlyInstancesBornAfterStart() throws {
    let token = String(format: "7777.%07d", Int.random(in: 1...9999999))
    var children: [Child] = []
    defer { for child in children { child.kill() } }
    for _ in 0..<8 { children.append(try Child("/bin/sleep", [token])) }
    let selector = ProcessSelector.name("sleep", glob: false, args: token)
    let current = Waiter(condition: .processStarted(selector, newOnly: false), timeout: 1).run()
    #expect(current.matched == 8 && current.processes?.count == 5)
    let done = DispatchSemaphore(value: 0)
    var result: WaitResult?
    let waiter = Waiter(condition: .processStarted(selector, newOnly: true), timeout: 4)
    waiter.start { result = $0; done.signal() }
    Thread.sleep(forTimeInterval: 1)
    children.append(try Child("/bin/sleep", [token]))
    #expect(done.wait(timeout: .now() + 3) == .success)
    #expect(result?.matched == 1 && result?.processes?.first?.pid == children.last?.pid)
}
