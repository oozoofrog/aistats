import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Same panel in a regular window, for when the menu bar is too crowded to show the item.
    private var window: NSWindow?

    private var model: AppModel!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
            button.imagePosition = .imageLeading
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        updateButton()
        if ProcessInfo.processInfo.environment["AISTATS_OPEN_WINDOW"] == "1" { showWindow() }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the panel as a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PanelView(model: model)))
            w.title = "AIStats"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.setPanel("window", visible: true)
    }


    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.title = model.menuTitle
        // A small mark while an agent is reading stats, so you can see AIStats being used.
        if model.agentActiveRecently {
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "에이전트가 조회 중")
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = nil
        }
        button.toolTip = model.agents.isEmpty ? "AIStats" : "AIStats · 에이전트 \(model.agents.count)개 연결됨"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        model.setPanel("popover", visible: true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPanel("popover", visible: false)
    }

    func windowWillClose(_ notification: Notification) {
        model.setPanel("window", visible: false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.setPanel("window", visible: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.setPanel("window", visible: true)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
