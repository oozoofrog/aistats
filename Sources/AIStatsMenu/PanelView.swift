import AppKit
import CoreText
import SwiftUI
import StatsCore

enum PanelFocus: Hashable {
    case row(AgentTarget)
    case action(AgentTarget, String)
    case quit
}

struct FocusRequest: Equatable {
    let id = UUID()
    let target: AgentTarget
}

final class PanelContent: ObservableObject {
    @Published var data: PanelData
    @Published var theme: Theme
    @Published var size: CGSize
    @Published var focusRequest: FocusRequest?
    let decoration: DecorationContext
    let cells: [EffectID: FrameCell]
    let perform: (AppModel.Action, AgentTarget) -> Void
    let refreshRegistrations: () -> Void
    let confirm: (AgentTarget) -> Void

    init(data: PanelData, theme: Theme, size: CGSize, decoration: DecorationContext,
         cells: [EffectID: FrameCell], perform: @escaping (AppModel.Action, AgentTarget) -> Void,
         refreshRegistrations: @escaping () -> Void, confirm: @escaping (AgentTarget) -> Void) {
        self.data = data
        self.theme = theme
        self.size = size
        self.decoration = decoration
        self.cells = cells
        self.perform = perform
        self.refreshRegistrations = refreshRegistrations
        self.confirm = confirm
    }

    func artwork(_ id: EffectID, _ artwork: Artwork) -> some View {
        MotionArtwork(cell: cells[id]!, artwork: artwork, decoration: decoration).equatable()
    }
}

struct PanelView: View {
    @ObservedObject var content: PanelContent
    var fixtureScrollOffset: CGFloat?
    @FocusState private var focus: PanelFocus?

    private var data: PanelData { content.data }
    private var screen: ScreenSnapshot { data.screen }

    var body: some View {
        VStack(alignment: .leading, spacing: S.sectionGap) {
            header
            if let fixtureScrollOffset {
                GeometryReader { viewport in
                    bodyContents.fixedSize(horizontal: false, vertical: true)
                        .offset(y: -fixtureScrollOffset)
                        .frame(height: viewport.size.height, alignment: .top)
                        .clipped()
                }
            } else {
                ScrollView { bodyContents }
                    .accessibilityIdentifier("panel-body")
            }
            footer
        }
        .padding(.vertical, S.panelInset)
        .frame(width: content.size.width, height: content.size.height)
        .background {
            Ink.ground.color.overlay { gutters }
        }
        .foregroundStyle(Ink.text.color)
        .environment(\.panelTheme, content.theme)
        .onChange(of: content.focusRequest, initial: true) { _, request in
            guard let request, content.decoration.exposure.isCurrent else { return }
            let row = screen.registrations[request.target]
            if case .nameConflict? = row?.state, row?.busy == false {
                focus = .action(request.target, "덮어쓰기…")
            } else {
                focus = .row(request.target)
            }
        }
        .overlay(alignment: .topLeading) {
            if PanelTrace.isEnabled {
                CommitMarker(decoration: content.decoration, revision: screen.revision)
                    .frame(width: S.baseStroke, height: S.baseStroke)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }

    private var bodyContents: some View {
        VStack(alignment: .leading, spacing: S.sectionGap) {
            if !data.warnings.isEmpty { warnings }
            if let cpu = data.metrics[.cpu] {
                cpuCard(cpu)
                resources
            } else {
                Label("측정 중…", systemImage: "waveform.path")
                    .font(Theme.TypeRole.body.font)
                    .foregroundStyle(content.theme.detail)
            }
            if !screen.topProcesses.isEmpty { processes }
            if let tree = screen.tree { OriginPanel(tree: tree) }
            agents
            if !screen.otherClients.isEmpty { clients }
            if !screen.recentCalls.isEmpty { calls }
            if let error = screen.recordingError { recording(error) }
        }
        .padding(.horizontal, S.panelInset)
        .padding(.vertical, S.xs)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: S.xs) {
            instrument("AISTATS", role: .wordmark, color: .cyan)
                .accessibilityAddTraits(.isHeader)
            heading("// SYSTEM", "시스템")
        }
        .padding(.horizontal, S.panelInset)
    }

    private var gutters: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                sideGutter(.left)
                Spacer(minLength: 0)
                sideGutter(.right)
            }
            .padding(.horizontal, S.gutterInset)
            if content.theme.options.gutterEffects {
                content.artwork(.shimmer, .shimmer)
                    .frame(height: S.gutter)
                    .padding([.bottom, .horizontal], S.gutterInset)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sideGutter(_ side: GutterSide) -> some View {
        ZStack {
            if content.theme.options.gutterEffects {
                content.artwork(.grid, .grid(side))
                StaticArtwork(artwork: .scanlines(side), decoration: content.decoration).equatable()
            }
            content.artwork(.boot, .bootScan(side))
        }
        .frame(width: S.gutter)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                HStack(spacing: S.iconGap) {
                    Text("종료")
                    Text("⌘Q").font(Theme.TypeRole.data.font).accessibilityHidden(true)
                }
            }
            .buttonStyle(PanelButtonStyle(focused: focus == .quit))
            .focusEffectDisabled()
            .focused($focus, equals: .quit)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, S.panelInset)
    }

    private func heading(_ latin: String, _ korean: String) -> some View {
        VStack(alignment: .leading, spacing: S.xxs) {
            instrument(latin, color: .magenta)
            Text(korean).font(Theme.TypeRole.heading.font)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func instrument(_ title: String, role: Theme.TypeRole = .instrument, color: Ink = .muted) -> some View {
        InstrumentLabel(layout: InstrumentLayout.named(title, role: role), color: color,
                        boot: content.cells[.boot]!, decoration: content.decoration).equatable()
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: S.rowGap) {
            content.artwork(.hazard, .hazard)
                .frame(height: S.hazardHeight)
            ForEach(data.warnings, id: \.symbol) { warning in
                HStack(alignment: .top, spacing: S.iconGap) {
                    Glyph(symbol: warning.symbol, color: .amber, size: S.warningGlyph)
                    Text(warning.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Theme.TypeRole.body.font)
        .padding(S.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(outline: .amber, opacity: 1) }
        .background {
            if !content.theme.options.increaseContrast {
                content.artwork(.warning, .warning).padding(-FX.warningOffset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("경고")
    }

    private func cpuCard(_ metric: MetricDisplay) -> some View {
        VStack(alignment: .leading, spacing: S.rowGap) {
            VStack(alignment: .leading, spacing: S.rowGap) {
                instrument("CPU")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: S.md) {
                        cpuReading(metric).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: S.xs)
                        detail(metric.detail).fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: S.xxs) {
                        cpuReading(metric)
                        detail(metric.detail)
                    }
                }
                track(.cpu, metric)
            }
            .accessibilityElement(children: .combine)
            sparkline
        }
        .padding(S.cardInset)
        .background { CardSurface(outline: .cyan, opacity: FX.cyanOutline, glow: true) }
        .overlay { content.artwork(.reading(.cpu), .edge(S.cardChamfer)) }
        .overlay { brackets(0) }
    }

    private func cpuReading(_ metric: MetricDisplay) -> some View {
        Group {
            if metric.available, metric.reading.hasSuffix("%") {
                (Text(metric.reading.dropLast()).font(Theme.TypeRole.cpu.font)
                 + Text("%").font(Theme.TypeRole.percent.font))
                    .foregroundStyle(Ink.cyan.color)
            } else {
                Text(metric.reading).font(Theme.TypeRole.reading.font)
                    .foregroundStyle(content.theme.detail)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sparkline: some View {
        VStack(spacing: S.xxs) {
            ZStack {
                Ink.ground.color
                if !content.theme.options.reduceMotion && screen.cpuHistory.count >= 2 {
                    content.artwork(.chartScan, .chartMask)
                }
                content.artwork(.chartChange, .chart)
            }
            .frame(height: S.plotHeight)
            HStack {
                detail("이전")
                Spacer()
                detail("최신")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("최근 2분 CPU 사용률")
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: S.tileGap) {
            if let memory = data.metrics[.memory] { resource(.memory, "MEM", "메모리", memory) }
            if let disk = data.metrics[.disk] { resource(.disk, "DISK", "디스크", disk) }
            HStack(alignment: .top, spacing: S.tileGap) {
                if let net = data.metrics[.network] { tile(.network, "NET", "네트워크", net) }
                if let battery = data.metrics[.battery] { tile(.battery, "BATTERY", "배터리", battery) }
            }
        }
        .padding(S.cardInset)
        .background { CardSurface() }
        .overlay { brackets(1) }
    }

    private func resource(_ id: MetricID, _ latin: String, _ title: String, _ metric: MetricDisplay) -> some View {
        VStack(alignment: .leading, spacing: S.xxs) {
            HStack(spacing: S.iconGap) {
                instrument(latin)
                Text(title)
                if metric.warning { Glyph(symbol: "exclamationmark.triangle", color: .amber) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: S.md) {
                    secondaryReading(metric).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: S.xs)
                    detail(metric.detail).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: S.xxs) {
                    secondaryReading(metric)
                    if !metric.detail.isEmpty { detail(metric.detail) }
                }
            }
            track(id, metric)
        }
        .font(Theme.TypeRole.body.font)
        .padding(S.xs)
        .overlay { content.artwork(.reading(id), .edge(S.smallChamfer)) }
        .accessibilityElement(children: .combine)
    }

    private func tile(_ id: MetricID, _ latin: String, _ title: String, _ metric: MetricDisplay) -> some View {
        VStack(alignment: .leading, spacing: S.xxs) {
            instrument(latin)
            HStack(spacing: S.iconGap) {
                Text(title)
                if !metric.available { Glyph(symbol: "minus.square", color: .muted) }
            }
            Text(metric.reading)
                .font((id == .network ? Theme.TypeRole.data : .reading).font)
                .foregroundStyle(metric.available ? Ink.cyan.color : content.theme.detail)
                .fixedSize(horizontal: false, vertical: true)
            if !metric.detail.isEmpty { detail(metric.detail) }
        }
        .font(Theme.TypeRole.body.font)
        .padding(S.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { CardSurface(cut: S.smallChamfer, opacity: FX.inactiveOutline) }
        .overlay { content.artwork(.reading(id), .edge(S.smallChamfer)) }
        .accessibilityElement(children: .combine)
    }

    private func secondaryReading(_ metric: MetricDisplay) -> some View {
        Text(metric.reading)
            .font((metric.available ? Theme.TypeRole.reading : .body).font)
            .foregroundStyle(metric.available ? (metric.warning ? Ink.amber : .cyan).color : content.theme.detail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ value: String) -> some View {
        Text(value).font(Theme.TypeRole.body.font).foregroundStyle(content.theme.detail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func track(_ id: MetricID, _ metric: MetricDisplay) -> some View {
        content.artwork(.segment(id), .segments(metric.warning ? .amber : .cyan, metric.available))
            .frame(height: S.slotHeight)
    }

    private func brackets(_ group: Int) -> some View {
        content.artwork(.boot, .brackets(group)).padding(-FX.bracketSlide)
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: S.rowGap) {
            heading("// PROCESSES", "CPU 상위 프로세스")
            Grid(alignment: .leading, horizontalSpacing: S.md, verticalSpacing: S.rowGap) {
                ForEach(data.processRows) { row in
                    GridRow {
                        Text(verbatim: row.name).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
                        Text(verbatim: row.cpu).gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                        Text(verbatim: row.memory).foregroundStyle(content.theme.detail).gridColumnAlignment(.trailing)
                            .accessibilityHidden(true)
                    }
                }
            }
            .font(Theme.TypeRole.data.font)
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: S.rowGap) {
            HStack(alignment: .bottom, spacing: S.md) {
                heading("// AGENTS", "에이전트").layoutPriority(1)
                Spacer(minLength: 0)
                detail(screen.agents.isEmpty ? "실행 중인 세션 없음" : "세션 \(screen.agents.count)개 사용 중")
            }
            VStack(alignment: .leading, spacing: S.rowGap) {
                ForEach(AgentTarget.allCases, id: \.self) { target in
                    let row = data.agentRows[target]!
                    AgentRowView(content: content, target: target, row: row.registration,
                                 sessions: row.sessions, focus: $focus)
                }
            }
            .padding(S.cardInset)
            .background { CardSurface() }
            .overlay { brackets(2) }
        }
    }

    private var clients: some View {
        let others = screen.otherClients
        return VStack(alignment: .leading, spacing: S.rowGap) {
            heading("// CLIENTS", "다른 클라이언트")
            ForEach(others.prefix(4), id: \.name) { client in
                HStack(spacing: S.iconGap) {
                    Glyph(symbol: "diamond.fill", color: .green)
                    Text(client.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    detail("세션 \(client.count)개")
                }
                .accessibilityElement(children: .combine)
            }
            if others.count > 4 { detail("외 \(others.count - 4)개 클라이언트") }
        }
        .font(Theme.TypeRole.body.font)
    }

    private static let callTime: DateFormatter = {
        let format = DateFormatter()
        format.dateStyle = .none
        format.timeStyle = .medium
        return format
    }()

    private var calls: some View {
        VStack(alignment: .leading, spacing: S.rowGap) {
            heading("// CALLS", "최근 호출")
            ForEach(screen.recentCalls) { call in
                HStack(alignment: .firstTextBaseline, spacing: S.iconGap) {
                    Text(Self.callTime.string(from: call.date)).font(Theme.TypeRole.data.font)
                        .foregroundStyle(content.theme.detail)
                    Text(call.agent).foregroundStyle(Ink.magenta.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: S.xxs)
                    detail(Self.toolLabel(call))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(Theme.TypeRole.body.font)
    }

    private func recording(_ error: String) -> some View {
        HStack(alignment: .top, spacing: S.iconGap) {
            Glyph(symbol: "exclamationmark.triangle", color: .amber, size: S.warningGlyph)
            Text("기록을 저장하지 못해 에이전트가 최근 추이를 볼 수 없습니다: \(error)")
                .font(Theme.TypeRole.body.font)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(S.cardInset)
        .background { CardSurface(outline: .amber, opacity: 1) }
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

struct Glyph: View {
    let symbol: String
    let color: Ink
    var size = S.statusGlyph

    var body: some View {
        Image(systemName: symbol)
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color.color)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

struct InstrumentLabel: View, Equatable {
    let layout: InstrumentLayout
    let color: Ink
    let boot: FrameCell
    let decoration: DecorationContext
    @Environment(\.panelTheme) private var theme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layout == rhs.layout && lhs.color == rhs.color && lhs.boot === rhs.boot
            && lhs.decoration.exposure === rhs.decoration.exposure
    }

    var body: some View {
        let ink = theme.options.increaseContrast && color == .muted ? Ink.text : color
        MotionArtwork(cell: boot, artwork: .label(layout, ink), decoration: decoration)
            .equatable()
            .frame(width: layout.width, height: layout.height)
            .accessibilityRepresentation { Text(verbatim: layout.title) }
    }
}

final class InstrumentLayout: Equatable {
    private struct GlyphLine {
        let line: CTLine
        let width: CGFloat

        init(_ character: Character, font: NSFont) {
            line = CTLineCreateWithAttributedString(NSAttributedString(
                string: String(character), attributes: [
                    .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]))
            width = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
    }

    private struct Cell {
        let glyph: GlyphLine
        let character: Character
        let letter: Int
        let width: CGFloat
    }

    let title: String
    let width: CGFloat
    let height: CGFloat
    private let baseline: CGFloat
    private let cells: [Cell]
    private let glyphs: [Character: GlyphLine]
    private let spacing: CGFloat

    private static let pools = Dictionary(uniqueKeysWithValues: [Theme.TypeRole.wordmark, .instrument].map { role in
        let font = role.nsFont
        let glyphs = Dictionary(uniqueKeysWithValues: MotionMath.glyphPool.map { ($0, GlyphLine($0, font: font)) })
        return (role, glyphs)
    })
    private static let known = Dictionary(uniqueKeysWithValues:
        ["AISTATS", "// SYSTEM", "// PROCESSES", "// AGENTS", "// CLIENTS", "// CALLS", "CPU", "MEM", "DISK", "NET", "BATTERY"]
            .map { ($0, InstrumentLayout($0, role: $0 == "AISTATS" ? .wordmark : .instrument)) })

    static func named(_ title: String, role: Theme.TypeRole) -> InstrumentLayout {
        known[title] ?? InstrumentLayout(title, role: role)
    }

    static func == (lhs: InstrumentLayout, rhs: InstrumentLayout) -> Bool { lhs === rhs }

    private init(_ title: String, role: Theme.TypeRole) {
        self.title = title
        let font = role.nsFont
        let pool = Self.pools[role] ?? [:]
        glyphs = pool
        let widest = pool.values.map(\.width).max() ?? 0
        let tracking = role.tracking
        spacing = tracking
        var letter = 0
        cells = title.map { glyph in
            let line = GlyphLine(glyph, font: font)
            if glyph == "/" || glyph == " " {
                return Cell(glyph: line, character: glyph, letter: 0, width: line.width + tracking)
            }
            letter += 1
            return Cell(glyph: line, character: glyph, letter: letter, width: max(line.width, widest) + tracking)
        }
        width = cells.reduce(0) { $0 + $1.width }
        height = ceil(font.ascender - font.descender + font.leading)
        baseline = (height + font.ascender + font.descender) / 2
    }

    func visibleFrame(_ frame: EffectFrame) -> EffectFrame {
        guard case .boot(let elapsed, let titles) = frame, titles.contains(title),
              elapsed < Double(cells.last?.letter ?? 0) * Motion.letterDeadline else { return .none }
        return frame
    }

    func draw(_ context: CGContext, color: CGColor, frame: EffectFrame) {
        let elapsed = frame.elapsed ?? Motion.decode
        context.translateBy(x: 0, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.setFillColor(color)
        var x: CGFloat = 0
        for cell in cells {
            let character = MotionMath.decode(cell.character, letter: cell.letter, elapsed: elapsed)
            let glyph = character == cell.character ? cell.glyph : glyphs[character] ?? cell.glyph
            context.textPosition = CGPoint(x: x + (cell.width - spacing - glyph.width) / 2, y: 0)
            CTLineDraw(glyph.line, context)
            x += cell.width
        }
    }
}

private struct AgentRowView: View {
    let content: PanelContent
    let target: AgentTarget
    let row: AppModel.AgentRow
    let sessions: Int
    @FocusState.Binding var focus: PanelFocus?
    @Environment(\.panelTheme) private var theme

    private var stateHelp: String {
        [row.state?.detail, row.cliPath.map { "확인에 쓴 명령: \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }

    private var state: String {
        guard let state = row.state else { return "확인 중…" }
        return AppModel.stateLabel(state) + (sessions > 0 ? " · 세션 \(sessions)개" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: S.xxs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: S.xs) {
                    status.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: S.xxs)
                    actions.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: S.xxs) {
                    status
                    actions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let operation = row.operation, row.state != nil {
                Text(operation).foregroundStyle(theme.detail)
                    .padding(.leading, S.iconGap)
            }
            if let message = row.message {
                HStack(alignment: .top, spacing: S.iconGap) {
                    Glyph(symbol: row.messageIsError ? "xmark.square" : "checkmark", color: row.messageIsError ? .magenta : .green)
                    Text(message)
                        .foregroundStyle(row.messageIsError ? Ink.magenta.color : theme.detail)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(row.messageDetail ?? "")
                }
                .padding(.horizontal, S.xs)
            }
        }
        .font(Theme.TypeRole.body.font)
        .background {
            Chamfer(cut: S.smallChamfer).strokeBorder((theme.options.increaseContrast ? Ink.focus.color : Ink.muted.color.opacity(FX.inactiveOutline)),
                                                      lineWidth: theme.boundary)
                .padding(-S.xxs)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay { content.artwork(.result(target), .edge(S.smallChamfer)).padding(-S.xxs) }
        .accessibilityElement(children: .contain)
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: S.iconGap) {
            stateGlyph
            VStack(alignment: .leading, spacing: S.xxs) {
                Text(target.displayName)
                Text(state).foregroundStyle(theme.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(stateHelp)
            }
        }
        .padding(S.xs)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .row(target))
        .overlay {
            if focus == .row(target) {
                Chamfer(cut: S.smallChamfer).strokeBorder(Ink.focus.color, lineWidth: S.focusStroke)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var stateGlyph: some View {
        if row.busy || row.state == nil {
            content.artwork(.busy(target), .busy)
                .frame(width: FX.busyGlyph, height: FX.busyGlyph)
        } else {
            switch row.state {
            case .installed?: Glyph(symbol: sessions > 0 ? "diamond.fill" : "diamond", color: sessions > 0 ? .green : .cyan)
            case .notInstalled?: Glyph(symbol: "circle", color: .muted)
            case .agentNotFound?: Glyph(symbol: "minus.square", color: .muted)
            case .pathUpdateNeeded?, .nameConflict?, .checkFailed?:
                Glyph(symbol: "exclamationmark.triangle", color: .amber)
            case nil: EmptyView()
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if !row.busy {
            switch row.state {
            case .notInstalled?:
                button("연결", kind: .primary) { content.perform(.connect, target) }
            case .installed?:
                button("연결 해제") { content.perform(.disconnect, target) }
            case .pathUpdateNeeded?:
                HStack(spacing: S.xxs) {
                    button("다시 연결", kind: .primary, help: "등록된 경로가 이 앱의 aistats와 다릅니다") {
                        content.perform(.connect, target)
                    }
                    button("연결 해제") { content.perform(.disconnect, target) }
                }
            case .checkFailed?:
                button("다시 확인", action: content.refreshRegistrations)
            case .nameConflict?:
                button("덮어쓰기…", help: "이미 등록된 다른 aistats 명령을 이 앱의 것으로 바꿉니다(백업을 남김)") {
                    content.confirm(target)
                }
            default: EmptyView()
            }
        }
    }

    private func button(_ label: String, kind: PanelButtonKind = .secondary, help: String = "",
                        action: @escaping () -> Void) -> some View {
        let id = PanelFocus.action(target, label)
        return Button(label, action: action)
            .buttonStyle(PanelButtonStyle(kind: kind, focused: focus == id))
            .focusEffectDisabled()
            .focused($focus, equals: id)
            .help(help)
    }
}

private struct CommitMarker: NSViewRepresentable {
    let decoration: DecorationContext
    let revision: UInt64

    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ view: Marker, context: Context) {
        view.decoration = decoration
        if view.revision != revision {
            view.revision = revision
            view.needsDisplay = true
        }
    }

    final class Marker: NSView {
        var decoration: DecorationContext?
        var revision: UInt64?

        override func draw(_ rect: NSRect) {
            guard let decoration, decoration.exposure.isCurrent else { return }
            PanelTrace.event("Render commit", decoration.host, revision.map(String.init) ?? "")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
