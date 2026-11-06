// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns text into cut lines with Core Text. The font size is the em
// height in millimetres; letters missing in the font come from the
// system fallback fonts.

import AppKit
import CoreText

enum TextOutliner {
    /// Line spacing as a multiple of the natural line height.
    static let lineSpacing: CGFloat = 1.0

    /// Cut lines for the text in mm, y down, baseline of the first line at y = ascent.
    static func paths(for spec: TextSpec) -> [Polyline] {
        let path = cgPath(for: spec)
        return path.polylines(tolerance: ShapeImporter.tolerance)
    }

    static func cgPath(for spec: TextSpec) -> CGPath {
        let size = max(CGFloat(spec.sizeMM), 0.5)
        let font = CTFontCreateWithName(spec.fontName as CFString, size, nil)
        let ascent = CTFontGetAscent(font)
        let lineHeight = (ascent + CTFontGetDescent(font) + CTFontGetLeading(font)) * lineSpacing
        let result = CGMutablePath()

        let lines = spec.text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let baseline = ascent + CGFloat(index) * lineHeight
            let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let runFontRef = attrs[kCTFontAttributeName as String]
                // Fallback fonts are set per run by Core Text
                let runFont = runFontRef.map { $0 as! CTFont } ?? font
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                for i in 0..<count {
                    // Glyphs have y up: flip around the baseline
                    var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                              tx: positions[i].x, ty: baseline - positions[i].y)
                    if let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], &t) {
                        result.addPath(glyphPath)
                    }
                }
            }
        }
        return result
    }
}

/// Installed fonts for the text inspector.
enum FontCatalog {
    struct Face: Identifiable, Hashable {
        let postScriptName: String
        let styleName: String
        var id: String { postScriptName }
    }

    static var families: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    }

    static func faces(of family: String) -> [Face] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { m in
            guard m.count >= 2, let ps = m[0] as? String, let style = m[1] as? String else { return nil }
            return Face(postScriptName: ps, styleName: style)
        }
    }

    static func family(ofPostScriptName name: String) -> String? {
        NSFont(name: name, size: 12)?.familyName
    }

    static let defaultFontName = "HelveticaNeue-Bold"

    static func defaultSpec(text: String = "Schnittwerk") -> TextSpec {
        TextSpec(text: text, fontName: defaultFontName, sizeMM: 25)
    }
}

extension CutShape {
    /// New text object; its top left corner sits at `origin` on the mat.
    static func text(_ spec: TextSpec, at origin: CGPoint) -> CutShape? {
        let lines = TextOutliner.paths(for: spec)
        guard !lines.isEmpty else { return nil }
        let b = lines.bounds
        let moved = lines.applying(CGAffineTransform(translationX: origin.x - b.minX, y: origin.y - b.minY))
        let firstLine = spec.text.components(separatedBy: .newlines).first ?? spec.text
        return CutShape(name: firstLine, matPaths: moved, text: spec)
    }

    /// Applies a changed text setting and rebuilds the cut lines.
    /// Returns false if the text gives no lines (e.g. only spaces).
    @discardableResult
    mutating func updateText(_ spec: TextSpec) -> Bool {
        let lines = TextOutliner.paths(for: spec)
        guard !lines.isEmpty else { return false }
        // Keep the left edge in place when the text gets longer
        let oldLeft = matBounds.minX
        let oldTop = matBounds.minY
        text = spec
        replaceGeometry(lines)
        name = spec.text.components(separatedBy: .newlines).first ?? spec.text
        let b = matBounds
        position.x += oldLeft - b.minX
        position.y += oldTop - b.minY
        return true
    }
}
