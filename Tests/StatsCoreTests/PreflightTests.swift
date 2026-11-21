import Foundation
import Testing
@testable import StatsCore

@Test func preflightDistinguishesEveryThresholdAndMissingReading() throws {
    var healthy = SystemSampler().sample()
    healthy.cpu.logicalCores = 4
    healthy.cpu.loadAverage1m = 7.99
    healthy.memory.pressure = "normal"
    healthy.thermalState = "fair"
    healthy.disk = .init(mountPath: "/", totalBytes: 100 << 30, availableBytes: Diagnosis.lowDiskBytes)
    healthy.battery = .init(percent: 20, isCharging: false, powerSource: "Battery Power")
    healthy.unavailable = nil
    func assess(_ snapshot: Snapshot, _ cpu: Double? = 84.9) -> Preflight {
        Preflight.assess(snapshot, cpu: cpu, at: Date(), start: Proc.nowNs())
    }
    #expect(assess(healthy).readiness == "ready")
    let cases: [(String, (inout Snapshot) -> Void)] = [
        ("loadAverage", { $0.cpu.loadAverage1m = 8 }), ("memoryPressure", { $0.memory.pressure = "warning" }),
        ("thermal", { $0.thermalState = "serious" }), ("diskFree", { $0.disk?.availableBytes -= 1 }),
        ("battery", { $0.battery?.percent = 19 }), ("cpu", { $0.cpu.usagePercent = 85 })
    ]
    for (metric, mutate) in cases {
        var sample = healthy
        mutate(&sample)
        let cpu = metric == "cpu" ? 85.0 : 84.9
        sample.cpu.usagePercent = cpu
        let report = assess(sample, cpu)
        #expect(report.signals.map(\.metric) == [metric] && report.readiness == "caution")
        #expect(Diagnosis.make(purpose: "heavy_work", snapshot: sample, top: []).evidence.map(\.metric) == [metric])
    }
    for metric in ["loadAverage", "memoryPressure", "diskFree", "battery", "thermal", "cpu"] {
        var sample = healthy
        sample.unavailable = [metric]
        if metric == "diskFree" { sample.disk = nil }
        if metric == "battery" { sample.battery = nil }
        if metric == "thermal" { sample.thermalState = "unknown" }
        let report = assess(sample, metric == "cpu" ? nil : 84.9)
        #expect(report.unavailable == [metric] && report.signals.isEmpty)
        #expect(report.readiness == (["loadAverage","memoryPressure","diskFree"].contains(metric) ? "unknown" : "ready"))
    }
    var all = healthy
    for (_, mutate) in cases { mutate(&all) }
    let full = assess(all, 85)
    #expect(full.signals.count == 6 && full.context.utf8.count <= 512)
}
