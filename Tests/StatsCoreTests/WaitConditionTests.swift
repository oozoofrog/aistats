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
