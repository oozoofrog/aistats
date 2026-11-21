import AppKit
import CoreText

@MainActor
func verifyPanelFonts() -> Int32 {
    let fonts = PanelFonts.shared
    print("Font bundle: \(fonts.bundle?.bundleURL.path ?? "missing")")
    func runs(_ text: String, font: NSFont) -> (names: [String], glyphs: [CGGlyph], digits: [CGFloat]) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        var names: [String] = []
        var glyphs: [CGGlyph] = []
        var digits: [CGFloat] = []
        let source = text as NSString
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let face = attributes[kCTFontAttributeName] as! CTFont
            names.append(CTFontCopyPostScriptName(face) as String)
            let count = CTRunGetGlyphCount(run)
            var buffer = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, range, &buffer)
            CTRunGetStringIndices(run, range, &indices)
            CTRunGetAdvances(run, range, &advances)
            for (index, advance) in zip(indices, advances) where (48...57).contains(source.character(at: index)) {
                digits.append(advance.width)
            }
            glyphs.append(contentsOf: buffer)
        }
        return (names, glyphs, digits)
    }
    var passed = true
    for role in [Theme.TypeRole.wordmark, .instrument, .data, .reading] {
        guard let face = role.face else { continue }
        let actual = runs("AISTATS 0123456789", font: role.nsFont)
        print("\(face.rawValue): \(fonts.urls[face]?.path ?? "missing"), runs \(actual.names)")
        passed = passed && fonts.names[face] == face.rawValue && actual.names == [face.rawValue] && !actual.glyphs.contains(0)
    }
    let mixture = runs("메모리 10% / 88% · 배터리 09%", font: Theme.TypeRole.data.nsFont)
    let advances = Set(mixture.digits)
    let readable = !mixture.glyphs.isEmpty && !mixture.glyphs.contains(0) && mixture.digits.count == 6 && advances.count == 1
    print("Mixed fixture: \(mixture.names), missing glyphs \(mixture.glyphs.filter { $0 == 0 }.count), digit advances \(advances.sorted())")
    return passed && readable ? 0 : 1
}
