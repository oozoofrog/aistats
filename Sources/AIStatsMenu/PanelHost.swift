import AppKit
import Combine
import StatsCore
import SwiftUI

@MainActor
final class PanelHost {
    let controller: NSHostingController<HostShell>
    private let model: AppModel
    private let motion: HostMotion
    private var theme: Theme
    private var dimensions: CGSize
    private let confirm: (PanelHost, AgentTarget) -> Void
    private let terminate: (PanelHost, OrphanReport.Row) -> Void
    private let traceClose: (String) -> Void
    private var updates: AnyCancellable?
    private var content: PanelContent?
    private var exposure: Exposure?
    private var focusRequest: FocusRequest?
    private var applicationHidden = false
    private var minimizing = false
    private var wantsImmediateSample = false

    weak var window: NSWindow?
    private(set) var shown = false
    private(set) var presentation: UInt64 = 0
    var isExposed: Bool { exposure?.isCurrent == true }
    var size: CGSize { dimensions }
    var appliedData: PanelData? { content?.data }
    var appliedFocusRequest: FocusRequest? { content?.focusRequest }

    init(id: String, model: AppModel, clock: AnimationClock, theme: Theme,
         traceClose: @escaping (String) -> Void = { PanelTrace.event("Close start", $0) },
         confirm: @escaping (PanelHost, AgentTarget) -> Void,
         terminate: @escaping (PanelHost, OrphanReport.Row) -> Void = { _, _ in }) {
        self.model = model
        self.theme = theme
        self.confirm = confirm
        self.terminate = terminate
        self.traceClose = traceClose
        motion = HostMotion(host: id, clock: clock)
        motion.settings(theme.options)
        dimensions = S.fit(CGSize(width: S.panelWidth, height: S.panelHeight), on: NSScreen.main)
        controller = NSHostingController(rootView: HostShell(size: dimensions))
        // The Host owns its explicit content size.
        controller.sizingOptions = []
    }

    func open(on screen: NSScreen?) {
        resize(on: screen)
        wantsImmediateSample = true
        guard !shown else { return }
        shown = true
        minimizing = false
        presentation += 1
        motion.opened()
    }

    func close() {
        guard shown else { return }
        detach(closing: true)
    }

    func setApplicationHidden(_ hidden: Bool) {
        if hidden {
            detach { applicationHidden = true }
            return
        }
        applicationHidden = hidden
        reconcile()
    }

    func setMinimizing(_ minimizing: Bool) {
        if minimizing {
            detach { self.minimizing = true }
            return
        }
        self.minimizing = false
        wantsImmediateSample = true
        reconcile()
    }

    func resize(on screen: NSScreen?) {
        let new = S.fit(CGSize(width: S.panelWidth, height: S.panelHeight), on: screen)
        guard dimensions != new else { return }
        dimensions = new
        if let content {
            content.size = new
        } else {
            controller.rootView = HostShell(size: new)
        }
        window?.setContentSize(new)
    }

    func settings(_ theme: Theme) {
        self.theme = theme
        motion.settings(theme.options)
        content?.theme = theme
        PanelTrace.event("Display options applied", motion.host)
    }

    func reconcile() {
        guard shown, !applicationHidden, !minimizing, let window, window.isVisible, !window.isMiniaturized, !NSApp.isHidden,
              window.occlusionState.contains(.visible) else {
            detach()
            return
        }
        guard exposure == nil else {
            requestSampleIfNeeded()
            return
        }
        attachExposedContent()
    }

    func attachExposedContent() {
        guard shown, exposure == nil else { return }
        let token = Exposure()
        exposure = token
        let decoration = DecorationContext(host: motion.host, exposure: token)
        let data = PanelData(model.screen)
        motion.expose(token, data: data)
        let content = PanelContent(data: data, theme: theme, size: dimensions, decoration: decoration, cells: motion.cells,
                                   perform: { [weak self] action, target in
                                       guard token.isCurrent else { return }
                                       self?.model.perform(action, target)
                                   },
                                   refreshRegistrations: { [weak self] in
                                       guard token.isCurrent else { return }
                                       self?.model.refreshRegistrations()
                                   },
                                   confirm: { [weak self] target in
                                       guard let self, token.isCurrent else { return }
                                       self.confirm(self, target)
                                   },
                                   terminate: { [weak self] row in
                                       guard let self, token.isCurrent else { return }
                                       self.terminate(self, row)
                                   })
        content.focusRequest = focusRequest
        focusRequest = nil
        self.content = content
        controller.rootView = HostShell(size: dimensions, panel: content, entered: { [weak self] in self?.interact() })
        updates = model.screenUpdates.sink { [weak self, weak content] snapshot in
            guard let self, let content, self.exposure === token, token.isCurrent else { return }
            let data = PanelData(snapshot)
            self.motion.update(data)
            content.data = data
            PanelTrace.event("Screen update", self.motion.host)
        }
        PanelTrace.event("Exposure start", motion.host)
        PanelTrace.event("Screen update", motion.host)
        let sampled = model.setExposed(motion.host, exposed: true)
        requestSampleIfNeeded(alreadyRequested: sampled)
    }

    private func requestSampleIfNeeded(alreadyRequested: Bool = false) {
        guard wantsImmediateSample else { return }
        wantsImmediateSample = false
        if !alreadyRequested { model.refresh() }
    }

    func interact() {
        if isExposed { motion.interact() }
    }

    func restoreFocus(_ target: FocusTarget, presentation: UInt64) {
        guard shown, self.presentation == presentation else { return }
        let request = FocusRequest(target: target)
        if let content, isExposed {
            window?.makeKey()
            content.focusRequest = request
        } else {
            focusRequest = request
        }
    }

    private func detach(closing: Bool = false, updateState: () -> Void = {}) {
        let wasExposed = exposure != nil
        if wasExposed { model.setExposed(motion.host, exposed: false) }
        if closing {
            traceClose(motion.host)
            shown = false
            focusRequest = nil
            wantsImmediateSample = false
        }
        updateState()
        guard closing || wasExposed else { return }
        updates?.cancel()
        updates = nil
        exposure?.invalidate()
        exposure = nil
        motion.pause(closing: closing)
        content = nil
        if wasExposed {
            controller.rootView = HostShell(size: dimensions)
            PanelTrace.event("Exposure end", motion.host)
        }
    }
}

struct HostShell: View {
    let size: CGSize
    var panel: PanelContent?
    var entered: (() -> Void)?

    var body: some View {
        Group {
            if let panel {
                PanelView(content: panel)
                    .background(PointerEntry(entered: entered))
            } else {
                Ink.ground.color.frame(width: size.width, height: size.height)
            }
        }
    }
}

private struct PointerEntry: NSViewRepresentable {
    let entered: (() -> Void)?

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.entered = entered }

    final class TrackingView: NSView {
        var entered: (() -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            if tracking == nil {
                let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: nil)
                addTrackingArea(area)
                tracking = area
            }
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { entered?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
