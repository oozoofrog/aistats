import StatsCore

enum MetricID: String, CaseIterable {
    case cpu, memory, disk, network, battery
}

struct MetricDisplay {
    var reading: String
    var detail = ""
    var fraction: Double?
    var available = true
    var warning = false
}

enum PanelWarning: Equatable {
    static let lowDiskFloor: UInt64 = 10 * 1024 * 1024 * 1024
    case thermal, memory(String), disk

    static func active(in sample: Snapshot?) -> [Self] {
        guard let s = sample else { return [] }
        var warnings: [Self] = []
        if s.thermalState == "serious" || s.thermalState == "critical" { warnings.append(.thermal) }
        if s.isAvailable("memoryPressure"), s.memory.pressure == "warning" || s.memory.pressure == "critical" {
            warnings.append(.memory(s.memory.pressure))
        }
        if let disk = s.disk, s.isAvailable("disk"), disk.totalBytes > 0, disk.availableBytes < lowDiskFloor {
            warnings.append(.disk)
        }
        return warnings
    }

    var text: String {
        switch self {
        case .thermal: return "발열로 성능이 제한되고 있습니다"
        case .memory(let pressure): return pressure == "critical" ? "메모리 압박 심각" : "메모리 압박 경고"
        case .disk: return "디스크 여유 10 GiB 미만"
        }
    }

    var symbol: String {
        switch self {
        case .thermal: return "thermometer.high"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        }
    }
}

struct PanelData {
    struct AgentRow: Equatable {
        let registration: AppModel.AgentRow
        let sessions: Int
    }

    struct ProcessRow: Equatable, Identifiable {
        let id: Int32
        let name: String
        let cpu: String
        let memory: String
        let accessibilityLabel: String

        init(_ process: ProcessUsage) {
            id = process.pid
            name = process.name
            cpu = String(format: "%.1f%%", process.cpuPercent)
            memory = Format.bytes(process.memoryBytes)
            accessibilityLabel = [name, cpu, memory].joined(separator: ", ")
        }
    }

    let screen: ScreenSnapshot
    let agentRows: [AgentTarget: AgentRow]
    let processRows: [ProcessRow]
    var warnings: [PanelWarning] = []
    var metrics: [MetricID: MetricDisplay] = [:]

    init(_ screen: ScreenSnapshot) {
        self.screen = screen
        agentRows = Dictionary(uniqueKeysWithValues: AgentTarget.allCases.map { target in
            (target, AgentRow(registration: screen.registrations[target] ?? .init(), sessions: screen.sessionCount(target)))
        })
        processRows = screen.topProcesses.map(ProcessRow.init)
        guard let s = screen.sample else { return }
        warnings = PanelWarning.active(in: s)
        let pressure = s.isAvailable("memoryPressure") ? s.memory.pressure : nil
        let memoryWarning = pressure == "warning" || pressure == "critical"

        let cpu = s.isAvailable("cpu")
        let memory = s.isAvailable("memory")
        let network = s.isAvailable("network")
        let failed = "측정 실패"
        metrics[.cpu] = MetricDisplay(reading: cpu ? Format.percent(s.cpu.usagePercent) : failed,
                                      detail: String(format: "부하 %.2f", s.cpu.loadAverage1m),
                                      fraction: cpu ? s.cpu.usagePercent / 100 : nil, available: cpu)
        let pressureNote: String
        switch pressure {
        case "warning": pressureNote = " · 압박 경고"
        case "critical": pressureNote = " · 압박 심각"
        case nil: pressureNote = " · 압박 측정 실패"
        default: pressureNote = ""
        }
        let total = Format.bytes(s.memory.totalBytes)
        metrics[.memory] = MetricDisplay(reading: memory ? Format.percent(s.memory.usedPercent) : failed,
                                         detail: (memory ? "\(Format.bytes(s.memory.usedBytes)) / \(total)" : "전체 \(total)") + pressureNote,
                                         fraction: memory ? s.memory.usedPercent / 100 : nil,
                                         available: memory, warning: memory && memoryWarning)
        if let d = s.disk, d.totalBytes > 0, s.isAvailable("disk") {
            let lowSpace = d.availableBytes < PanelWarning.lowDiskFloor
            metrics[.disk] = MetricDisplay(reading: "\(Format.bytes(d.availableBytes)) 남음",
                                           detail: "전체 \(Format.bytes(d.totalBytes))",
                                           fraction: Double(d.totalBytes - min(d.totalBytes, d.availableBytes)) / Double(d.totalBytes),
                                           warning: lowSpace)
        } else {
            metrics[.disk] = MetricDisplay(reading: failed, available: false)
        }
        metrics[.network] = MetricDisplay(reading: network ? "↓ \(Format.rate(s.network.receivedBytesPerSecond))\n↑ \(Format.rate(s.network.sentBytesPerSecond))" : failed,
                                          available: network)
        if let b = s.battery {
            metrics[.battery] = MetricDisplay(reading: "\(b.percent)%",
                                              detail: b.isCharging ? "충전 중" : (b.powerSource == "AC Power" ? "전원 연결됨" : "배터리 사용"))
        }
    }

    var bootLabels: Set<String> {
        var labels: Set<String> = ["AISTATS", "// SYSTEM", "// AGENTS"]
        if screen.sample != nil { labels.formUnion(["CPU", "MEM", "DISK", "NET"]) }
        if metrics[.battery] != nil { labels.insert("BATTERY") }
        if !screen.topProcesses.isEmpty { labels.insert("// PROCESSES") }
        if !screen.otherClients.isEmpty { labels.insert("// CLIENTS") }
        if !screen.recentCalls.isEmpty { labels.insert("// CALLS") }
        return labels
    }
}
