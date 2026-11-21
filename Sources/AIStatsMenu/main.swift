import AppKit
import Combine
import UserNotifications
import StatsCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
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
        if Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        _ = PanelFonts.shared
        if let button = statusItem.button {
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
        PanelHost(id: id, model: model, clock: clock, theme: theme) { [weak self] in self?.confirmReplace(from: $0, target: $1) }
    }

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
        guard dialog == nil, host.isExposed,
              let consent = ReplacementConsent(target: target, row: model.screen.registrations[target]) else { return }
        let modal = ConfirmationDialog(consent: consent, theme: theme, screen: host.window?.screen)
        let presentation = host.presentation
        dialog = modal
        let fromPopover = host === popupHost
        if fromPopover { popover.behavior = .applicationDefined }
        let confirmed = modal.run()
        if fromPopover { popover.behavior = .transient }
        dialog = nil
        if confirmed { model.perform(.replace(fingerprint: consent.fingerprint), consent.target) }
        DispatchQueue.main.async { [weak host] in host?.restoreFocus(target, presentation: presentation) }
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
