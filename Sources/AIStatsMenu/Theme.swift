import AppKit
import Combine
import CoreText
import SwiftUI

struct DisplayOptions: Equatable {
    var reduceMotion = false
    var increaseContrast = false
    var reduceTransparency = false

    static var current: Self {
        let workspace = NSWorkspace.shared
        return Self(reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                    increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                    reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
    }

    static func observeChanges(in center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                               _ update: @escaping @MainActor () -> Void) -> AnyCancellable {
        let mainLoop = CFRunLoopGetMain()
        let modes = [RunLoop.Mode.common.rawValue, RunLoop.Mode.modalPanel.rawValue] as CFArray
        let observer = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                          object: nil, queue: nil) { _ in
            CFRunLoopPerformBlock(mainLoop, modes) { MainActor.assumeIsolated { update() } }
            CFRunLoopWakeUp(mainLoop)
        }
        return AnyCancellable { center.removeObserver(observer) }
    }

    var gutterEffects: Bool { !increaseContrast && !reduceTransparency }
}

struct Theme {
    var options = DisplayOptions()
    var detail: Color { (options.increaseContrast ? Ink.text : Ink.muted).color }
    var boundary: CGFloat { options.increaseContrast ? Size.contrastStroke : Size.baseStroke }

    enum Ink: UInt32, CaseIterable {
        case ground = 0x07060D, surface = 0x0E0C1A, cyan = 0x00F0FF, amber = 0xFFB000
        case green = 0x39FF88, magenta = 0xFF2A6D, text = 0xE8E6F5, muted = 0x9A97B8, track = 0x1E1A35
        static let focus = Self.text
        var rgb: RGB { RGB(hex: rawValue) }
        var color: Color { rgb.color }
        private static let cgColors = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.rgb.cgColor) })
        var cgColor: CGColor { Self.cgColors[self]! }
    }

    enum TypeRole {
        case wordmark, instrument, cpu, percent, reading, data, heading, body, dialog

        var face: PanelFonts.Face? {
            switch self {
            case .wordmark: return .orbitronBlack
            case .instrument: return .orbitronBold
            case .cpu, .percent, .reading: return .monoBold
            case .data: return .monoRegular
            default: return nil
            }
        }

        var size: CGFloat {
            switch self {
            case .wordmark: return 22
            case .instrument: return 11
            case .cpu: return 34
            case .percent: return 18
            case .reading: return 16
            case .data, .body: return 12
            case .heading: return 13
            case .dialog: return 17
            }
        }

        var tracking: CGFloat {
            switch self {
            case .wordmark: return 2
            case .instrument: return 1
            default: return 0
            }
        }

        var weight: NSFont.Weight {
            switch self {
            case .wordmark: return .black
            case .instrument, .cpu, .percent, .reading, .dialog: return .bold
            case .heading: return .semibold
            default: return .regular
            }
        }

        var nsFont: NSFont { nsFont(using: .shared) }

        func nsFont(using fonts: PanelFonts) -> NSFont {
            if let face, let name = fonts.names[face], let font = NSFont(name: name, size: size) {
                return font
            }
            if face == .monoBold || face == .monoRegular {
                return .monospacedSystemFont(ofSize: size, weight: weight)
            }
            return .systemFont(ofSize: size, weight: weight)
        }

        var font: Font { Font(nsFont) }

    }

    enum Size {
        static let panelWidth: CGFloat = 380
        static let panelHeight: CGFloat = 760
        static let dialogWidth: CGFloat = 412
        static let dialogHeight: CGFloat = 420
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let displayMargin: CGFloat = 24
        static let panelInset = xl
        static let sectionGap = lg
        static let cardInset = lg
        static let rowGap = sm
        static let iconGap = md
        static let tileGap = md
        static let dialogInset = xxl
        static let cardChamfer: CGFloat = 12
        static let smallChamfer: CGFloat = 7
        static let dialogChamfer: CGFloat = 16
        static let bracketArm: CGFloat = 9
        static let bracketStroke: CGFloat = 2
        static let baseStroke: CGFloat = 1
        static let focusStroke: CGFloat = 2
        static let contrastStroke: CGFloat = 2
        static let focusGap: CGFloat = 2
        static let gutter: CGFloat = 6
        static let gutterInset: CGFloat = 2
        static let buttonWidth: CGFloat = 44
        static let buttonHeight: CGFloat = 28
        static let statusGlyph: CGFloat = 8
        static let warningGlyph: CGFloat = 14
        static let plotHeight: CGFloat = 48
        static let traceStroke: CGFloat = 1.5
        static let slotCount = 24
        static let slotHeight: CGFloat = 6
        static let slotGap: CGFloat = 2
        static let hazardHeight: CGFloat = 4
        static let hazardBar: CGFloat = 8
        static let gridTile: CGFloat = 20
        static let gridStroke: CGFloat = 1
        static let scanlineStep: CGFloat = 4
        static let scanlineStroke: CGFloat = 1
        static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)

        static func fit(_ maximum: CGSize, on screen: NSScreen?) -> CGSize {
            guard let visible = screen?.visibleFrame else { return maximum }
            return CGSize(width: min(maximum.width, max(1, visible.width - displayMargin)),
                          height: min(maximum.height, max(1, visible.height - displayMargin)))
        }
    }

    enum Effect {
        static let neutralOutline = 0.55
        static let inactiveOutline = 0.42
        static let cyanOutline = 0.45
        static let gridAlpha = 0.045
        static let scanlineAlpha = 0.10
        static let outlineGlowRadius: CGFloat = 6
        static let chartGlowRadius: CGFloat = 3
        static let outlineGlowAlpha = 0.22
        static let chartGlowAlpha = 0.30
        static let chartAreaAlpha = 0.08
        static let chartHead: CGFloat = 2
        static let chartTrail: CGFloat = 24
        static let chartScanAlpha = 0.24
        static let chartWrapClearance: CGFloat = 50
        static let bootHead: CGFloat = 2
        static let bootFalloff: CGFloat = 12
        static let bootAlpha = 0.22
        static let shimmerStroke: CGFloat = 1
        static let shimmerLength: CGFloat = 36
        static let shimmerAlpha = 0.18
        static let shimmerStops: [CGFloat] = [0.0, 0.25, 0.75, 1.0]
        static let bracketSlide: CGFloat = 4
        static let hazardAlpha = 0.50
        static let warningOffset: CGFloat = 2
        static let warningAlpha = 0.24
        static let readingAlpha = 0.24
        static let resultAlpha = 0.22
        static let busyGlyph: CGFloat = 12
        static let busyStroke: CGFloat = 1.5
        static let busyLength = 1.0 / 3
    }

    enum Motion {
        static let boot = 0.360
        static let bracket = 0.180
        static let bracketStarts = [0.0, 0.040, 0.080]
        static let decode = 0.360
        static let letterDeadline = 0.036
        static let glyphInterval = 0.060
        static let readingRise = 0.040
        static let readingDecay = 0.100
        static let transition = 0.180
        static let chart = 4.0
        static let grid = 16.0
        static let hazard = 1.2
        static let shimmer = 8.0
        static let warning = 0.150
        static let warningCooldown = 1.0
        static let busy = 1.0
        static let resultRise = 0.060
        static let resultDecay = 0.180
        static let quietPeriod = 12.0
        static let oneShotFPS = 30.0
        static let loopFPS = 15.0
        static let quietGutterFPS = 8.0
        static let quietChartFPS = 10.0
        static let easeOut = (0.20, 0.80, 0.20, 1.0)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme()
}

extension EnvironmentValues {
    var panelTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

struct RGB: Equatable {
    var cgColor: CGColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor }
    var red: Double
    var green: Double
    var blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 255) / 255
        green = Double((hex >> 8) & 255) / 255
        blue = Double(hex & 255) / 255
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    func toward(_ target: RGB, by fraction: Double) -> RGB {
        var value = self
        value.red += (target.red - red) * fraction
        value.green += (target.green - green) * fraction
        value.blue += (target.blue - blue) * fraction
        return value
    }
}

struct PanelFonts {
    enum Face: String, CaseIterable {
        case orbitronBlack = "Orbitron-Black"
        case orbitronBold = "Orbitron-Bold"
        case monoRegular = "JetBrainsMono-Regular"
        case monoBold = "JetBrainsMono-Bold"
    }

    static let shared = Self()
    private static let bundleName = "AIStats_AIStatsMenu.bundle"

    let bundle: Bundle?
    let urls: [Face: URL]
    let names: [Face: String]

    init(bundle: Bundle? = Self.resourceBundle()) {
        self.bundle = bundle
        var urls: [Face: URL] = [:]
        var names: [Face: String] = [:]
        for face in Face.allCases {
            guard let url = bundle?.url(forResource: face.rawValue, withExtension: "ttf", subdirectory: "Fonts") else { continue }
            urls[face] = url
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) else { continue }
            names[face] = name
        }
        self.urls = urls
        self.names = names
    }

    static func resourceBundle() -> Bundle? {
        let locations = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for directory in locations.compactMap({ $0 }) {
            if let bundle = Bundle(url: directory.appendingPathComponent(bundleName)) { return bundle }
        }
        return nil
    }
}
