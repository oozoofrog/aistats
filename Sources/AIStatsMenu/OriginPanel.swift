import AppKit
import StatsCore
import SwiftUI
import UserNotifications
import os

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
    @State private var offerSettings = false

    var body: some View {
        DisclosureGroup("프로세스 트리", isExpanded: $showTree) {
            VStack(alignment: .leading) {
                KeyChoice(label: "정렬 기준", options: OriginMetric.allCases.map { ($0, $0.label) }, selection: $metric)
                ProcessTreeView(tree: tree, metric: metric)
                OriginThreshold(metric: metric).id(metric)
                KeyToggle(title: "선택한 기준 도달 시 알림", isOn: Binding(get: { enabled }, set: toggle), disabled: requesting)
                if !message.isEmpty {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    if offerSettings {
                        KeyButton(title: "알림 설정 열기") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.oozoofrog.aistats")!)
                        }
                    }
                }
            }.padding(.leading, 6)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Ink.text.color)
    }

    private func toggle(_ value: Bool) {
        message = ""
        offerSettings = false
        guard value else { enabled = false; return }
        guard OriginAlertRule.supportsNotifications else {
            message = "알림을 사용하려면 AIStats 앱을 여세요."
            return
        }
        requesting = true
        Task { @MainActor in
            defer { requesting = false }
            do {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                switch settings.authorizationStatus {
                case .authorized:
                    enabled = true
                case .notDetermined, .provisional:
                    enabled = try await center.requestAuthorization(options: [.alert])
                default:
                    enabled = false
                }
                if !enabled { message = "AIStats 알림을 허용한 뒤 다시 켜세요."; offerSettings = true }
            } catch {
                let error = error as NSError
                Logger(subsystem: "com.oozoofrog.aistats", category: "notifications")
                    .error("requestAuthorization failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
                message = "알림 권한을 확인할 수 없습니다. 시스템 설정 › 알림에서 AIStats 항목을 확인한 뒤 다시 켜세요."
                offerSettings = true
            }
        }
    }
}

/// Segmented choice that Tab reaches without macOS Keyboard Navigation; Left and Right change the selection.
struct KeyChoice<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: S.xxs) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.value == selection
                Text(option.title)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, S.sm).padding(.vertical, S.xxs)
                    .foregroundStyle(on ? Ink.ground.color : Ink.text.color)
                    .background(on ? Ink.cyan.color : Ink.track.color, in: Chamfer(cut: S.xs))
                    .contentShape(Rectangle())
                    .onTapGesture { if selection != option.value { selection = option.value }; focused = true }
                    .id(option.value)
            }
        }
        .padding(S.xxs)
        .focusable().focusEffectDisabled().focused($focused)
        .overlay {
            if focused {
                Chamfer(cut: S.smallChamfer).strokeBorder(Ink.focus.color, lineWidth: S.focusStroke)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard !options.isEmpty else { return .ignored }
            let i = options.firstIndex { $0.value == selection } ?? 0
            let next = options[press.key == .leftArrow ? max(0, i - 1) : min(options.count - 1, i + 1)].value
            if next != selection { selection = next }
            return .handled
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].title).tag(options[$0].value) }
            }.pickerStyle(.radioGroup)
        }
    }
}

/// Button that Tab reaches without macOS Keyboard Navigation; Space or Return activates it.
struct KeyButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PanelButtonStyle(kind: .secondary, focused: focused))
            .focusable().focusEffectDisabled().focused($focused)
            .onKeyPress(keys: [.space, .return]) { _ in action(); return .handled }
    }
}

/// Checkbox that Tab reaches without macOS Keyboard Navigation; Space toggles it.
struct KeyToggle: View {
    let title: String
    @Binding var isOn: Bool
    var disabled = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: S.xs) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .foregroundStyle(isOn ? Ink.cyan.color : Ink.muted.color)
            Text(title)
        }
        .padding(S.xxs)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { focused = true; isOn.toggle() } }
        .focusable().focusEffectDisabled().focused($focused)
        .overlay {
            if focused {
                Chamfer(cut: S.smallChamfer).strokeBorder(Ink.focus.color, lineWidth: S.focusStroke)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onKeyPress(.space) { guard !disabled else { return .ignored }; isOn.toggle(); return .handled }
        .opacity(disabled ? 0.5 : 1)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn).disabled(disabled) }
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
