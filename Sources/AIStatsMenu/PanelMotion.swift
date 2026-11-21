import Combine
import Foundation
import StatsCore

typealias Motion = Theme.Motion

enum MotionMath {
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    static func mix(_ from: Double, _ to: Double, _ progress: Double) -> Double {
        from + (to - from) * progress
    }

    static func ease(_ progress: Double) -> Double {
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }
        let (x1, y1, x2, y2) = Motion.easeOut
        func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let rest = 1 - t
            return 3 * rest * rest * t * a + 3 * rest * t * t * b + t * t * t
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if curve(middle, x1, x2) < progress { lower = middle } else { upper = middle }
        }
        return curve((lower + upper) / 2, y1, y2)
    }

    static func segment(_ fraction: Double, slot: Int) -> Double {
        clamp(clamp(fraction) * Double(Theme.Size.slotCount) - Double(slot))
    }

    static let glyphPool = Array("0123456789#%+*=:<>[]─│┌┐└┘╱╲")

    static func decode(_ final: Character, letter: Int, elapsed: Double) -> Character {
        guard letter > 0, elapsed < Motion.decode, elapsed < Double(letter) * Motion.letterDeadline else { return final }
        return glyphPool[(letter - 1 + Int(max(0, elapsed) / Motion.glyphInterval)) % glyphPool.count]
    }
}

struct PlotPoint: Equatable {
    var id: UInt64
    var slot: Double
    var value: Double
    var alpha = 1.0

    static func settled(_ history: [CPUPoint]) -> [Self] {
        let points = history.suffix(AppModel.sparklineLength)
        return points.enumerated().map {
            Self(id: $0.element.id, slot: Double(AppModel.sparklineLength - points.count + $0.offset),
                 value: MotionMath.clamp($0.element.value / 100))
        }
    }

}

/// Match identities once on retarget. Render each interpolated point on demand.
final class PlotTransition: Equatable {
    private struct Movement {
        let from: PlotPoint
        let to: PlotPoint
    }

    private let movements: [Movement]
    var count: Int { movements.count }

    init(from visible: [PlotPoint], to target: [PlotPoint]) {
        let previous = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        let current = Set(target.map(\.id))
        let shift = target.compactMap { point in previous[point.id].map { $0.slot - point.slot } }.max() ?? 1
        let retiring = visible.compactMap { point -> Movement? in
            guard !current.contains(point.id) else { return nil }
            var end = point
            end.slot -= max(1, shift)
            return Movement(from: point, to: end)
        }
        movements = retiring + target.map { point in
            let start = previous[point.id] ?? PlotPoint(id: point.id, slot: point.slot, value: point.value, alpha: 0)
            return Movement(from: start, to: point)
        }
    }

    static func == (lhs: PlotTransition, rhs: PlotTransition) -> Bool { lhs === rhs }

    func point(at index: Int, progress: Double) -> PlotPoint {
        let item = movements[index]
        return PlotPoint(id: item.to.id, slot: MotionMath.mix(item.from.slot, item.to.slot, progress),
                         value: item.to.value, alpha: MotionMath.mix(item.from.alpha, item.to.alpha, progress))
    }
}

enum PlotFrame: Equatable, RandomAccessCollection {
    case settled([PlotPoint])
    case transition(PlotTransition, Double)

    var startIndex: Int { 0 }
    var endIndex: Int {
        switch self {
        case .settled(let points): return points.count
        case .transition(let transition, _): return transition.count
        }
    }

    subscript(index: Int) -> PlotPoint {
        switch self {
        case .settled(let points): return points[index]
        case .transition(let transition, let progress): return transition.point(at: index, progress: progress)
        }
    }

    var leadingDot: PlotPoint? {
        first { $0.slot >= 0 && $0.alpha > 0 }
    }
}

struct EdgeSample: Equatable {
    var rgb: RGB
    var alpha: Double

    static func reading(from alpha: Double, elapsed: Double) -> Self {
        let peak = Theme.Effect.readingAlpha
        let value = elapsed < Motion.readingRise
            ? MotionMath.mix(alpha, peak, MotionMath.clamp(elapsed / Motion.readingRise))
            : peak * (1 - MotionMath.ease((elapsed - Motion.readingRise) / Motion.readingDecay))
        return Self(rgb: Theme.Ink.cyan.rgb, alpha: value)
    }

    static func result(from: Self, to target: RGB, elapsed: Double) -> Self {
        let peak = Theme.Effect.resultAlpha
        if elapsed < Motion.resultRise {
            let p = MotionMath.ease(elapsed / Motion.resultRise)
            return Self(rgb: from.rgb.toward(target, by: p), alpha: MotionMath.mix(from.alpha, peak, p))
        }
        return Self(rgb: target, alpha: peak * (1 - MotionMath.ease((elapsed - Motion.resultRise) / Motion.resultDecay)))
    }
}

struct LoopPhase {
    private(set) var phase = 0.0
    private var origin: (time: Double, phase: Double)?

    mutating func draw(at time: Double, period: Double) -> Double {
        if let origin {
            phase = (origin.phase + max(0, time - origin.time) / period).truncatingRemainder(dividingBy: 1)
        } else {
            origin = (time, phase)
        }
        return phase
    }

    mutating func pause(at lastDrawn: Double? = nil) {
        phase = lastDrawn ?? phase
        origin = nil
    }
}

struct QuietPeriod {
    private(set) var lastInput: Double?

    mutating func input(at time: Double) { lastInput = max(lastInput ?? -.infinity, time) }
    func contains(_ time: Double) -> Bool {
        lastInput.map { time - $0 >= Motion.quietPeriod } ?? true
    }
}

enum EffectID: Hashable {
    case boot, grid, shimmer, hazard, warning, chartScan, chartChange
    case segment(MetricID), reading(MetricID), busy(AgentTarget), result(AgentTarget)

    var traceName: String {
        switch self {
        case .boot: return "boot"
        case .grid: return "grid"
        case .shimmer: return "shimmer"
        case .hazard: return "hazard"
        case .warning: return "warning"
        case .chartScan: return "chartScan"
        case .chartChange: return "chartChange"
        case .segment(let metric): return "segment." + metric.rawValue
        case .reading(let metric): return "reading." + metric.rawValue
        case .busy(let target): return "busy." + target.rawValue
        case .result(let target): return "result." + target.rawValue
        }
    }

    var period: Double? {
        switch self {
        case .grid: return Motion.grid
        case .shimmer: return Motion.shimmer
        case .hazard: return Motion.hazard
        case .chartScan: return Motion.chart
        case .busy: return Motion.busy
        default: return nil
        }
    }

    func fps(quiet: Bool) -> Double {
        guard period != nil else { return Motion.oneShotFPS }
        switch self {
        case .grid, .shimmer: return quiet ? Motion.quietGutterFPS : Motion.loopFPS
        case .chartScan: return quiet ? Motion.quietChartFPS : Motion.loopFPS
        default: return Motion.loopFPS
        }
    }
}

enum EffectFrame: Equatable {
    case none
    case phase(Double)
    case boot(Double, Set<String>)
    case segment(Double?)
    case plot(PlotFrame)
    case edge(EdgeSample)
    case warning(Double)

    var phase: Double? {
        if case .phase(let value) = self { return value }
        return nil
    }

    var elapsed: Double? {
        if case .boot(let elapsed, _) = self { return elapsed }
        return nil
    }

    var edge: EdgeSample? {
        if case .edge(let sample) = self { return sample }
        return nil
    }
}

@MainActor
final class FrameCell: ObservableObject {
    final class LoopSeed {
        let frame: EffectFrame
        init(phase: Double) { frame = .phase(phase) }
    }

    let id: EffectID
    @Published private(set) var frame: EffectFrame = .none
    private(set) var lastDrawn: EffectFrame?
    private(set) var loopSeed: LoopSeed?
    var onFirstDraw: (() -> Void)?

    init(id: EffectID) { self.id = id }

    func recordDraw(_ frame: EffectFrame?) {
        lastDrawn = frame
        guard frame?.phase != nil || frame?.elapsed != nil else { return }
        let firstDraw = onFirstDraw
        onFirstDraw = nil
        firstDraw?()
    }

    func seedLoop(phase: Double, onDraw: @escaping () -> Void) {
        let seed = LoopSeed(phase: phase)
        loopSeed = seed
        onFirstDraw = onDraw
        set(seed.frame)
    }

    func clearLoop() {
        loopSeed = nil
        onFirstDraw = nil
        lastDrawn = nil
        set(.none)
    }

    func set(_ frame: EffectFrame) {
        if self.frame != frame { self.frame = frame }
    }
}

final class Exposure: @unchecked Sendable {
    private let lock = NSLock()
    private var exposed = true
    var isCurrent: Bool { lock.withLock { exposed } }

    func invalidate() { lock.withLock { exposed = false } }

    @discardableResult
    func drawIfCurrent(_ draw: () -> Void) -> Bool {
        lock.withLock {
            guard exposed else { return false }
            draw()
            return true
        }
    }
}

@MainActor
final class HostMotion {
    private struct Loop {
        var phase = LoopPhase()
        var lastFrame: Double?
    }

    private struct Shot {
        var start: Double?
        var lastFrame: Double?
        let duration: Double
        let final: EffectFrame
        let frame: (Double) -> EffectFrame
    }

    let host: String
    private(set) var cells: [EffectID: FrameCell] = [:]
    private let clock: AnimationClock
    private var loops: [EffectID: Loop] = [:]
    private var eligible: Set<EffectID> = []
    private var shots: [EffectID: Shot] = [:]
    private var exposure: Exposure?
    private var options = DisplayOptions()
    private var quiet = QuietPeriod()
    private var data: PanelData?
    private var pendingBoot = false
    private var lastWarningEcho = -Double.infinity

    init(host: String, clock: AnimationClock) {
        self.host = host
        self.clock = clock
    }

    private static let effectIDs: [EffectID] = {
        let global: [EffectID] = [.boot, .grid, .shimmer, .hazard, .warning, .chartScan, .chartChange]
        let readings: [EffectID] = MetricID.allCases.flatMap { [.segment($0), .reading($0)] }
        let rows: [EffectID] = AgentTarget.allCases.flatMap { [.busy($0), .result($0)] }
        return global + readings + rows
    }()

    func opened() {
        let now = clock.now
        pendingBoot = !options.reduceMotion
        quiet.input(at: now)
        PanelTrace.event("Open", host)
        PanelTrace.marker("open", host: host)
    }

    func interact() {
        quiet.input(at: clock.now)
        clock.schedule()
    }

    func expose(_ token: Exposure, data: PanelData) {
        cells = Dictionary(uniqueKeysWithValues: Self.effectIDs.map { ($0, FrameCell(id: $0)) })
        exposure = token
        update(data, animate: false)
        if pendingBoot {
            let labels = data.bootLabels
            start(.boot, duration: Motion.boot) { .boot($0, labels) }
            cells[.boot]?.onFirstDraw = { [weak self] in self?.startBoot() }
            deliver(.boot, .boot(0, labels))
        }
        clock.activate(self)
    }

    private func startBoot() {
        guard var boot = shots[.boot] else { return }
        let time = clock.now
        boot.start = time
        boot.lastFrame = time
        shots[.boot] = boot
        pendingBoot = false
        PanelTrace.event("Boot", host)
        PanelTrace.marker("boot", host: host)
        clock.schedule()
    }

    func pause(closing: Bool) {
        exposure = nil
        if closing { pendingBoot = false }
        clock.deactivate(self)
        pauseLoops()
        settle()
        cells.removeAll()
    }

    func settings(_ new: DisplayOptions) {
        let previous = options
        options = new
        if new.reduceMotion {
            pendingBoot = false
            pauseLoops()
            settle()
        }
        if !new.gutterEffects {
            for id in [EffectID.grid, .shimmer] { pauseLoop(id) }
        }
        if new.increaseContrast, shots.removeValue(forKey: .warning) != nil { cells[.warning]?.set(.none) }
        if previous != new {
            if exposure?.isCurrent == true, !new.reduceMotion { seedLoops() }
            clock.schedule()
        }
    }

    func update(_ next: PanelData, animate: Bool = true) {
        let previous = data
        data = next
        let now = clock.now
        let onset = previous?.warnings.isEmpty != false && !next.warnings.isEmpty
        if let event = next.screen.quietEvent { quiet.input(at: event) }
        if previous?.screen.warningGeneration != next.screen.warningGeneration { resetLoop(.hazard) }

        let shouldAnimate = animate && !options.reduceMotion
        if onset, shouldAnimate, !options.increaseContrast, now - lastWarningEcho >= Motion.warningCooldown {
            start(.warning, duration: Motion.warning) { .warning(1 - MotionMath.ease($0 / Motion.warning)) }
        } else if next.warnings.isEmpty {
            shots[.warning] = nil
            cells[.warning]?.set(.none)
        }

        var nextLoops: Set<EffectID> = [.grid, .shimmer]
        if next.screen.cpuHistory.count >= 2 { nextLoops.insert(.chartScan) }
        if !next.warnings.isEmpty { nextLoops.insert(.hazard) }

        for target in AgentTarget.allCases {
            let row = next.screen.registrations[target] ?? .init()
            if row.busyGeneration != (previous?.screen.registrations[target]?.busyGeneration ?? 0) {
                resetLoop(.busy(target))
            }
            if row.state == nil || row.busy { nextLoops.insert(.busy(target)) }
            if shouldAnimate, row.resultID != 0, row.resultID != previous?.screen.registrations[target]?.resultID {
                let id = EffectID.result(target)
                let targetColor = (row.messageIsError ? Theme.Ink.magenta : .green).rgb
                let from = displayed(id)?.edge ?? EdgeSample(rgb: targetColor, alpha: 0)
                start(id, duration: Motion.resultRise + Motion.resultDecay) { .edge(.result(from: from, to: targetColor, elapsed: $0)) }
            }
        }

        for id in eligible.subtracting(nextLoops) { resetLoop(id) }
        eligible = nextLoops
        if exposure?.isCurrent == true { seedLoops() }

        for id in MetricID.allCases {
            let metric = next.metrics[id]
            let prior = previous?.metrics[id]
            if !shouldAnimate || metric?.fraction != prior?.fraction {
                let key = EffectID.segment(id)
                let final = EffectFrame.segment(metric?.fraction)
                if shouldAnimate, let to = metric?.fraction, case .segment(let shown) = displayed(key) {
                    let from = prior?.available == true ? shown ?? 0 : 0
                    start(key, duration: Motion.transition, final: final) {
                        .segment(MotionMath.mix(from, to, MotionMath.ease($0 / Motion.transition)))
                    }
                } else {
                    shots[key] = nil
                    cells[key]?.set(final)
                }
            }

            if let metric, metric.available, let prior, prior.reading != metric.reading, shouldAnimate {
                let key = EffectID.reading(id)
                let alpha = displayed(key)?.edge?.alpha ?? 0
                start(key, duration: Motion.readingRise + Motion.readingDecay) { .edge(.reading(from: alpha, elapsed: $0)) }
            } else if metric?.available != true {
                shots[.reading(id)] = nil
                cells[.reading(id)]?.set(.none)
            }
        }

        if !shouldAnimate || next.screen.cpuHistory != previous?.screen.cpuHistory {
            let points = PlotPoint.settled(next.screen.cpuHistory)
            let final = EffectFrame.plot(.settled(points))
            if shouldAnimate, case .plot(let visible) = displayed(.chartChange), !points.isEmpty {
                let transition = PlotTransition(from: Array(visible), to: points)
                start(.chartChange, duration: Motion.transition, final: final) {
                    .plot(.transition(transition, MotionMath.ease($0 / Motion.transition)))
                }
            } else {
                shots[.chartChange] = nil
                cells[.chartChange]?.set(final)
            }
        }
        clock.schedule()
    }

    private func start(_ id: EffectID, duration: Double, final: EffectFrame = .none,
                       frame: @escaping (Double) -> EffectFrame) {
        shots[id] = Shot(start: nil, lastFrame: shots[id]?.lastFrame,
                         duration: duration, final: final, frame: frame)
    }

    private func displayed(_ id: EffectID) -> EffectFrame? {
        guard let cell = cells[id] else { return nil }
        return cell.lastDrawn ?? cell.frame
    }

    private func resetLoop(_ id: EffectID) {
        loops[id] = nil
        cells[id]?.clearLoop()
    }

    private func pauseLoop(_ id: EffectID) {
        guard var loop = loops[id] else { return }
        loop.phase.pause(at: cells[id]?.lastDrawn?.phase)
        loop.lastFrame = nil
        loops[id] = loop
        guard exposure?.isCurrent == true else { return }
        cells[id]?.clearLoop()
    }

    private func seedLoops() {
        guard !options.reduceMotion else { return }
        for id in movingLoops {
            guard let cell = cells[id], cell.loopSeed == nil, let period = id.period else { continue }
            let loop = loops[id] ?? Loop()
            loops[id] = loop
            cell.seedLoop(phase: loop.phase.phase) { [weak self] in self?.startLoop(id, period: period) }
        }
    }

    private func startLoop(_ id: EffectID, period: Double) {
        guard var loop = loops[id] else { return }
        let time = clock.now
        _ = loop.phase.draw(at: time, period: period)
        loop.lastFrame = time
        loops[id] = loop
        clock.schedule()
    }

    private func pauseLoops() {
        for id in Array(loops.keys) { pauseLoop(id) }
    }

    private func settle() {
        if exposure?.isCurrent == true {
            for (id, shot) in shots {
                cells[id]?.onFirstDraw = nil
                cells[id]?.recordDraw(nil)
                cells[id]?.set(shot.final)
            }
        }
        shots.removeAll()
    }

    private var movingLoops: Set<EffectID> {
        options.gutterEffects ? eligible : eligible.subtracting([.grid, .shimmer])
    }

    func nextDeadline(at time: Double) -> Double? {
        guard exposure?.isCurrent == true, !options.reduceMotion else { return nil }
        var due = Double.infinity
        let isQuiet = quiet.contains(time)
        for id in movingLoops {
            guard let lastFrame = loops[id]?.lastFrame else { continue }
            due = min(due, lastFrame + 1 / id.fps(quiet: isQuiet))
        }
        for (id, shot) in shots where id != .boot || shot.start != nil {
            due = min(due, (shot.lastFrame ?? -.infinity) + 1 / Motion.oneShotFPS)
        }
        return due == .infinity ? nil : due
    }

    func tick(_ time: Double) {
        guard exposure?.isCurrent == true, !options.reduceMotion else { return }
        var delivered = false
        let isQuiet = quiet.contains(time)
        for id in movingLoops {
            guard let period = id.period, var loop = loops[id], let lastFrame = loop.lastFrame,
                  time >= lastFrame + 1 / id.fps(quiet: isQuiet) else { continue }
            loop.lastFrame = time
            let phase = loop.phase.draw(at: time, period: period)
            loops[id] = loop
            deliver(id, .phase(phase))
            delivered = true
        }
        for id in Array(shots.keys) {
            guard var shot = shots[id], id != .boot || shot.start != nil,
                  time >= (shot.lastFrame ?? -.infinity) + 1 / Motion.oneShotFPS else { continue }
            if shot.start == nil {
                shot.start = time
                if id == .warning { lastWarningEcho = time }
            }
            let elapsed = time - (shot.start ?? time)
            if elapsed >= shot.duration {
                shots[id] = nil
                deliver(id, shot.final)
            } else {
                shot.lastFrame = time
                shots[id] = shot
                deliver(id, shot.frame(elapsed))
            }
            delivered = true
        }
        if delivered { PanelTrace.event("Host frame", host) }
    }

    private func deliver(_ id: EffectID, _ frame: EffectFrame) {
        guard exposure?.isCurrent == true else { return }
        if PanelTrace.isEnabled { PanelTrace.event("Effect frame", host, id.traceName) }
        cells[id]?.set(frame)
    }
}

@MainActor
final class AnimationClock {
    private let time: () -> Double
    private let automaticallySchedules: Bool
    private var hosts: [String: HostMotion] = [:]
    private var timer: Timer?
    private var deadline: Double?
    private var lastTick = -Double.infinity
    var now: Double { time() }

    init(time: (() -> Double)? = nil) {
        automaticallySchedules = time == nil
        self.time = time ?? { PanelTrace.now }
    }

    func activate(_ host: HostMotion) {
        hosts[host.host] = host
        schedule()
    }

    func deactivate(_ host: HostMotion) {
        hosts[host.host] = nil
        schedule()
    }

    func schedule() {
        guard automaticallySchedules else { return }
        let now = now
        guard let earliest = hosts.values.compactMap({ $0.nextDeadline(at: now) }).min() else {
            timer?.invalidate()
            timer = nil
            deadline = nil
            return
        }
        let due = max(earliest, lastTick + 1 / Motion.oneShotFPS, now)
        if let deadline, deadline <= due { return }
        timer?.invalidate()
        let next = Timer(timeInterval: max(0.0001, due - now), repeats: false) { [weak self] fired in
            MainActor.assumeIsolated {
                guard let self, self.timer === fired else { return }
                self.timer = nil
                self.deadline = nil
                let timestamp = self.now
                if timestamp >= self.lastTick + 1 / Motion.oneShotFPS,
                   self.hosts.values.contains(where: { ($0.nextDeadline(at: timestamp) ?? .infinity) <= timestamp }) {
                    self.lastTick = timestamp
                    PanelTrace.event("Clock tick")
                    for host in self.hosts.values { host.tick(timestamp) }
                }
                self.schedule()
            }
        }
        deadline = due
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}
