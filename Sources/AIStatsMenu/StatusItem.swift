import AppKit

struct StatusPresentation: Equatable {
    let title: String
    let tooltip: String
    let glyphs: StatusGlyphs

    @MainActor
    init(model: AppModel) {
        let screen = model.screen
        title = screen.sample.map(AppModel.title(for:)) ?? "AIStats"
        tooltip = screen.agents.isEmpty ? "AIStats" : "AIStats · 에이전트 \(screen.agents.count)개 연결됨"
        glyphs = StatusGlyphs(activity: model.agentActiveRecently, warning: model.hasWarning)
    }

    @MainActor
    func apply(to button: NSStatusBarButton, after last: Self?) {
        if title != last?.title {
            button.title = title
            PanelTrace.event("Status write", "", "title")
        }
        if glyphs != last?.glyphs {
            button.image = glyphs.image
            PanelTrace.event("Status write", "", "image")
        }
        if tooltip != last?.tooltip {
            button.toolTip = tooltip
            PanelTrace.event("Status write", "", "tooltip")
        }
        if title != last?.title || glyphs != last?.glyphs {
            button.setAccessibilityLabel(([title] + glyphs.descriptions).joined(separator: " · "))
            PanelTrace.event("Status write", "", "accessibility")
        }
    }
}

struct StatusGlyphs: Equatable {
    var activity: Bool
    var warning: Bool

    var descriptions: [String] {
        (activity ? ["에이전트가 조회 중"] : []) + (warning ? ["시스템 경고"] : [])
    }

    var image: NSImage? {
        guard activity || warning else { return nil }
        let gap = S.xs
        let height = S.warningGlyph
        let width = (activity ? S.statusGlyph : 0) + (warning ? height : 0) + (activity && warning ? gap : 0)
        let result = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            NSColor.black.set()
            if activity {
                let w = S.statusGlyph
                let x = w / 2, y = rect.midY
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: x, y: y - x))
                diamond.line(to: NSPoint(x: w, y: y))
                diamond.line(to: NSPoint(x: x, y: y + x))
                diamond.line(to: NSPoint(x: 0, y: y))
                diamond.line(to: NSPoint(x: x, y: y))
                diamond.line(to: NSPoint(x: S.xxs, y: y - S.xxs))
                diamond.close()
                diamond.fill()
            }
            if warning {
                let x = rect.maxX - height, mid = x + height / 2
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: mid, y: 1))
                triangle.line(to: NSPoint(x: rect.maxX - 1, y: height - 1))
                triangle.line(to: NSPoint(x: x + 1, y: height - 1))
                triangle.close()
                triangle.move(to: NSPoint(x: mid, y: S.xs + 1))
                triangle.line(to: NSPoint(x: mid, y: S.md))
                triangle.lineWidth = 1.25
                triangle.stroke()
                NSBezierPath(ovalIn: NSRect(x: mid - 0.75, y: height - S.xs, width: 1.5, height: 1.5)).fill()
            }
            return true
        }
        result.isTemplate = true
        result.accessibilityDescription = descriptions.joined(separator: " · ")
        return result
    }
}
