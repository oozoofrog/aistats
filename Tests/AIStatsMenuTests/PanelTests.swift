import Foundation
import StatsCore
import Testing
@testable import AIStatsMenu

@Test func segmentLightsOnlyTheLeadingFraction() {
    let fraction = 4.5 / 24
    #expect(MotionMath.segment(fraction, slot: 3) == 1)
    #expect(MotionMath.segment(fraction, slot: 4) == 0.5)
    #expect(MotionMath.segment(fraction, slot: 5) == 0)
    #expect(MotionMath.segment(-1, slot: 0) == 0)
    #expect(MotionMath.segment(2, slot: 23) == 1)
}

@Test func labelDecodeUsesTheOrderedPoolAndLetterDeadlines() {
    #expect(MotionMath.decode("A", letter: 1, elapsed: 0) == "0")
    #expect(MotionMath.decode("S", letter: 3, elapsed: 0.060) == "3")
    #expect(MotionMath.decode("A", letter: 1, elapsed: 0.035) == "0")
    #expect(MotionMath.decode("A", letter: 1, elapsed: 0.036) == "A")
    #expect(MotionMath.decode("S", letter: 3, elapsed: 0.108) == "S")
    #expect(MotionMath.decode("/", letter: 0, elapsed: 0.060) == "/")
    #expect(MotionMath.decode("S", letter: 9, elapsed: 0.360) == "S")
}

@Test func quietChangesTheDeadlinePolicyWithoutChangingPhase() {
    var quiet = QuietPeriod()
    quiet.input(at: 20)
    #expect(!quiet.contains(31.999))
    #expect(quiet.contains(32))
    #expect(EffectID.grid.fps(quiet: quiet.contains(32)) == 8)
    #expect(EffectID.shimmer.fps(quiet: true) == 8)
    #expect(EffectID.chartScan.fps(quiet: true) == 10)
    #expect(EffectID.hazard.fps(quiet: true) == 15)
    #expect(EffectID.busy(.codex).fps(quiet: true) == 15)
    quiet.input(at: 32)
    quiet.input(at: 30)
    #expect(EffectID.grid.fps(quiet: quiet.contains(32)) == 15)
    var loop = LoopPhase()
    #expect(loop.draw(at: 20, period: 16) == 0)
    #expect(loop.draw(at: 32, period: 16) == 0.75)
    #expect(loop.draw(at: 36, period: 16) == 0)
}

@Test func phasePauseUsesTheLastDrawnFrame() {
    var loop = LoopPhase()
    #expect(loop.draw(at: 0, period: 4) == 0)
    #expect(loop.draw(at: 1, period: 4) == 0.25)
    _ = loop.draw(at: 1.5, period: 4)
    loop.pause(at: 0.25)
    #expect(loop.draw(at: 8, period: 4) == 0.25)
    #expect(loop.draw(at: 9, period: 4) == 0.5)
}

@Test func processGenerationInvalidatesAtLossOfLastHost() {
    let gate = ProcessGeneration()
    #expect(gate.ticket() == nil)
    #expect(gate.setExposed("popover", true) == .first)
    let scan = gate.ticket()
    #expect(gate.setExposed("window", true) == .unchanged)
    #expect(gate.setExposed("popover", false) == .unchanged)
    #expect(gate.allows(scan))
    #expect(gate.setExposed("window", false) == .last)
    #expect(!gate.allows(scan))
    #expect(gate.setExposed("window", true) == .first)
    #expect(!gate.allows(scan))
    #expect(gate.allows(gate.ticket()))
}

@Test func edgeTransitionsStartAtTheDisplayedColorAndAlpha() {
    let displayed = EdgeSample.result(from: .init(rgb: Ink.green.rgb, alpha: 0), to: Ink.green.rgb, elapsed: 0.030)
    #expect(EdgeSample.result(from: displayed, to: Ink.magenta.rgb, elapsed: 0) == displayed)
    #expect(EdgeSample.result(from: displayed, to: Ink.magenta.rgb, elapsed: 0.060) == .init(rgb: Ink.magenta.rgb, alpha: 0.22))
    #expect(EdgeSample.result(from: displayed, to: Ink.magenta.rgb, elapsed: 0.240).alpha < 0.000_001)
    let reading = EdgeSample.reading(from: 0, elapsed: 0.080)
    #expect(EdgeSample.reading(from: reading.alpha, elapsed: 0).alpha == reading.alpha)
    #expect(EdgeSample.reading(from: reading.alpha, elapsed: 0.040).alpha == 0.24)
    #expect(EdgeSample.reading(from: reading.alpha, elapsed: 0.140).alpha < 0.000_001)
}

@Test func chartRetargetKeepsSurvivingPointPositionAndIncomingOpacity() {
    let input = (1...60).map { CPUPoint(id: UInt64($0), value: Double($0)) }
    let first = PlotPoint.settled(input)
    let second = PlotPoint.settled(input + [CPUPoint(id: 61, value: 92)])
    let third = PlotPoint.settled(input + [CPUPoint(id: 61, value: 92), CPUPoint(id: 62, value: 10)])
    let middle = Array(PlotFrame.transition(PlotTransition(from: first, to: second), MotionMath.ease(0.5)))
    let change = PlotTransition(from: middle, to: third)
    let retarget = PlotFrame.transition(change, 0)
    #expect(first.first?.slot == 0)
    #expect(PlotPoint.settled([input[0]])[0].slot == 59)
    #expect(second.count == 60)
    #expect(Array(retarget.dropLast()) == middle)
    #expect(retarget.last?.alpha == 0)
    #expect(retarget.last?.value == 0.10)
    #expect(Array(PlotFrame.transition(change, 1).suffix(60)) == third)
}

@Test @MainActor func bootWaitsForExposureAndDoesNotReplayOnResume() {
    var time = 0.0
    let clock = AnimationClock(time: { time })
    let host = HostMotion(host: "window", clock: clock)
    host.opened()
    #expect(host.nextDeadline(at: 1) == nil)
    time = 1
    let first = Exposure()
    let data = PanelData(ScreenSnapshot())
    host.expose(first, data: data)
    #expect(host.cells[.boot]?.frame.elapsed == 0)
    host.cells[.boot]?.recordDraw(host.cells[.boot]?.frame)
    host.tick(1.1)
    #expect((host.cells[.boot]?.frame.elapsed ?? 0) > 0)
    first.invalidate()
    host.pause(closing: false)
    #expect(host.nextDeadline(at: 4) == nil)
    time = 4
    host.expose(Exposure(), data: data)
    #expect(host.cells[.boot]?.frame == EffectFrame.none)
    host.pause(closing: true)
}

@Test @MainActor func reduceMotionDiscardsPendingBootAndKeepsOtherHostIndependent() {
    var time = 0.0
    let clock = AnimationClock(time: { time })
    let first = HostMotion(host: "popover", clock: clock)
    let second = HostMotion(host: "window", clock: clock)
    first.opened()
    first.settings(DisplayOptions(reduceMotion: true))
    first.settings(DisplayOptions())
    let data = PanelData(ScreenSnapshot())
    first.expose(Exposure(), data: data)
    second.expose(Exposure(), data: data)
    #expect(first.cells[.boot]?.frame == EffectFrame.none)
    first.cells[.grid]?.recordDraw(.phase(0))
    second.cells[.grid]?.recordDraw(.phase(0))
    time = 4
    first.tick(time)
    second.tick(time)
    first.cells[.grid]?.recordDraw(first.cells[.grid]?.frame)
    first.settings(DisplayOptions(reduceMotion: true))
    #expect(first.nextDeadline(at: time) == nil)
    time = 8
    second.tick(time)
    #expect(second.cells[.grid]?.frame.phase == 0.5)
    first.settings(DisplayOptions())
    #expect(first.cells[.grid]?.frame.phase == 0.25)
    first.pause(closing: true)
    second.pause(closing: true)
}

@Test func warningAndUnavailableFixturesPreserveTextAndOrder() throws {
    var fixture = try PanelFixtures.screen(warning: true)
    fixture.sample?.unavailable = ["cpu", "memory", "network"]
    let data = PanelData(fixture)
    #expect(data.warnings.map(\.text) == ["발열로 성능이 제한되고 있습니다", "메모리 압박 심각", "디스크 여유 10 GiB 미만"])
    #expect(data.metrics[.cpu]?.reading == "측정 실패")
    #expect(data.metrics[.cpu]?.detail == "부하 3.12")
    #expect(data.metrics[.cpu]?.fraction == nil)
    #expect(data.metrics[.memory]?.detail.hasSuffix(" · 압박 심각") == true)
    #expect(data.metrics[.network]?.reading == "측정 실패")
    #expect(data.metrics[.disk]?.reading.hasSuffix(" 남음") == true)
    #expect(data.metrics[.battery]?.detail == "배터리 사용")
    fixture.sample?.unavailable = ["memoryPressure", "disk"]
    let partial = PanelData(fixture)
    #expect(partial.warnings == [.thermal])
    #expect(partial.metrics[.memory]?.detail.hasSuffix(" · 압박 측정 실패") == true)
}

@Test func diskWarningUsesAFixedGiBThresholdAndIgnoresCPU() throws {
    var fixture = try PanelFixtures.screen()
    fixture.sample?.cpu.usagePercent = 100
    fixture.sample?.disk?.availableBytes = 10 * 1024 * 1024 * 1024
    #expect(PanelData(fixture).warnings.isEmpty)
    fixture.sample?.disk?.availableBytes -= 1
    #expect(PanelData(fixture).warnings == [.disk])
    fixture.sample?.disk?.totalBytes = 0
    #expect(PanelData(fixture).warnings.isEmpty)
}

@Test func menuGlyphDescriptionsUseTheSpecifiedOrder() {
    #expect(StatusGlyphs(activity: false, warning: false).descriptions.isEmpty)
    #expect(StatusGlyphs(activity: true, warning: false).descriptions == ["에이전트가 조회 중"])
    #expect(StatusGlyphs(activity: false, warning: true).descriptions == ["시스템 경고"])
    #expect(StatusGlyphs(activity: true, warning: true).descriptions == ["에이전트가 조회 중", "시스템 경고"])
}

@Test func consentCapturesTheOriginalRedactedTextAndFingerprint() throws {
    var row = AppModel.AgentRow(state: .installed, fingerprint: "0123456789ab")
    #expect(ReplacementConsent(target: .codex, row: row) == nil)
    let summary = String(repeating: "명령…", count: 135)
    row.state = .nameConflict(registered: summary)
    let consent = try #require(ReplacementConsent(target: .codex, row: row))
    row.fingerprint = nil
    #expect(ReplacementConsent(target: .codex, row: row) == nil)
    #expect(consent.summary == summary)
    #expect(consent.fingerprint == "0123456789ab")
}

@Test func chamferAndAccessibilityTokensMatchTheSpecification() {
    let points = Chamfer.vertices(in: CGRect(x: 0, y: 0, width: 100, height: 50), cut: S.cardChamfer)
    #expect(points == [CGPoint(x: 0, y: 0), CGPoint(x: 88, y: 0), CGPoint(x: 100, y: 12),
                       CGPoint(x: 100, y: 50), CGPoint(x: 12, y: 50), CGPoint(x: 0, y: 38)])
    #expect(Theme(options: .init(increaseContrast: true)).boundary == 2)
    #expect(!DisplayOptions(reduceTransparency: true).gutterEffects)
    #expect(!DisplayOptions(increaseContrast: true).gutterEffects)
    #expect(DisplayOptions(reduceMotion: true).gutterEffects)
    #expect(S.gutter == 6 && S.gutterInset == 2)
    #expect(S.focusGap == 2 && S.focusStroke == 2)
}

@Test func textAndFocusColorsMeetTheSpecifiedSRGBContrast() {
    func luminance(_ ink: Ink) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let rgb = ink.rgb
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }
    func ratio(_ first: Ink, _ second: Ink) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    for ink in [Ink.text, .muted, .magenta, .cyan, .amber, .green] {
        #expect(ratio(ink, .ground) >= 4.5)
        #expect(ratio(ink, .surface) >= 4.5)
    }
    #expect(ratio(.focus, .ground) >= 3)
    #expect(ratio(.muted, .surface) >= 3)
}

@Test(arguments: [
    ("get_system_stats", nil, "현재 상태"),
    ("get_top_processes", "memory 5", "프로세스 5개 · 메모리순"),
    ("get_top_processes", "memory", "프로세스 개 · 메모리순"),
    ("get_top_processes", "cpu 3", "프로세스 3개 · CPU순"),
    ("get_top_processes", nil, "프로세스 개 · CPU순"),
    ("get_stats_history", "5m", "추이 5분"),
    ("get_stats_history", "1m 2m M", "추이 1분 2분 M"),
    ("get_stats_history", nil, "추이 "),
    ("diagnose_system", "heavy_work", "작업 전 점검"),
    ("diagnose_system", "slow", "느려짐 진단"),
    ("find_processes", nil, "프로세스 찾기"),
    ("track_processes", "start app", "프로세스 추적 시작"),
    ("track_processes", "status", "추적 결과 조회"),
    ("track_processes", "stop", "추적 중지"),
    ("track_processes", "list", "추적 목록"),
    ("track_processes", nil, "프로세스 추적"),
    ("wait_for", "cpu_idle", "조용해질 때까지 대기"),
    ("wait_for", "process_exit", "프로세스 종료 대기"),
    ("wait_for", "memory_pressure_normal", "메모리 압박 해소 대기"),
    ("wait_for", nil, "대기"),
    ("get_environment", nil, "환경 정보"),
    ("unknown", nil, "unknown"),
] as [(String, String?, String)])
func toolLabelsMatchBaseline(input: (tool: String, detail: String?, label: String)) {
    #expect(PanelView.toolLabel(.init(agent: "fixture", tool: input.tool, detail: input.detail)) == input.label)
}

@Test func absentFontResourcesFallBackPerRole() {
    let missing = PanelFonts(bundle: nil)
    #expect(missing.names.isEmpty)
    #expect(Theme.TypeRole.data.nsFont(using: missing).isFixedPitch)
    #expect(Theme.TypeRole.reading.nsFont(using: missing).isFixedPitch)
    #expect(Theme.TypeRole.wordmark.nsFont(using: missing).fontName != "Orbitron-Black")
}

@Test @MainActor func lateBootLabelsStayFinalAndExposureStopsAllDeliveries() throws {
    var time = 100.0
    let clock = AnimationClock(time: { time })
    let motion = HostMotion(host: "popover", clock: clock)
    let token = Exposure()
    motion.opened()
    motion.expose(token, data: PanelData(ScreenSnapshot()))
    motion.cells[.boot]?.recordDraw(motion.cells[.boot]?.frame)
    let session = try PanelFixtures.screen()
    motion.update(PanelData(session))
    time += 0.09
    motion.tick(time)
    if case .boot(_, let labels) = motion.cells[.boot]?.frame {
        #expect(labels.contains("// SYSTEM"))
        #expect(!labels.contains("CPU"))
    } else { Issue.record("Boot did not start") }

    let beforeClose = motion.cells[.grid]?.frame
    token.invalidate()
    time += 1
    motion.tick(time)
    #expect(motion.cells[.grid]?.frame == beforeClose)
    #expect(motion.nextDeadline(at: time) == nil)
    motion.pause(closing: true)
}

@Test @MainActor func warningAdditionKeepsItsEchoAndNewOnsetHonorsTheCooldown() throws {
    var time = 10.0
    let clock = AnimationClock(time: { time })
    let motion = HostMotion(host: "window", clock: clock)
    let token = Exposure()
    let normal = try PanelFixtures.screen()
    var warning = try PanelFixtures.screen(warning: true)
    warning.sample?.memory.pressure = "normal"
    motion.expose(token, data: PanelData(normal))
    motion.update(PanelData(warning))
    motion.tick(time)
    #expect(motion.cells[.warning]?.frame == .warning(1))
    warning.sample?.memory.pressure = "warning"
    time += 0.08
    motion.update(PanelData(warning))
    motion.tick(time)
    #expect(motion.cells[.warning]?.frame != .warning(1))
    time += 0.08
    motion.update(PanelData(normal))
    motion.update(PanelData(warning))
    motion.tick(time)
    #expect(motion.cells[.warning]?.frame == EffectFrame.none)
    token.invalidate()
    motion.pause(closing: true)
}

@Test func originAlertsRequireObservedCrossingsAndResetWhenExposureChanges() throws {
    let monitor = OriginCrossings()
    let rule = OriginAlertRule(metric: .memory, threshold: 100)
    func count(_ bytes: Int, generation: UInt64 = 1, enabled: Bool = true) throws -> Int {
        let data = Data("{\"pid\":7,\"startToken\":\"9\",\"name\":\"worker\",\"cpuPercent\":0,\"memoryBytes\":\(bytes)}".utf8)
        let row = try JSONDecoder().decode(ProcessUsage.self, from: data)
        return monitor.crossed(processes: [row], rule: enabled ? rule : nil, generation: generation).count
    }
    #expect(try [count(20),count(120),count(150),count(10),count(110)] == [0,1,0,0,1])
    #expect(try count(10) == 0)
    #expect(try count(130, generation: 2) == 0)
    #expect(try count(10, enabled: false) == 0)
    #expect(try count(150) == 0)
}
