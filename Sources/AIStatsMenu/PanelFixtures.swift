import AppKit
import StatsCore
import SwiftUI

enum PanelFixtures {
    static func screen(warning: Bool = false) throws -> ScreenSnapshot {
        let json = """
        {
          "timestamp": 650000000, "sampleIntervalSeconds": 2,
          "cpu": {"usagePercent": 23.4,"userPercent": 18,"systemPercent": 5.4,"logicalCores": 8,
                  "loadAverage1m": 3.12,"loadAverage5m": 2.01,"loadAverage15m": 1.99},
          "memory": {"totalBytes": 34359738368,"usedBytes": 20959440486,"appBytes": 1000000,"wiredBytes": 900000,
                     "compressedBytes": 10000,"cachedBytes": 20000,"swapUsedBytes": 0,
                     "pressure": "\(warning ? "critical" : "normal")"},
          "disk": {"mountPath": "/", "totalBytes": 499000000000, "availableBytes": \(warning ? 5000000000 : 112000000000)},
          "network": {"receivedBytesPerSecond": 1200000,"sentBytesPerSecond": 84000,
                      "receivedTotalBytes": 5200000000,"sentTotalBytes": 510000000,"interfaces": ["en0"]},
          "battery": {"percent": 82,"isCharging": false,"powerSource": "Battery Power"},
          "uptimeSeconds": 5000,"thermalState": "\(warning ? "serious" : "nominal")",
          "topProcesses": [
            {"pid": 1, "name": "프로세스 이름이 긴 Fixture", "cpuPercent": 132.5, "memoryBytes": 976000000},
            {"pid": 2, "name": "WindowServer", "cpuPercent": 12.3, "memoryBytes": 561000000},
            {"pid": 3, "name": "AIStatsMenu", "cpuPercent": 5.0, "memoryBytes": 120000000}
          ]
        }
        """
        let sample = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        let now = sample.timestamp
        return ScreenSnapshot(
            sample: sample,
            cpuHistory: (0..<60).map { CPUPoint(id: UInt64($0), value: 26 + 15 * sin(Double($0) * 0.64) + Double($0 % 7) * 2) },
            topProcesses: sample.topProcesses ?? [],
            agents: [
                .init(name: "Claude Code", pid: 1, client: "claude-code", connectedAt: now, lastSeen: now),
                .init(name: "Codex", pid: 2, client: "codex", connectedAt: now, lastSeen: now),
                .init(name: "테스트 클라이언트", pid: 3, client: nil, connectedAt: now, lastSeen: now),
            ],
            recentCalls: [
                .init(date: now, agent: "claude-code", tool: "diagnose_system"),
                .init(date: now.addingTimeInterval(-5), agent: "codex", tool: "get_system_stats"),
            ],
            registrations: [
                .claudeCode: .init(state: .installed),
                .codex: .init(state: .pathUpdateNeeded(registered: "/fixtures/previous/aistats")),
                .gemini: .init(state: .notInstalled),
                .claudeDesktop: .init(state: .nameConflict(registered: "command=/fixtures/foreign args=[] env={TOKEN: …}"),
                                      fingerprint: "0123456789ab"),
                .cursor: .init(state: .checkFailed("fixture diagnostic"), message: "설정을 읽지 못해 바꾸지 않았습니다",
                               messageIsError: true, messageDetail: "fixture diagnostic"),
            ]
        )
    }

    @MainActor
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures: [(name: String, warning: Bool, width: CGFloat, frame: Double?, options: DisplayOptions)] = [
            ("normal", false, S.panelWidth, nil, .init()),
            ("warning", true, S.panelWidth, nil, .init()),
            ("narrow-accessible", true, 320, nil, .init(reduceMotion: true, increaseContrast: true, reduceTransparency: true)),
            ("narrow-actions", true, 320, nil, .init(reduceMotion: true, increaseContrast: true)),
            ("boot-start", false, S.panelWidth, 0, .init()),
            ("boot-mid", false, S.panelWidth, 0.18, .init()),
            ("boot-end", false, S.panelWidth, 0.36, .init()),
            ("chart-wrap-before", false, S.panelWidth, 3.999, .init()),
            ("chart-wrap-after", false, S.panelWidth, 4.034, .init()),
        ]
        for fixture in fixtures {
            let data = PanelData(try screen(warning: fixture.warning))
            let exposure = Exposure()
            let clock = AnimationClock(time: { 0 })
            let host = HostMotion(host: "fixture", clock: clock)
            host.settings(fixture.options)
            if fixture.frame != nil { host.opened() }
            host.expose(exposure, data: data)
            if let time = fixture.frame {
                // Timed snapshots advance from a simulated first draw at fixture time zero.
                for cell in host.cells.values { cell.recordDraw(cell.frame) }
                if time >= 4 { host.tick(3.94) }
                host.tick(time)
            }
            let spy = RegistrationSpy()
            let content = PanelContent(data: data, theme: Theme(options: fixture.options),
                                       size: CGSize(width: fixture.width, height: S.panelHeight),
                                       decoration: DecorationContext(host: "fixture", exposure: exposure, usesCanvas: true), cells: host.cells,
                                       perform: spy.perform, refreshRegistrations: spy.refresh, confirm: spy.confirm)
            let offset: CGFloat = fixture.name == "narrow-actions" ? 540 : 0
            let renderer = ImageRenderer(content: PanelView(content: content, fixtureScrollOffset: offset)
                .environment(\.locale, Locale(identifier: "ko_KR")))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let file = directory.appendingPathComponent(fixture.name + ".png")
            try png.write(to: file, options: .atomic)
            print(file.path)
            precondition(spy.calls == 0)
            exposure.invalidate()
            host.pause(closing: true)
        }
    }

    private final class RegistrationSpy {
        private(set) var calls = 0
        func perform(_ action: AppModel.Action, _ target: AgentTarget) { calls += 1 }
        func refresh() { calls += 1 }
        func confirm(_ target: AgentTarget) { calls += 1 }
    }
}
