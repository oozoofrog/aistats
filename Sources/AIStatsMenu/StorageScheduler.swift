import Foundation
import IOKit.ps
import StatsCore

/// Wall-clock time and delayed work on one serial queue.
protocol StorageTimeline: AnyObject {
    func now() -> Date
    /// Runs `block` on the timeline's queue after `delay` seconds; the returned closure cancels it.
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) -> () -> Void
}

final class DispatchTimeline: StorageTimeline, @unchecked Sendable {
    private let queue = DispatchQueue(label: "aistats.storage", qos: .utility)

    func now() -> Date { Date() }

    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(wallDeadline: .now() + max(0, delay), execute: item)
        return { item.cancel() }
    }
}

/// Starts at most one Storage Pass per six hours, spaces slices by at least 60 s and holds them while a
/// deferral condition holds (ADR 0010 Schedule and Deferral). All state lives on the timeline's queue.
final class StorageScheduler: @unchecked Sendable {
    static let interval: TimeInterval = 6 * 3600, launchDelay: TimeInterval = 120
    /// The deferral recheck also records an App CPU reading, so it runs once per admission window, well within the
    /// 15 min that ADR 0010 allows. The admission test after a deferral then reads the last 60 to 120 s.
    static let pause: TimeInterval = 60, recheck: TimeInterval = 60

    private let timeline: StorageTimeline
    private let home: URL
    private let makePass: () -> StoragePass
    private let deferred: () -> Bool
    private var pass: StoragePass?
    private var cancel: (() -> Void)?
    private var waiting = false
    private var observers: [NSObjectProtocol] = []
    private(set) var passesStarted = 0

    init(timeline: StorageTimeline, home: URL, deferred: @escaping () -> Bool, makePass: @escaping () -> StoragePass) {
        self.timeline = timeline
        self.home = home
        self.deferred = deferred
        self.makePass = makePass
    }

    static func live(home: URL = AIStatsPaths.home) -> StorageScheduler {
        StorageScheduler(timeline: DispatchTimeline(), home: home, deferred: liveDeferred) { StoragePass(.live(aistatsHome: home)) }
    }

    /// Battery power, Low Power Mode, or thermal state serious or critical.
    static func liveDeferred() -> Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical { return true }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    func start() {
        _ = timeline.after(0) { [self] in launch() }
    }

    /// Rechecks power, Low Power Mode and thermal state on their notifications.
    func observeConditions() {
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.conditionsChanged() })
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            context.map { Unmanaged<StorageScheduler>.fromOpaque($0).takeUnretainedValue().conditionsChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func conditionsChanged() {
        _ = timeline.after(0) { [self] in
            guard waiting, !deferred() else { return }
            cancel?()
            due()
        }
    }

    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        cancel?()
        cancel = timeline.after(delay, block)
    }

    /// The next pass starts 120 s after launch when none started in the last six hours, else six hours after the last
    /// start. An unreadable schedule counts as a pass started at launch; a future time counts as now.
    private func launch() {
        let now = timeline.now()
        let next: Date
        switch StorageFiles.readSchedule(home: home) {
        case nil: next = now.addingTimeInterval(Self.launchDelay)
        case .some(nil): next = now.addingTimeInterval(Self.interval)
        case .some(let last?):
            let started = min(last, now)
            next = now.timeIntervalSince(started) >= Self.interval ? now.addingTimeInterval(Self.launchDelay) : started.addingTimeInterval(Self.interval)
        }
        arm(next)
    }

    /// Creates the pass and records the App CPU baseline 60 s before the start, so the first admission test has a window.
    /// The first slice comes at least one pause after the baseline, also when the start is already past.
    private func arm(_ start: Date) {
        schedule(max(0, start.timeIntervalSince(timeline.now()) - Self.pause)) { [self] in
            let next = makePass()
            next.recordBaseline()
            pass = next
            schedule(max(Self.pause, start.timeIntervalSince(timeline.now()))) { [self] in due() }
        }
    }

    /// Waits `delay`, or less when the pass wall cap comes first.
    private func wait(_ delay: TimeInterval) {
        let cap = pass?.wallCapAt.map { max(0, $0.timeIntervalSince(timeline.now())) }
        schedule(min(delay, cap ?? delay)) { [self] in due() }
    }

    private func ended(_ pass: StoragePass) {
        self.pass = nil
        waiting = false
        arm((pass.startedAt ?? timeline.now()).addingTimeInterval(Self.interval))
    }

    private func due() {
        guard let pass else { return }
        if pass.endAtWallCap() { return ended(pass) }
        if deferred() {
            waiting = true
            pass.recordBaseline()
            wait(Self.recheck)
            return
        }
        waiting = false
        let starting = pass.startedAt == nil
        if pass.slice() {
            ended(pass)
        } else {
            wait(Self.pause)
        }
        if starting, pass.startedAt != nil { passesStarted += 1 }
    }
}
