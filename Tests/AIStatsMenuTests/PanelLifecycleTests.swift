import AppKit
import Combine
import os
import StatsCore
import Testing
@testable import AIStatsMenu

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
}

@Test @MainActor func firstExposureAppliesRegistrationResultsToHostRows() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = RegistrationEnvironment(home: directory, variables: [:], cliSearchPaths: [], appSearchPaths: [])
    let registrar = AgentRegistrar(binaryPath: "/fixtures/aistats", environment: environment)
    let complete = DispatchSemaphore(value: 0)
    let operations = AppModel.RegistrationOperations(status: {
        _ = complete.wait(timeout: .now() + 3)
        return registrar.status($0)
    }, perform: { _, target in registrar.uninstall(target) })
    let model = AppModel(directory: directory, registration: operations)
    let host = PanelHost(id: "window", model: model, clock: AnimationClock(time: { 0 }), theme: Theme()) { _, _ in }
    host.open(on: nil)
    host.attachExposedContent()
    defer { host.close() }
    let checking = try #require(host.appliedData)
    #expect(checking.agentRows.count == 5)
    #expect(checking.agentRows.values.allSatisfy { $0.registration.operation == "확인 중…" })

    for _ in AgentTarget.allCases { complete.signal() }
    try await waitUntil { host.appliedData?.agentRows.values.allSatisfy { $0.registration.state != nil } == true }
    let applied = try #require(host.appliedData)
    #expect(applied.screen.revision > checking.screen.revision)
    for target in AgentTarget.allCases {
        #expect(applied.agentRows[target] != checking.agentRows[target])
        #expect(applied.agentRows[target]?.registration.state == .agentNotFound)
        #expect(applied.agentRows[target]?.registration.busy == false)
    }

    host.close()
    var closedUpdates = 0
    let subscription = model.screenUpdates.sink { _ in closedUpdates += 1 }
    defer { subscription.cancel() }
    model.refreshRegistrations()
    for _ in AgentTarget.allCases { complete.signal() }
    try await waitUntil { model.screen.registrations.values.allSatisfy { !$0.busy } }
    #expect(closedUpdates == 0)
    #expect(host.appliedData == nil)
}

@Test func lastExposureRejectsScanPausedImmediatelyBeforeEnumeration() async {
    let gate = ProcessGeneration()
    let reachedEntry = DispatchSemaphore(value: 0)
    let resumeScan = DispatchSemaphore(value: 0)
    _ = gate.setExposed("window", true)
    let queued = gate.ticket()
    let result = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            var enumerations = 0
            let sample = SystemSampler().sample { _ in
                reachedEntry.signal()
                _ = resumeScan.wait(timeout: .now() + 3)
                return gate.enumerate(queued) {
                    enumerations += 1
                    return []
                }
            }
            continuation.resume(returning: (enumerations, sample.topProcesses))
        }
        #expect(reachedEntry.wait(timeout: .now() + 3) == .success)
        #expect(gate.setExposed("window", false) == .last)
        #expect(gate.setExposed("window", true) == .first)
        resumeScan.signal()
    }
    #expect(result.0 == 0)
    #expect(result.1 == nil)
    #expect(gate.enumerate(gate.ticket()) { [42] } == [42])
}

@Test @MainActor func lastHostCloseRevokesQueuedScanBeforeCloseTraceAndStateChange() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = RegistrationEnvironment(home: directory, variables: [:], cliSearchPaths: [], appSearchPaths: [])
    let registrar = AgentRegistrar(binaryPath: "/fixtures/aistats", environment: environment)
    let gate = ProcessGeneration()
    let model = AppModel(directory: directory, registration: .init(registrar), processGate: gate)
    let reachedEntry = DispatchSemaphore(value: 0)
    let resumeScan = DispatchSemaphore(value: 0)
    let scanFinished = DispatchSemaphore(value: 0)
    let enumerated = OSAllocatedUnfairLock(initialState: false)
    weak var closingHost: PanelHost?
    var closeTraces = 0
    let host = PanelHost(id: "window", model: model, clock: AnimationClock(time: { 0 }), theme: Theme(),
                         traceClose: { _ in
                             closeTraces += 1
                             #expect(closingHost?.shown == true)
                             resumeScan.signal()
                             #expect(scanFinished.wait(timeout: .now() + 3) == .success)
                             #expect(!enumerated.withLock { $0 })
                         }) { _, _ in }
    closingHost = host
    host.open(on: nil)
    host.attachExposedContent()
    let queued = try #require(gate.ticket())
    DispatchQueue.global().async {
        _ = SystemSampler().sample { _ in
            reachedEntry.signal()
            _ = resumeScan.wait(timeout: .now() + 3)
            return gate.enumerate(queued) {
                enumerated.withLock { $0 = true }
                return []
            }
        }
        scanFinished.signal()
    }
    #expect(reachedEntry.wait(timeout: .now() + 3) == .success)
    host.close()
    #expect(closeTraces == 1)
    #expect(!host.shown)
    #expect(!host.isExposed)
}

@Test @MainActor func confirmedReplacementWaitsForRecheckAndKeepsTheCapturedFingerprint() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let support = directory.appendingPathComponent("Library/Application Support/Claude")
    let apps = directory.appendingPathComponent("Applications")
    let config = support.appendingPathComponent("claude_desktop_config.json")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: apps.appendingPathComponent("Claude.app"), withIntermediateDirectories: true)
    try #"{"mcpServers":{"aistats":{"command":"/foreign","args":[]}}}"#
        .write(to: config, atomically: true, encoding: .utf8)
    let environment = RegistrationEnvironment(home: directory, variables: [:], cliSearchPaths: [], appSearchPaths: [apps.path])
    let registrar = AgentRegistrar(binaryPath: "/fixtures/aistats", environment: environment)
    let real = AppModel.RegistrationOperations(registrar)
    let canCheck = DispatchSemaphore(value: 0)
    let calls = OSAllocatedUnfairLock(initialState: [AppModel.Action]())
    let target = AgentTarget.claudeDesktop
    let operations = AppModel.RegistrationOperations(status: {
        if $0 == target { _ = canCheck.wait(timeout: .now() + 3) }
        return real.status($0)
    }, perform: { action, target in
        calls.withLock { $0.append(action) }
        return real.perform(action, target)
    })
    let model = AppModel(directory: directory, registration: operations)

    model.setExposed("window", exposed: true)
    canCheck.signal()
    try await waitUntil { model.screen.registrations[target]?.busy == false }
    let consent = try #require(ReplacementConsent(target: target, row: model.screen.registrations[target]))
    model.setExposed("window", exposed: false)
    model.setExposed("window", exposed: true)
    #expect(model.screen.registrations[target]?.busy == true)

    let otherEntry = #"{"mcpServers":{"aistats":{"command":"/different","args":[]}}}"#
    try otherEntry.write(to: config, atomically: true, encoding: .utf8)
    let replace = AppModel.Action.replace(fingerprint: consent.fingerprint)
    model.perform(replace, target)
    model.perform(replace, target)
    #expect(calls.withLock { $0.isEmpty })

    canCheck.signal()
    try await waitUntil { model.screen.registrations[target]?.resultID == 1 }
    #expect(calls.withLock { $0 } == [replace])
    #expect(model.screen.registrations[target]?.messageIsError == true)
    #expect(try String(contentsOf: config, encoding: .utf8) == otherEntry)
}

@Test @MainActor func displayOptionsNotificationRunsInModalPanelMode() {
    let center = NotificationCenter()
    var deliveredIn: RunLoop.Mode?
    let observer = DisplayOptions.observeChanges(in: center) {
        deliveredIn = RunLoop.current.currentMode
        CFRunLoopStop(CFRunLoopGetMain())
    }
    defer { observer.cancel() }
    let timer = Timer(timeInterval: 1, repeats: false) { _ in }
    RunLoop.main.add(timer, forMode: .modalPanel)
    defer { timer.invalidate() }
    center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(1))
    #expect(deliveredIn == .modalPanel)
}

@Test @MainActor func closeDoesNotPublishToOldFrameCells() throws {
    let motion = HostMotion(host: "window", clock: AnimationClock(time: { 10 }))
    let first = Exposure()
    motion.opened()
    motion.expose(first, data: PanelData(try PanelFixtures.screen(warning: true)))
    let oldGrid = try #require(motion.cells[.grid])
    let oldBoot = try #require(motion.cells[.boot])
    var deliveries = 0
    let subscriptions = [oldGrid, oldBoot].map { cell in
        cell.$frame.dropFirst().sink { _ in deliveries += 1 }
    }
    defer { subscriptions.forEach { $0.cancel() } }

    first.invalidate()
    motion.pause(closing: true)
    motion.expose(Exposure(), data: PanelData(ScreenSnapshot()))
    #expect(motion.cells[.grid] !== oldGrid)
    #expect(motion.cells[.boot] !== oldBoot)
    #expect(deliveries == 0)
    motion.pause(closing: true)
}

@Test @MainActor func chartUsesNewExposureSeedUntilItsFirstDraw() throws {
    let motion = HostMotion(host: "window", clock: AnimationClock(time: { 10 }))
    var screen = ScreenSnapshot(cpuHistory: [.init(id: 1, value: 10)])
    let first = Exposure()
    motion.expose(first, data: PanelData(screen))
    let old = try #require(motion.cells[.chartChange])
    old.recordDraw(old.frame)
    first.invalidate()
    motion.pause(closing: true)

    screen.cpuHistory.append(.init(id: 2, value: 30))
    motion.expose(Exposure(), data: PanelData(screen))
    screen.cpuHistory.append(.init(id: 3, value: 60))
    motion.update(PanelData(screen))
    motion.tick(10)
    let current = try #require(motion.cells[.chartChange])
    guard case .plot(let points) = current.frame else { Issue.record("Missing chart frame"); return }
    #expect(points.map(\.alpha) == [1, 1, 0])
    #expect(points.map(\.slot) == [58, 59, 59])
    motion.pause(closing: true)
}

private func bitmap(width: Int = 64, height: Int = 16) throws -> CGContext {
    try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
}

@Test func chartDrawsTheSurvivingDotBeforeTheFirstEdgeAppears() throws {
    let first = PlotPoint.settled([.init(id: 1, value: 50)])
    let second = PlotPoint.settled([.init(id: 1, value: 50), .init(id: 2, value: 90)])
    let context = try bitmap()
    let frame = PlotFrame.transition(PlotTransition(from: first, to: second), 0)
    Artwork.chart.draw(context, CGSize(width: 64, height: 16), frame: .plot(frame), options: DisplayOptions())
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let offset = 7 * context.bytesPerRow + 63 * 4
    #expect(pixels[offset + 3] > 0)
}

@Test @MainActor func bootStartsAtFirstExposedDrawAfterDeferredMount() throws {
    var time = 10.0
    let motion = HostMotion(host: "window", clock: AnimationClock(time: { time }))
    let data = PanelData(ScreenSnapshot())
    let undrawn = Exposure()
    motion.opened()
    motion.expose(undrawn, data: data)
    undrawn.invalidate()
    motion.pause(closing: false)

    let token = Exposure()
    motion.expose(token, data: data)
    defer {
        token.invalidate()
        motion.pause(closing: true)
    }
    let cell = try #require(motion.cells[.boot])
    time += 1
    motion.tick(time)
    #expect(cell.frame.elapsed == 0)
    #expect(motion.nextDeadline(at: time) == nil)

    let surface = FrameSurface.Surface(frame: CGRect(x: 0, y: 0, width: 64, height: 16))
    surface.configure(FrameSurface(cell: cell, artwork: .bootScan(.left),
                                   decoration: DecorationContext(host: "window", exposure: token), options: .init()))
    time += 1
    motion.tick(time)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: try bitmap(), flipped: true)
    defer { NSGraphicsContext.current = previous }
    surface.draw(surface.bounds)
    #expect(cell.lastDrawn?.elapsed == 0)
    #expect(motion.nextDeadline(at: time) == time + 1 / Motion.oneShotFPS)
    motion.tick(time + 0.1)
    #expect(abs((cell.frame.elapsed ?? -1) - 0.1) < 0.000_001)
    motion.tick(time + Motion.boot + 0.001)
    #expect(cell.frame == .none)
}

@Test @MainActor func hazardHoldsInitialAndResumedPhasesUntilDraw() throws {
    var time = 10.0
    let motion = HostMotion(host: "window", clock: AnimationClock(time: { time }))
    let token = Exposure()
    motion.expose(token, data: PanelData(try PanelFixtures.screen()))
    motion.tick(time)
    time += 0.02
    var warning = try PanelFixtures.screen(warning: true)
    warning.warningGeneration = 1
    motion.update(PanelData(warning))
    let cell = try #require(motion.cells[.hazard])
    time += 0.2
    motion.tick(time)
    #expect(cell.frame == .phase(0))

    let surface = FrameSurface.Surface(frame: CGRect(x: 0, y: 0, width: 64, height: 4))
    surface.configure(FrameSurface(cell: cell, artwork: .hazard,
                                   decoration: DecorationContext(host: "window", exposure: token), options: .init()))
    time += 0.2
    motion.tick(time)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: try bitmap(), flipped: true)
    defer { NSGraphicsContext.current = previous }
    var draws = 0
    var pendingPaint = false
    let frames = cell.$frame.sink { _ in pendingPaint = true }
    defer { frames.cancel() }
    func drawIfNeeded() {
        guard pendingPaint else { return }
        surface.draw(surface.bounds)
        pendingPaint = false
        draws += 1
    }
    drawIfNeeded()
    #expect(draws == 1)
    #expect(cell.lastDrawn == .phase(0))
    motion.tick(time + 0.04)
    drawIfNeeded()
    #expect(draws == 1)
    time += 1 / Motion.loopFPS
    motion.tick(time)
    drawIfNeeded()
    #expect(draws == 2)
    let phase = try #require(cell.lastDrawn?.phase)
    #expect(phase > 0)
    time += 0.2
    motion.tick(time)
    #expect(cell.frame.phase != phase)
    token.invalidate()
    motion.pause(closing: false)

    let restored = Exposure()
    motion.expose(restored, data: PanelData(warning))
    let resumed = try #require(motion.cells[.hazard])
    time += 0.2
    motion.tick(time)
    surface.configure(FrameSurface(cell: resumed, artwork: .hazard,
                                   decoration: DecorationContext(host: "window", exposure: restored), options: .init()))
    surface.draw(surface.bounds)
    #expect(resumed.lastDrawn == .phase(phase))
    motion.tick(time + 1 / Motion.loopFPS)
    #expect((resumed.frame.phase ?? 0) > phase)
    restored.invalidate()
    motion.pause(closing: true)
}

@Test @MainActor func sharedGridDrawsItsSeedOnALateSecondLayer() throws {
    var time = 10.0
    let motion = HostMotion(host: "window", clock: AnimationClock(time: { time }))
    let token = Exposure()
    motion.expose(token, data: PanelData(ScreenSnapshot()))
    defer {
        token.invalidate()
        motion.pause(closing: true)
    }
    let cell = try #require(motion.cells[.grid])
    let rect = CGRect(x: 0, y: 0, width: 64, height: 16)
    let decoration = DecorationContext(host: "window", exposure: token)
    let previous = NSGraphicsContext.current
    defer { NSGraphicsContext.current = previous }

    func draw(_ side: GutterSide) throws -> Data {
        let surface = FrameSurface.Surface(frame: rect)
        surface.configure(FrameSurface(cell: cell, artwork: .grid(side), decoration: decoration, options: .init()))
        let context = try bitmap()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        surface.draw(rect)
        let pixels = try #require(context.data)
        return Data(bytes: pixels, count: context.bytesPerRow * context.height)
    }

    let initial = try draw(.left)
    time += Motion.grid / 2
    motion.tick(time)
    #expect(cell.frame == .phase(0.5))
    #expect(try draw(.right) == initial)
}

@Test @MainActor func ambientTickOnlyChangesTheEligibleFrameCells() throws {
    let motion = HostMotion(host: "window", clock: AnimationClock(time: { 10 }))
    let token = Exposure()
    let data = PanelData(try PanelFixtures.screen())
    motion.expose(token, data: data)
    let decoration = DecorationContext(host: "window", exposure: token)
    let content = PanelContent(data: data, theme: Theme(), size: CGSize(width: S.panelWidth, height: S.panelHeight),
                               decoration: decoration, cells: motion.cells, perform: { _, _ in },
                               refreshRegistrations: {}, confirm: { _ in })
    var panelChanges = 0
    let panel = content.objectWillChange.sink { _ in panelChanges += 1 }
    let chart = try #require(content.cells[.chartChange])
    let originalChart = chart.frame
    let scan = try #require(content.cells[.chartScan])
    scan.recordDraw(scan.frame)

    motion.tick(10.11)
    #expect(scan.frame.phase ?? 0 > 0)
    #expect(chart.frame == originalChart)
    #expect(panelChanges == 0)
    panel.cancel()
    token.invalidate()
    motion.pause(closing: true)
}
