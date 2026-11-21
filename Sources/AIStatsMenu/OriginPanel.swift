import StatsCore
import SwiftUI
import UserNotifications

extension OriginMetric {
    var label: String {
        switch self { case .cpu: return "CPU"; case .memory: return "메모리"; case .disk: return "디스크 I/O" }
    }
    var thresholdUnit: String {
        switch self { case .cpu: return "%"; case .memory: return "MiB"; case .disk: return "MiB/s" }
    }
    var defaultThreshold: Double { self == .memory ? 1024 : self == .disk ? 1 : 85 }

    func reading(_ row: AgentSessions.Busy) -> String {
        switch self {
        case .cpu: return String(format: "%.1f%%", row.cpuPercent)
        case .memory: return Format.bytes(row.memoryBytes)
        case .disk: return Format.rate(row.diskBytesPerSecond ?? 0)
        }
    }
}

extension AgentSessions.Busy {
    var originLabel: String {
        if let agentPid { return "\(agentName ?? "에이전트") (PID \(agentPid))" }
        switch unattributed {
        case "no_agent_ancestor": return "launchd에서 추적 종료"
        case "walk_limit": return "상위 프로세스 추적 한도 도달"
        default: return "상위 프로세스를 확인할 수 없음"
        }
    }
}

struct OriginAlertRule: Equatable {
    let metric: OriginMetric
    let threshold: Double

    static var supportsNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func current(_ defaults: UserDefaults = .standard) -> Self? {
        guard defaults.bool(forKey: "originAlerts"),
              let metric = OriginMetric(rawValue: defaults.string(forKey: "originMetric") ?? "cpu") else { return nil }
        let value = (defaults.object(forKey: "originThreshold." + metric.rawValue) as? NSNumber)?.doubleValue ?? metric.defaultThreshold
        guard value.isFinite && value > 0 else { return nil }
        return Self(metric: metric, threshold: metric == .cpu ? value : value * 1_048_576)
    }
}

// Confined to the serial sampler queue.
final class OriginCrossings: @unchecked Sendable {
    private var below: Set<Proc.Key> = []
    private var lastRule: OriginAlertRule?
    private var lastGeneration: UInt64?

    func crossed(processes: [ProcessUsage], rule: OriginAlertRule?, generation: UInt64?) -> [ProcessUsage] {
        if rule != lastRule || generation != lastGeneration { below.removeAll() }
        lastRule = rule
        lastGeneration = generation
        guard let rule, generation != nil else { return [] }
        var next: Set<Proc.Key> = []
        var crossings: [ProcessUsage] = []
        for row in processes {
            guard let token = row.startToken, let start = UInt64(token),
                  let value = OriginSnapshot.value(row, rule.metric) else { continue }
            let key = Proc.Key(pid: row.pid, start: start)
            if value < rule.threshold { next.insert(key) }
            else if below.contains(key) { crossings.append(row) }
        }
        below = next
        return crossings
    }
}

struct OriginPanel: View {
    let tree: ProcessTree
    @AppStorage("originMetric") private var metric = OriginMetric.cpu
    @AppStorage("originAlerts") private var enabled = false
    @State private var showTree = true
    @State private var requesting = false
    @State private var message = ""

    var body: some View {
        DisclosureGroup("프로세스 트리", isExpanded: $showTree) {
            VStack(alignment: .leading) {
                Picker("정렬 기준", selection: $metric) {
                    ForEach(OriginMetric.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                ProcessTreeView(tree: tree, metric: metric)
                OriginThreshold(metric: metric).id(metric)
                Toggle("선택한 기준 도달 시 알림", isOn: Binding(get: { enabled }, set: toggle))
                    .disabled(requesting)
                if !message.isEmpty { Text(message) }
            }.padding(.leading, 6)
        }
    }

    private func toggle(_ value: Bool) {
        message = ""
        guard value else { enabled = false; return }
        guard OriginAlertRule.supportsNotifications else {
            message = "알림을 사용하려면 AIStats 앱을 여세요."
            return
        }
        requesting = true
        Task { @MainActor in
            defer { requesting = false }
            do {
                enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                if !enabled { message = "시스템 설정에서 알림을 허용하세요." }
            } catch { message = "알림 권한을 확인할 수 없습니다." }
        }
    }
}

private struct OriginThreshold: View {
    let metric: OriginMetric
    @AppStorage private var threshold: Double
    init(metric: OriginMetric) {
        self.metric = metric
        _threshold = AppStorage(wrappedValue: metric.defaultThreshold, "originThreshold." + metric.rawValue)
    }
    var body: some View {
        HStack {
            Text("알림 기준 (\(metric.thresholdUnit))")
            TextField("양수", value: $threshold, format: .number)
                .accessibilityLabel("알림 기준 \(metric.thresholdUnit)")
        }
    }
}
