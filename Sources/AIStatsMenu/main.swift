import AppKit
import Combine
import UserNotifications
import StatsCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private let storage = StorageScheduler.live()
    private let lineage = LineageController.live()
    private var closedPanelRecording = UserDefaults.standard.bool(forKey: Lineage.closedPanelKey)
    private let clock = AnimationClock()
    private var theme = Theme(options: .current)
    private let popover = NSPopover()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusPresentation: StatusPresentation?
    private var window: NSWindow?
    private var dialog: ConfirmationDialog?
    private var observers = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private lazy var popupHost = makeHost("popover")
    private lazy var windowHost = makeHost("window")

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        UserDefaults.standard.bool(forKey: "originAlerts") ? [.banner, .list] : []
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if OriginAlertRule.supportsNotifications {
            UNUserNotificationCenter.current().delegate = self
        }
        _ = PanelFonts.shared
        storage.observeConditions()
        storage.start()
        model.exposureChanged = { [lineage] exposed in lineage.update { $0.exposed = exposed } }
        model.sessionsChanged = { [lineage] in lineage.sessionsChanged() }
        lineage.sessionsChanged()
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                let on = UserDefaults.standard.bool(forKey: Lineage.closedPanelKey)
                guard on != self.closedPanelRecording else { return }
                self.closedPanelRecording = on
                self.lineage.update { $0.closedPanel = on }
            }
            .store(in: &observers)
        if let button = statusItem.button {
            button.setAccessibilityIdentifier("aistats.statusItem")
            button.setAccessibilityHelp("AIStats 팝오버를 열거나 닫습니다.")
            button.target = self
            button.action = #selector(togglePopover)
            button.font = S.statusFont
            button.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = popupHost.controller
        model.statusUpdates.sink { [weak self] in self?.updateButton() }.store(in: &observers)
        updateButton()

        DisplayOptions.observeChanges { [weak self] in self?.updateSettings() }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.popupHost.isExposed || self.windowHost.isExposed else { return }
                self.model.refreshLaunchAtLogin()
            }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow else { return }
                if window === self.window { self.windowHost.reconcile() }
                if window === self.popupHost.window { self.popupHost.reconcile() }
            }
            .store(in: &observers)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            if let self, let window = event.window {
                if window === self.window { self.windowHost.interact() }
                if window === self.popupHost.window { self.popupHost.interact() }
            }
            return event
        }
        if ProcessInfo.processInfo.environment["AISTATS_OPEN_WINDOW"] == "1" { showWindow() }
    }

    private func makeHost(_ id: String) -> PanelHost {
        PanelHost(id: id, model: model, clock: clock, theme: theme,
                  confirm: { [weak self] in self?.confirmReplace(from: $0, target: $1) },
                  terminate: { [weak self] in self?.confirmTermination(from: $0, row: $1) })
    }

    func applicationWillTerminate(_ notification: Notification) { lineage.shutdown() }

    private func updateSettings() {
        let next = DisplayOptions.current
        guard theme.options != next else { return }
        theme = Theme(options: next)
        popupHost.settings(theme)
        windowHost.settings(theme)
        dialog?.settings(theme)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationWillHide(_ notification: Notification) {
        popupHost.setApplicationHidden(true)
        windowHost.setApplicationHidden(true)
    }

    func applicationDidUnhide(_ notification: Notification) {
        popupHost.setApplicationHidden(false)
        windowHost.setApplicationHidden(false)
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: windowHost.controller)
            w.title = "AIStats"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(windowHost.size)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
            windowHost.window = w
        }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        windowHost.open(on: window.screen ?? NSScreen.main)
        if window.isMiniaturized {
            window.deminiaturize(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        windowHost.reconcile()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let next = StatusPresentation(model: model)
        guard next != statusPresentation else { return }
        next.apply(to: button, after: statusPresentation)
        statusPresentation = next
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popupHost.open(on: button.window?.screen ?? NSScreen.main)
            popover.contentSize = popupHost.size
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            attachPopoverWindow()
            popupHost.window?.makeKey()
        }
    }

    private func attachPopoverWindow() {
        if let window = popupHost.controller.view.window {
            window.setAccessibilityIdentifier("aistats.popover")
            window.setAccessibilityLabel("AIStats 팝오버")
            popupHost.window = window
            popupHost.reconcile()
        }
    }

    func popoverDidShow(_ notification: Notification) { attachPopoverWindow() }
    func popoverWillClose(_ notification: Notification) { popupHost.close() }
    func popoverDidClose(_ notification: Notification) { popupHost.window = nil }

    func windowWillClose(_ notification: Notification) { windowHost.close() }
    func windowWillMiniaturize(_ notification: Notification) { windowHost.setMinimizing(true) }
    func windowDidMiniaturize(_ notification: Notification) { windowHost.setMinimizing(true) }
    func windowDidDeminiaturize(_ notification: Notification) { windowHost.setMinimizing(false) }

    func windowDidChangeScreen(_ notification: Notification) {
        windowHost.resize(on: window?.screen)
        windowHost.reconcile()
    }

    private func confirmReplace(from host: PanelHost, target: AgentTarget) {
        guard let consent = ReplacementConsent(target: target, row: model.screen.registrations[target]) else { return }
        present(consent, from: host)
    }

    private func confirmTermination(from host: PanelHost, row: OrphanReport.Row) {
        present(TerminationConsent(row: row), from: host)
    }

    /// One app-modal panel per action (ADR 0007). The consent runs its action only after an explicit confirmation.
    /// Focus returns to the initiating row or action if the Host remains open.
    private func present(_ consent: some Consent, from host: PanelHost) {
        guard dialog == nil, host.isExposed else { return }
        let modal = ConfirmationDialog(consent.dialog, theme: theme, screen: host.window?.screen)
        let presentation = host.presentation
        dialog = modal
        let fromPopover = host === popupHost
        if fromPopover { popover.behavior = .applicationDefined }
        let confirmed = modal.run()
        if fromPopover { popover.behavior = .transient }
        dialog = nil
        if confirmed { consent.confirm(model) }
        let focus = consent.focus
        DispatchQueue.main.async { [weak host] in host?.restoreFocus(focus, presentation: presentation) }
    }
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if arguments.dropFirst() == ["--verify-fonts"] { exit(verifyPanelFonts()) }
    if arguments.count == 3, arguments[1] == "--render-fixtures" {
        do {
            try PanelFixtures.render(to: URL(fileURLWithPath: arguments[2], isDirectory: true))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
