import AppKit
import Combine
import SwiftUI

typealias S = Theme.Size
typealias FX = Theme.Effect
typealias Ink = Theme.Ink

struct Chamfer: InsettableShape {
    var cut: CGFloat
    var insetAmount: CGFloat = 0

    static func vertices(in rect: CGRect, cut: CGFloat) -> [CGPoint] {
        let c = min(max(0, cut), rect.width / 2, rect.height / 2)
        return [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX - c, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY + c),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX + c, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY - c),
        ]
    }

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard inner.width > 0, inner.height > 0 else { return Path() }
        return polygon(Self.vertices(in: inner, cut: cut - insetAmount * (2 - sqrt(2))))
    }

    func inset(by amount: CGFloat) -> Self {
        Self(cut: cut, insetAmount: insetAmount + amount)
    }
}

private func polygon(_ vertices: [CGPoint]) -> Path {
    var path = Path()
    path.addLines(vertices)
    path.closeSubpath()
    return path
}

struct DecorationContext {
    let host: String
    let exposure: Exposure
    var usesCanvas = false

    @discardableResult
    func draw(_ artwork: Artwork, effect: EffectID? = nil, event: StaticString, paint: () -> Void) -> Bool {
        exposure.drawIfCurrent {
            if PanelTrace.isEnabled { PanelTrace.event(event, host, effect?.traceName ?? artwork.traceName) }
            paint()
        }
    }
}

enum GutterSide { case left, right }

enum Artwork: Equatable {
    case grid(GutterSide), scanlines(GutterSide), bootScan(GutterSide)
    case shimmer, hazard, warning, chartMask, chart
    case brackets(Int)
    case segments(Ink, Bool)
    case edge(CGFloat)
    case busy
    case label(InstrumentLayout, Ink)

    func visibleFrame(_ frame: EffectFrame) -> EffectFrame {
        if case .label(let layout, _) = self { return layout.visibleFrame(frame) }
        return frame
    }

    func draw(_ context: CGContext, _ size: CGSize, frame: EffectFrame, options: DisplayOptions) {
        let rect = CGRect(origin: .zero, size: size)
        switch self {
        case .grid:
            let offset = (frame.phase ?? 0) * S.gridTile
            var path = Path()
            for x in stride(from: offset - S.gridTile, through: size.width + S.gridTile, by: S.gridTile) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: S.gridStroke / 2, through: size.height, by: S.gridTile) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            stroke(context, path, color: Ink.cyan.cgColor, alpha: FX.gridAlpha, width: S.gridStroke)
        case .scanlines:
            var path = Path()
            for y in stride(from: S.scanlineStroke / 2, through: size.height, by: S.scanlineStep) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            stroke(context, path, color: Ink.ground.cgColor, alpha: FX.scanlineAlpha, width: S.scanlineStroke)
        case .bootScan:
            guard let elapsed = frame.elapsed else { return }
            let head = MotionMath.mix(-FX.bootHead, size.height + FX.bootFalloff + FX.bootHead, elapsed / Motion.boot)
            let start = head - FX.bootHead - FX.bootFalloff
            gradient(context, in: CGRect(x: 0, y: start, width: size.width, height: head - start),
                     Self.bootGradient, from: CGPoint(x: 0, y: start), to: CGPoint(x: 0, y: head))
        case .shimmer:
            guard let phase = frame.phase else { return }
            let length = FX.shimmerLength
            let head = MotionMath.mix(-S.baseStroke, size.width + length + S.baseStroke, phase)
            let tail = head - length
            let y = rect.midY
            gradient(context, in: CGRect(x: tail, y: y - FX.shimmerStroke / 2, width: length, height: FX.shimmerStroke),
                     Self.shimmerGradient, from: CGPoint(x: tail, y: y), to: CGPoint(x: head, y: y))
        case .hazard:
            context.setFillColor(Ink.ground.cgColor)
            context.fill(rect)
            let repeatWidth = S.hazardBar * 2
            let start = (frame.phase ?? 0) * repeatWidth - repeatWidth - S.hazardHeight
            var stripes = Path()
            for x in stride(from: start, through: size.width + repeatWidth, by: repeatWidth) {
                stripes.move(to: CGPoint(x: x, y: 0))
                stripes.addLine(to: CGPoint(x: x + S.hazardBar, y: 0))
                stripes.addLine(to: CGPoint(x: x + S.hazardBar - size.height, y: size.height))
                stripes.addLine(to: CGPoint(x: x - size.height, y: size.height))
                stripes.closeSubpath()
            }
            fill(context, stripes, color: Ink.amber.cgColor, alpha: FX.hazardAlpha)
        case .warning:
            guard case .warning(let remaining) = frame else { return }
            let offset = FX.warningOffset * remaining
            let inset = FX.warningOffset + S.baseStroke / 2
            let path = Chamfer(cut: S.cardChamfer).path(in: rect.insetBy(dx: inset, dy: inset).offsetBy(dx: offset, dy: 0))
            stroke(context, path, color: Ink.amber.cgColor, alpha: FX.warningAlpha * remaining, width: S.baseStroke)
        case .chartMask:
            guard let phase = frame.phase else { return }
            let head = MotionMath.mix(-FX.chartTrail, size.width + FX.chartWrapClearance, phase)
            let start = head - FX.chartHead - FX.chartTrail
            gradient(context, in: CGRect(x: start, y: 0, width: head - start, height: size.height),
                     Self.chartGradient, from: CGPoint(x: start, y: 0), to: CGPoint(x: head, y: 0))
        case .chart:
            guard case .plot(let points) = frame else { return }
            chart(context, rect: rect, points: points, glow: options.gutterEffects)
        case .brackets(let group):
            let start = Motion.bracketStarts[group]
            let elapsed = frame.elapsed ?? Motion.boot
            let inset = FX.bracketSlide + S.bracketStroke / 2 - FX.bracketSlide * (1 - MotionMath.ease((elapsed - start) / Motion.bracket))
            let arm = S.bracketArm
            let left = CGPoint(x: inset, y: inset)
            let right = CGPoint(x: size.width - inset, y: size.height - inset)
            var path = Path()
            path.addLines([CGPoint(x: left.x, y: left.y + arm), left, CGPoint(x: left.x + arm, y: left.y)])
            path.move(to: CGPoint(x: right.x - arm, y: right.y))
            path.addLine(to: right)
            path.addLine(to: CGPoint(x: right.x, y: right.y - arm))
            stroke(context, path, color: (options.increaseContrast ? Ink.focus : .cyan).cgColor, width: S.bracketStroke)
        case .segments(let ink, let available):
            if !available {
                let track = Path(rect.insetBy(dx: S.baseStroke / 2, dy: S.baseStroke / 2))
                context.setLineDash(phase: 0, lengths: [S.xs, S.slotGap])
                stroke(context, track, color: Ink.muted.cgColor, width: S.baseStroke)
                context.setLineDash(phase: 0, lengths: [])
                return
            }
            let fraction: Double
            if case .segment(let value) = frame { fraction = value ?? 0 } else { fraction = 0 }
            let width = max(0, (size.width - Double(S.slotCount - 1) * S.slotGap) / Double(S.slotCount))
            var track = Path()
            var lit = Path()
            for i in 0..<S.slotCount {
                let slot = CGRect(x: Double(i) * (width + S.slotGap), y: 0, width: width, height: size.height)
                track.addRect(slot)
                let fill = width * MotionMath.segment(fraction, slot: i)
                if fill > 0 { lit.addRect(CGRect(x: slot.minX, y: 0, width: fill, height: slot.height)) }
            }
            fill(context, track, color: Ink.track.cgColor)
            fill(context, lit, color: ink.cgColor)
        case .edge(let cut):
            guard let edge = frame.edge, edge.alpha > 0 else { return }
            let path = Chamfer(cut: cut).path(in: rect.insetBy(dx: S.baseStroke / 2, dy: S.baseStroke / 2))
            stroke(context, path, color: edge.rgb.cgColor, alpha: edge.alpha, width: S.baseStroke)
        case .busy:
            context.translateBy(x: rect.midX, y: rect.midY)
            let hex = Self.busyHexagon
            stroke(context, hex, color: Ink.cyan.cgColor, alpha: FX.inactiveOutline, width: FX.busyStroke)
            let start = frame.phase ?? 0
            let end = start + FX.busyLength
            var lit = hex.trimmedPath(from: start, to: min(1, end))
            if end > 1 { lit.addPath(hex.trimmedPath(from: 0, to: end - 1)) }
            stroke(context, lit, color: Ink.cyan.cgColor, width: FX.busyStroke)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        case .label(let layout, let ink):
            layout.draw(context, color: ink.cgColor, frame: frame)
        }
    }

    private static let busyHexagon: Path = {
        let radius = (FX.busyGlyph - FX.busyStroke) / 2
        return polygon((0..<6).map { i in
            let angle = .pi * (Double(i) / 3 - 0.5)
            return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
        })
    }()

    private static let bootGradient = bandGradient(trail: FX.bootFalloff / (FX.bootHead + FX.bootFalloff), alpha: FX.bootAlpha)
    private static let chartGradient = bandGradient(trail: FX.chartTrail / (FX.chartHead + FX.chartTrail), alpha: FX.chartScanAlpha)
    private static let shimmerGradient = makeGradient(colors: [
        Ink.cyan.cgColor.copy(alpha: 0)!, Ink.cyan.cgColor.copy(alpha: FX.shimmerAlpha)!,
        Ink.magenta.cgColor.copy(alpha: FX.shimmerAlpha)!, Ink.magenta.cgColor.copy(alpha: 0)!
    ], stops: FX.shimmerStops)

    private static func bandGradient(trail: CGFloat, alpha: CGFloat) -> CGGradient {
        let lit = Ink.cyan.cgColor.copy(alpha: alpha)!
        return makeGradient(colors: [Ink.cyan.cgColor.copy(alpha: 0)!, lit, lit], stops: [0, trail, 1])
    }

    private static func makeGradient(colors: [CGColor], stops: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: stops)!
    }

    private func gradient(_ context: CGContext, in rect: CGRect, _ gradient: CGGradient, from: CGPoint, to: CGPoint) {
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: from, end: to, options: [])
        context.restoreGState()
    }

    private func fill(_ context: CGContext, _ path: Path, color: CGColor, alpha: CGFloat = 1) {
        guard !path.isEmpty else { return }
        context.setFillColor(color)
        context.setAlpha(alpha)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setAlpha(1)
    }

    private func stroke(_ context: CGContext, _ path: Path, color: CGColor, alpha: CGFloat = 1, width: CGFloat) {
        guard !path.isEmpty else { return }
        context.setStrokeColor(color)
        context.setAlpha(alpha)
        context.setLineWidth(width)
        context.addPath(path.cgPath)
        context.strokePath()
        context.setAlpha(1)
    }

    private func chart(_ context: CGContext, rect: CGRect, points: PlotFrame, glow: Bool) {
        let width = S.traceStroke
        func position(_ point: PlotPoint) -> CGPoint {
            CGPoint(x: point.slot / Double(AppModel.sparklineLength - 1) * rect.width,
                    y: width / 2 + (rect.height - width) * (1 - point.value))
        }

        var trace = Path()
        var area = Path()
        var tail: CGPoint?
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for (left, right) in zip(points, points.dropFirst()) {
            let start = position(left), end = position(right)
            // The retiring edge is clipped by the plot, including across an interruption.
            guard max(start.x, end.x) >= 0 else { continue }
            let alpha = min(left.alpha, right.alpha)
            if alpha < 1 {
                guard alpha > 0 else { continue }
                let newArea = polygon([start, end, CGPoint(x: end.x, y: rect.maxY), CGPoint(x: start.x, y: rect.maxY)])
                fill(context, newArea, color: Ink.cyan.cgColor, alpha: FX.chartAreaAlpha * alpha)
                var edge = Path()
                edge.move(to: start)
                edge.addLine(to: end)
                stroke(context, edge, color: Ink.cyan.cgColor, alpha: alpha, width: width)
                continue
            }
            if tail != start {
                if let tail {
                    area.addLine(to: CGPoint(x: tail.x, y: rect.maxY))
                    area.closeSubpath()
                }
                trace.move(to: start)
                area.move(to: CGPoint(x: start.x, y: rect.maxY))
                area.addLine(to: start)
            }
            trace.addLine(to: end)
            area.addLine(to: end)
            tail = end
        }
        if let tail {
            area.addLine(to: CGPoint(x: tail.x, y: rect.maxY))
            area.closeSubpath()
            fill(context, area, color: Ink.cyan.cgColor, alpha: FX.chartAreaAlpha)
            if glow {
                context.setShadow(offset: .zero, blur: FX.chartGlowRadius,
                                  color: Ink.cyan.cgColor.copy(alpha: FX.chartGlowAlpha))
            }
            stroke(context, trace, color: Ink.cyan.cgColor, width: width)
        } else if let point = points.leadingDot {
            let center = position(point)
            let dot = CGRect(x: center.x - width / 2, y: center.y - width / 2, width: width, height: width)
            fill(context, Path(ellipseIn: dot), color: Ink.cyan.cgColor, alpha: point.alpha)
        }
    }

    var traceName: String {
        switch self {
        case .grid(.left): return "grid.left"
        case .grid(.right): return "grid.right"
        case .scanlines(.left): return "scanlines.left"
        case .scanlines(.right): return "scanlines.right"
        case .bootScan(.left): return "bootScan.left"
        case .bootScan(.right): return "bootScan.right"
        case .shimmer: return "shimmer"
        case .hazard: return "hazard"
        case .warning: return "warning"
        case .chartMask: return "chartMask"
        case .chart: return "chart"
        case .brackets: return "brackets"
        case .segments: return "segments"
        case .edge: return "edge"
        case .busy: return "busy"
        case .label(let layout, _): return layout.title
        }
    }
}

struct MotionArtwork: View, Equatable {
    let cell: FrameCell
    let artwork: Artwork
    let decoration: DecorationContext
    @Environment(\.panelTheme) private var theme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cell === rhs.cell && lhs.artwork == rhs.artwork && lhs.decoration.exposure === rhs.decoration.exposure
    }

    var body: some View {
        Color.clear.overlay {
            if decoration.usesCanvas {
                StaticArtwork(artwork: artwork, decoration: decoration, frame: cell.frame, options: theme.options, effect: cell.id)
                    .equatable()
            } else {
                FrameSurface(cell: cell, artwork: artwork, decoration: decoration, options: theme.options)
                    .equatable()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Invalidate only the backing layer. The enclosing SwiftUI view has no frame dependency.
struct FrameSurface: NSViewRepresentable, Equatable {
    let cell: FrameCell
    let artwork: Artwork
    let decoration: DecorationContext
    let options: DisplayOptions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cell === rhs.cell && lhs.artwork == rhs.artwork && lhs.options == rhs.options
            && lhs.decoration.exposure === rhs.decoration.exposure
    }

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) { view.configure(self) }

    final class Surface: NSView {
        private var input: FrameSurface?
        private var frames: AnyCancellable?
        private var frameToDraw = EffectFrame.none
        private weak var drawnSeed: FrameCell.LoopSeed?
        override var isFlipped: Bool { true }

        func configure(_ next: FrameSurface) {
            guard input != next else { return }
            let cellChanged = input?.cell !== next.cell
            input = next
            if cellChanged {
                wantsLayer = true
                frames = next.cell.$frame.sink { [weak self] frame in self?.setFrame(frame) }
            } else {
                setFrame(next.cell.frame)
            }
            needsDisplay = true
        }

        private func setFrame(_ frame: EffectFrame) {
            guard let input else { return }
            let visible = input.artwork.visibleFrame(frame)
            guard frameToDraw != visible else { return }
            frameToDraw = visible
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let input, !bounds.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
            let seed = input.cell.loopSeed
            // Two gutter layers share a clock, but either layer can paint its first frame later.
            let undrawnSeed = seed !== drawnSeed ? seed : nil
            let frame = undrawnSeed?.frame ?? frameToDraw
            let painted = input.decoration.draw(input.artwork, effect: input.cell.id, event: "Effect draw") {
                context.saveGState()
                context.clip(to: bounds)
                input.artwork.draw(context, bounds.size, frame: frame, options: input.options)
                context.restoreGState()
            }
            guard painted else { return }
            drawnSeed = seed
            if undrawnSeed == nil || frame == frameToDraw { input.cell.recordDraw(frame) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct StaticArtwork: View, Equatable {
    let artwork: Artwork
    let decoration: DecorationContext?
    var frame: EffectFrame = .none
    var options = DisplayOptions()
    var effect: EffectID?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artwork == rhs.artwork && lhs.frame == rhs.frame && lhs.options == rhs.options && lhs.effect == rhs.effect
            && lhs.decoration?.exposure === rhs.decoration?.exposure
    }

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                cg.saveGState()
                cg.clip(to: CGRect(origin: .zero, size: size))
                if let decoration {
                    decoration.draw(artwork, effect: effect, event: "Canvas draw") {
                        artwork.draw(cg, size, frame: frame, options: options)
                    }
                } else {
                    artwork.draw(cg, size, frame: frame, options: options)
                }
                cg.restoreGState()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .clipped()
    }
}

struct CardSurface: View {
    var cut = S.cardChamfer
    var outline = Ink.muted
    var opacity = FX.neutralOutline
    var glow = false
    @Environment(\.panelTheme) private var theme

    var body: some View {
        let shape = Chamfer(cut: cut)
        let color = theme.options.increaseContrast ? Ink.focus.color : outline.color.opacity(opacity)
        shape.fill(Ink.surface.color)
            .overlay {
                if glow, theme.options.gutterEffects {
                    shape.strokeBorder(outline.color, lineWidth: S.baseStroke)
                        .blur(radius: FX.outlineGlowRadius)
                        .opacity(FX.outlineGlowAlpha)
                        .mask(shape.stroke(lineWidth: FX.outlineGlowRadius * 2))
                }
                shape.strokeBorder(color, lineWidth: theme.boundary)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum PanelButtonKind {
    case primary, secondary, destructive

    var background: Ink {
        switch self {
        case .primary: return .cyan
        case .secondary: return .surface
        case .destructive: return .amber
        }
    }
}

struct PanelButtonStyle: ButtonStyle {
    var kind = PanelButtonKind.secondary
    var focused = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, kind: kind, focused: focused)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let kind: PanelButtonKind
        let focused: Bool
        @Environment(\.panelTheme) private var theme
        @State private var hovering = false

        var body: some View {
            let shape = Chamfer(cut: S.smallChamfer)
            let button = configuration.label
                .font(Theme.TypeRole.heading.font)
                .foregroundStyle((kind == .secondary ? Ink.text : .ground).color)
                .padding(.horizontal, S.md)
                .frame(minWidth: S.buttonWidth, minHeight: S.buttonHeight)
                .background { shape.fill(kind.background.color) }
                .overlay { shape.strokeBorder(outline.color, lineWidth: width).allowsHitTesting(false).accessibilityHidden(true) }
                .contentShape(shape)
                .onHover { hovering = $0 }
            button
                .padding(S.focusGap + S.focusStroke)
                .background {
                    if focused {
                        let outer = Chamfer(cut: S.smallChamfer + (S.focusGap + S.focusStroke) * (2 - sqrt(2)))
                        ZStack {
                            outer.fill(Ink.ground.color)
                            outer.strokeBorder(Ink.focus.color, lineWidth: S.focusStroke)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
        }

        private var outline: Ink {
            if theme.options.increaseContrast { return .focus }
            if configuration.isPressed || hovering { return kind == .secondary ? .cyan : .ground }
            return kind == .secondary ? .muted : kind.background
        }

        private var width: CGFloat {
            configuration.isPressed || theme.options.increaseContrast ? S.contrastStroke : S.baseStroke
        }
    }
}
