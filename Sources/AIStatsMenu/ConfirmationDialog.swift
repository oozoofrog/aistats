import AppKit
import StatsCore
import SwiftUI

struct ReplacementConsent {
    let target: AgentTarget
    let summary: String
    let fingerprint: String

    init?(target: AgentTarget, row: AppModel.AgentRow?) {
        guard row?.busy == false, case .nameConflict(let summary)? = row?.state,
              let fingerprint = row?.fingerprint, fingerprint.utf8.count == 12,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { return nil }
        self.target = target
        self.summary = summary
        self.fingerprint = fingerprint
    }
}

@MainActor
final class ConfirmationDialog: NSObject, NSWindowDelegate {
    let consent: ReplacementConsent
    private let panel: CancelOnReturnPanel
    private let appearance: Appearance
    private var active = false

    init(consent: ReplacementConsent, theme: Theme, screen: NSScreen?) {
        self.consent = consent
        appearance = Appearance(theme)
        let size = S.fit(CGSize(width: S.dialogWidth, height: S.dialogHeight), on: screen)
        panel = CancelOnReturnPanel(contentRect: CGRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.title = "AIStats"
        panel.setAccessibilityLabel("\(consent.target.displayName)의 aistats 항목을 바꿀까요?")
        panel.contentViewController = NSHostingController(rootView: DialogView(
            consent: consent, appearance: appearance, size: size,
            cancel: { [weak self] in self?.finish(.cancel) },
            replace: { [weak self] in self?.finish(.OK) }
        ))
        panel.cancel = { [weak self] in self?.finish(.cancel) }
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
    }

    func settings(_ theme: Theme) {
        appearance.theme = theme
        PanelTrace.event("Display options applied", "dialog")
    }

    func run() -> Bool {
        active = true
        panel.makeKeyAndOrderFront(nil)
        let result = NSApp.runModal(for: panel)
        active = false
        panel.orderOut(nil)
        return result == .OK
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.cancel)
        return false
    }

    private func finish(_ result: NSApplication.ModalResponse) {
        guard active else { return }
        active = false
        NSApp.stopModal(withCode: result)
    }

    private final class CancelOnReturnPanel: NSPanel {
        var cancel: (() -> Void)?

        override func sendEvent(_ event: NSEvent) {
            // Return, keypad Enter, and Escape cancel irrespective of focus.
            if event.type == .keyDown, [36, 76, 53].contains(event.keyCode) {
                cancel?()
                return
            }
            super.sendEvent(event)
        }

        override func cancelOperation(_ sender: Any?) { cancel?() }
    }

    private final class Appearance: ObservableObject {
        @Published var theme: Theme
        init(_ theme: Theme) { self.theme = theme }
    }

    private struct DialogView: View {
        enum Focus: Hashable { case cancel, replace }
        let consent: ReplacementConsent
        @ObservedObject var appearance: Appearance
        let size: CGSize
        let cancel: () -> Void
        let replace: () -> Void
        @FocusState private var focus: Focus?

        var body: some View {
            VStack(alignment: .leading, spacing: S.sectionGap) {
                StaticArtwork(artwork: .hazard, decoration: nil).frame(height: S.hazardHeight)
                Text("\(consent.target.displayName)의 aistats 항목을 바꿀까요?")
                    .font(Theme.TypeRole.dialog.font)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text("이미 등록된 명령을 이 앱의 aistats로 덮어씁니다.")
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: S.rowGap) {
                        Text("현재 항목: ") + Text(consent.summary).font(Theme.TypeRole.data.font)
                        Text("항목 지문: ") + Text(consent.fingerprint).font(Theme.TypeRole.data.font)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("최종 확인에서 항목이 바뀐 것으로 확인되면 덮어쓰지 않습니다. 바꾸기 전 설정 파일은 AIStats 데이터 폴더(backups)에 백업합니다.")
                    .foregroundStyle(appearance.theme.detail)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: S.xxs) {
                    Spacer()
                    Button("취소", action: cancel)
                        .buttonStyle(PanelButtonStyle(focused: focus == .cancel))
                        .focusEffectDisabled()
                        .focused($focus, equals: .cancel)
                    Button("덮어쓰기", action: replace)
                        .buttonStyle(PanelButtonStyle(kind: .destructive, focused: focus == .replace))
                        .focusEffectDisabled()
                        .focused($focus, equals: .replace)
                }
            }
            .font(Theme.TypeRole.body.font)
            .foregroundStyle(Ink.text.color)
            .padding(S.dialogInset)
            .frame(width: size.width, height: size.height)
            .background { CardSurface(cut: S.dialogChamfer, outline: .amber, opacity: 1) }
            .background(Ink.ground.color)
            .environment(\.panelTheme, appearance.theme)
            .defaultFocus($focus, .cancel)
            .onAppear { focus = .cancel }
        }
    }
}
