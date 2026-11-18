import StatsCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MetricsSection(model: model)
            Divider()
            AgentSection(model: model)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("종료") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

// MARK: - Metrics

private struct MetricsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let s = model.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                if s.isAvailable("cpu") {
                    MetricRow(title: "CPU", value: Format.percent(s.cpu.usagePercent),
                              detail: String(format: "부하 %.2f", s.cpu.loadAverage1m), fraction: s.cpu.usagePercent / 100)
                } else {
                    MetricRow(title: "CPU", value: "측정 실패", detail: String(format: "부하 %.2f", s.cpu.loadAverage1m),
                              fraction: 0, unavailable: true)
                }
                Sparkline(values: model.cpuHistory, length: AppModel.sparklineLength)
                    .frame(height: 22)
                    .accessibilityLabel("최근 2분 CPU 사용률")
                if s.isAvailable("memory") {
                    MetricRow(title: "메모리", value: Format.percent(s.memory.usedPercent),
                              detail: "\(Format.bytes(s.memory.usedBytes)) / \(Format.bytes(s.memory.totalBytes))" + pressureNote(s),
                              fraction: s.memory.usedPercent / 100,
                              warning: s.isAvailable("memoryPressure") && (s.memory.pressure == "warning" || s.memory.pressure == "critical"))
                } else {
                    MetricRow(title: "메모리", value: "측정 실패", detail: "전체 \(Format.bytes(s.memory.totalBytes))" + pressureNote(s),
                              fraction: 0, unavailable: true)
                }
                if let d = s.disk, d.totalBytes > 0, s.isAvailable("disk") {
                    MetricRow(title: "디스크", value: Format.bytes(d.availableBytes) + " 남음",
                              detail: "전체 \(Format.bytes(d.totalBytes))",
                              fraction: Double(d.totalBytes - min(d.totalBytes, d.availableBytes)) / Double(d.totalBytes),
                              warning: d.availableBytes < 10 * 1024 * 1024 * 1024)
                } else {
                    MetricRow(title: "디스크", value: "측정 실패", detail: "", fraction: 0, unavailable: true)
                }
                InfoRow(title: "네트워크") {
                    if s.isAvailable("network") {
                        Text("↓ \(Format.rate(s.network.receivedBytesPerSecond))")
                        Text("↑ \(Format.rate(s.network.sentBytesPerSecond))")
                    } else {
                        Text("측정 실패").foregroundStyle(.secondary)
                    }
                }
                if let b = s.battery {
                    InfoRow(title: "배터리") {
                        Text("\(b.percent)%")
                        Text(b.isCharging ? "충전 중" : (b.powerSource == "AC Power" ? "전원 연결됨" : "배터리 사용"))
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.topProcesses.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.topProcesses, id: \.pid) { p in
                            HStack {
                                Text(p.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(String(format: "%.1f%%", p.cpuPercent)).monospacedDigit()
                                Text(Format.bytes(p.memoryBytes)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
                if s.thermalState == "serious" || s.thermalState == "critical" {
                    Label("발열로 성능이 제한되고 있습니다", systemImage: "thermometer.high")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("측정 중…").foregroundStyle(.secondary) }
        }
    }

    private func pressureNote(_ s: Snapshot) -> String {
        guard s.isAvailable("memoryPressure") else { return " · 압박 측정 실패" }
        switch s.memory.pressure {
        case "warning": return " · 압박 경고"
        case "critical": return " · 압박 심각"
        default: return ""
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double
    var warning = false
    /// The reading failed: the value says so and the bar stays empty instead of showing 0.
    var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).frame(width: 56, alignment: .leading)
                Text(value).fontWeight(.semibold).foregroundStyle(unavailable ? .secondary : .primary)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())
            ProgressView(value: unavailable ? 0 : min(1, max(0, fraction)))
                .progressViewStyle(.linear)
                .tint(warning ? .orange : .accentColor)
                .opacity(unavailable ? 0.3 : 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InfoRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title).frame(width: 56, alignment: .leading)
            content
            Spacer()
        }
        .font(.callout.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let length: Int

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(1, length - 1))
            let offset = CGFloat(max(0, length - values.count)) * step
            Path { path in
                for (i, v) in values.suffix(length).enumerated() {
                    let point = CGPoint(x: offset + CGFloat(i) * step,
                                        y: geo.size.height * (1 - CGFloat(min(100, max(0, v)) / 100)))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Agents

private struct AgentSection: View {
    @ObservedObject var model: AppModel

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("에이전트").font(.headline)
                Spacer()
                Text(model.agents.isEmpty ? "실행 중인 세션 없음" : "세션 \(model.agents.count)개 사용 중")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(AgentTarget.allCases, id: \.self) { target in
                AgentRowView(model: model, target: target)
            }

            let others = model.otherClients
            if !others.isEmpty {
                Text("다른 클라이언트").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(others.prefix(4), id: \.name) { client in
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(client.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("세션 \(client.count)개").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if others.count > 4 {
                    Text("외 \(others.count - 4)개 클라이언트").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.recentCalls.isEmpty {
                Text("최근 호출").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(model.recentCalls) { call in
                    HStack(spacing: 6) {
                        Text(Self.timeFormatter.string(from: call.date)).monospacedDigit().foregroundStyle(.secondary)
                        Text(call.agent).lineLimit(1)
                        Spacer()
                        Text(Self.toolLabel(call)).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            if let error = model.recordingError {
                Label("기록을 저장하지 못해 에이전트가 최근 추이를 볼 수 없습니다: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func toolLabel(_ call: ActivityStore.Call) -> String {
        let detail = call.detail ?? ""
        switch call.tool {
        case "get_system_stats": return "현재 상태"
        case "get_top_processes":
            let parts = detail.split(separator: " ")
            let by = parts.first == "memory" ? "메모리" : "CPU"
            return "프로세스 \(parts.count > 1 ? parts[1] : "")개 · \(by)순"
        case "get_stats_history": return "추이 \(detail.replacingOccurrences(of: "m", with: "분"))"
        case "diagnose_system": return detail == "heavy_work" ? "작업 전 점검" : "느려짐 진단"
        case "find_processes": return "프로세스 찾기"
        case "track_processes":
            if detail.hasPrefix("start") { return "프로세스 추적 시작" }
            switch detail {
            case "status": return "추적 결과 조회"
            case "stop": return "추적 중지"
            case "list": return "추적 목록"
            default: return "프로세스 추적"
            }
        case "wait_for":
            switch detail {
            case "cpu_idle": return "조용해질 때까지 대기"
            case "process_exit": return "프로세스 종료 대기"
            case "memory_pressure_normal": return "메모리 압박 해소 대기"
            default: return "대기"
            }
        case "get_environment": return "환경 정보"
        default: return call.tool
        }
    }
}

/// One agent: whether AIStats is registered with it, and the buttons to change that.
private struct AgentRowView: View {
    @ObservedObject var model: AppModel
    let target: AgentTarget

    private var row: AppModel.AgentRow { model.registrations[target] ?? .init() }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(target.displayName).frame(width: 104, alignment: .leading)
                Text(stateText).foregroundStyle(.secondary).lineLimit(1)
                    .help([row.state?.detail, row.cliPath.map { "확인에 쓴 명령: \($0)" }].compactMap { $0 }.joined(separator: "\n"))
                Spacer(minLength: 4)
                if row.busy {
                    ProgressView().controlSize(.mini)
                } else {
                    buttons
                }
            }
            if let message = row.message {
                Text(message)
                    .foregroundStyle(row.messageIsError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 13)
            }
        }
        .font(.caption)
        .controlSize(.mini)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        switch row.state {
        case .notInstalled?:
            Button("연결") { model.perform(.connect, target) }
        case .installed?:
            Button("연결 해제") { model.perform(.disconnect, target) }
        case .pathUpdateNeeded?:
            Button("다시 연결") { model.perform(.connect, target) }
                .help("등록된 경로가 이 앱의 aistats와 다릅니다")
            Button("연결 해제") { model.perform(.disconnect, target) }
        case .checkFailed?:
            Button("다시 확인") { model.refreshRegistrations() }
        case .nameConflict?:
            Button("덮어쓰기…") { model.confirmReplace(target) }
                .help("이미 등록된 다른 aistats 명령을 이 앱의 것으로 바꿉니다(백업을 남김)")
        default:
            EmptyView()
        }
    }

    /// Registration state, plus how many sessions of this agent are using AIStats now.
    private var stateText: String {
        let n = model.sessionCount(target)
        let sessions = n > 0 ? " · 세션 \(n)개" : ""
        switch row.state {
        case nil: return "확인 중…"
        case .notInstalled?: return "연결 안 됨" + sessions
        case .installed?: return "등록됨" + sessions
        case .pathUpdateNeeded?: return "경로 바뀜" + sessions
        case .nameConflict?: return "다른 aistats 항목 있음" + sessions
        case .checkFailed?: return "확인 실패" + sessions
        case .agentNotFound?: return "설치 안 됨" + sessions
        }
    }

    private var dotColor: Color {
        switch row.state {
        case .installed?: return model.sessionCount(target) > 0 ? .green : .accentColor
        case .pathUpdateNeeded?, .checkFailed?, .nameConflict?: return .orange
        default: return .secondary.opacity(0.4)
        }
    }
}
