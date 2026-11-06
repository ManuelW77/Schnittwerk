// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// SVG reader for cut lines. Supports path, rect, circle, ellipse, line,
// polyline, polygon, groups, nested svg and transform. Text, images and
// <use> are skipped with a note.

import CoreGraphics
import Foundation

enum SVGImporter {
    /// SVG user units without a viewBox are CSS pixels (96 per inch).
    static let mmPerPixel: CGFloat = 25.4 / 96

    static func parse(_ data: Data) throws -> ImportResult {
        let delegate = SVGDocumentReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() || delegate.sawRoot else { throw ImportError.unreadable }
        guard delegate.sawRoot else { throw ImportError.unreadable }
        let lines = delegate.output.polylines(tolerance: ShapeImporter.tolerance)
        return ImportResult(paths: lines, warnings: delegate.warnings.uniqued())
    }

    // MARK: - Lengths

    /// Length in SVG user units (px). Returns nil for percentages.
    static func length(_ raw: String?) -> CGFloat? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("%") { return nil }
        let units: [(String, CGFloat)] = [("mm", 96 / 25.4), ("cm", 96 / 2.54), ("in", 96),
                                         ("pt", 96.0 / 72.0), ("pc", 16), ("px", 1)]
        var factor: CGFloat = 1
        for (suffix, f) in units where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            factor = f
            break
        }
        guard let v = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGFloat(v) * factor
    }

    static func numbers(_ raw: String?) -> [CGFloat] {
        guard let raw else { return [] }
        var scanner = NumberScanner(raw)
        var out: [CGFloat] = []
        while let n = scanner.number() { out.append(n) }
        return out
    }

    // MARK: - transform="…"

    static func transform(_ raw: String?) -> CGAffineTransform {
        guard let raw, !raw.isEmpty else { return .identity }
        var result = CGAffineTransform.identity
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r"))
            let args = numbers(String(rest[rest.index(after: open)..<close]))
            var t = CGAffineTransform.identity
            switch name {
            case "matrix" where args.count == 6:
                t = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case "translate" where !args.isEmpty:
                t = CGAffineTransform(translationX: args[0], y: args.count > 1 ? args[1] : 0)
            case "scale" where !args.isEmpty:
                t = CGAffineTransform(scaleX: args[0], y: args.count > 1 ? args[1] : args[0])
            case "rotate" where !args.isEmpty:
                let a = args[0] * .pi / 180
                if args.count >= 3 {
                    t = CGAffineTransform(translationX: args[1], y: args[2])
                        .rotated(by: a)
                        .translatedBy(x: -args[1], y: -args[2])
                } else {
                    t = CGAffineTransform(rotationAngle: a)
                }
            case "skewX" where !args.isEmpty:
                t = CGAffineTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY" where !args.isEmpty:
                t = CGAffineTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                break
            }
            // "A B" means: apply B first, then A
            result = t.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

// MARK: - XML walk

private final class SVGDocumentReader: NSObject, XMLParserDelegate {
    let output = CGMutablePath()
    var warnings: [String] = []
    var sawRoot = false

    private var ctmStack: [CGAffineTransform] = []
    private var skipDepth = 0

    private static let skipped: Set<String> = [
        "defs", "clipPath", "mask", "symbol", "pattern", "marker", "metadata", "title", "desc",
        "style", "script", "linearGradient", "radialGradient", "filter", "namedview", "foreignObject",
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if skipDepth > 0 { skipDepth += 1; return }

        if Self.skipped.contains(name) || isHidden(attributes) {
            skipDepth = 1
            return
        }

        let parent = ctmStack.last ?? .identity
        var ctm = SVGImporter.transform(attributes["transform"]).concatenating(parent)

        if name == "svg" {
            if !sawRoot {
                sawRoot = true
                ctm = rootTransform(attributes).concatenating(ctm)
            } else {
                let x = SVGImporter.length(attributes["x"]) ?? 0
                let y = SVGImporter.length(attributes["y"]) ?? 0
                ctm = CGAffineTransform(translationX: x, y: y).concatenating(ctm)
            }
        }
        ctmStack.append(ctm)

        switch name {
        case "text", "tspan", "textPath":
            warnings.append(String(localized: "Text in the SVG was skipped. Convert text to paths before exporting."))
        case "image":
            warnings.append(String(localized: "Images in the SVG were skipped. Only lines can be cut."))
        case "use":
            warnings.append(String(localized: "Linked copies (<use>) in the SVG were skipped."))
        default:
            if let shape = Self.shapePath(name, attributes) {
                output.addPath(shape, transform: ctm)
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        if !ctmStack.isEmpty { ctmStack.removeLast() }
    }

    private func isHidden(_ a: [String: String]) -> Bool {
        if a["display"] == "none" || a["visibility"] == "hidden" { return true }
        if let style = a["style"]?.replacingOccurrences(of: " ", with: "") {
            return style.contains("display:none") || style.contains("visibility:hidden")
        }
        return false
    }

    /// viewBox and width/height → millimetres.
    private func rootTransform(_ a: [String: String]) -> CGAffineTransform {
        let vb = SVGImporter.numbers(a["viewBox"])
        let px = SVGImporter.mmPerPixel
        guard vb.count == 4, vb[2] > 0, vb[3] > 0 else {
            return CGAffineTransform(scaleX: px, y: px)
        }
        let w = SVGImporter.length(a["width"]).map { $0 * px }
        let h = SVGImporter.length(a["height"]).map { $0 * px }
        let s: CGFloat
        switch (w, h) {
        case let (w?, h?): s = min(w / vb[2], h / vb[3])
        case let (w?, nil): s = w / vb[2]
        case let (nil, h?): s = h / vb[3]
        default: s = px
        }
        return CGAffineTransform(translationX: -vb[0], y: -vb[1])
            .concatenating(CGAffineTransform(scaleX: s, y: s))
    }

    // MARK: Basic shapes

    static func shapePath(_ name: String, _ a: [String: String]) -> CGPath? {
        func len(_ key: String) -> CGFloat { SVGImporter.length(a[key]) ?? 0 }
        switch name {
        case "path":
            guard let d = a["d"] else { return nil }
            return SVGPathParser.parse(d)
        case "rect":
            let w = len("width"), h = len("height")
            guard w > 0, h > 0 else { return nil }
            var rx = SVGImporter.length(a["rx"]), ry = SVGImporter.length(a["ry"])
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cx = min(max(rx ?? 0, 0), w / 2), cy = min(max(ry ?? 0, 0), h / 2)
            let r = CGRect(x: len("x"), y: len("y"), width: w, height: h)
            if cx > 0, cy > 0 {
                return CGPath(roundedRect: r, cornerWidth: cx, cornerHeight: cy, transform: nil)
            }
            return CGPath(rect: r, transform: nil)
        case "circle":
            let r = len("r")
            guard r > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: len("cx") - r, y: len("cy") - r, width: 2 * r, height: 2 * r), transform: nil)
        case "ellipse":
            let rx = len("rx"), ry = len("ry")
            guard rx > 0, ry > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: len("cx") - rx, y: len("cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        case "line":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: len("x1"), y: len("y1")))
            p.addLine(to: CGPoint(x: len("x2"), y: len("y2")))
            return p
        case "polyline", "polygon":
            let n = SVGImporter.numbers(a["points"])
            guard n.count >= 4 else { return nil }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: n[0], y: n[1]))
            var i = 2
            while i + 1 < n.count {
                p.addLine(to: CGPoint(x: n[i], y: n[i + 1]))
                i += 2
            }
            if name == "polygon" { p.closeSubpath() }
            return p
        default:
            return nil
        }
    }
}

// MARK: - Path data (d="…")

enum SVGPathParser {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var s = NumberScanner(d)
        var cmd: Character = " "
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?   // second control point of the last C/S
        var lastQuad: CGPoint?    // control point of the last Q/T
        var hasCurrent = false

        func ensureStarted() {
            if !hasCurrent { path.move(to: cur); start = cur; hasCurrent = true }
        }

        while true {
            if let letter = s.command() {
                cmd = letter
            } else if cmd == " " || s.atEnd {
                break
            }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }

            switch cmd.uppercased() {
            case "M":
                guard let x = s.number(), let y = s.number() else { return path }
                cur = pt(x, y); start = cur
                path.move(to: cur); hasCurrent = true
                lastCubic = nil; lastQuad = nil
                cmd = rel ? "l" : "L" // further pairs are lines
            case "L":
                guard let x = s.number(), let y = s.number() else { return path }
                ensureStarted()
                cur = pt(x, y); path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case "H":
                guard let x = s.number() else { return path }
                ensureStarted()
                cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y); path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case "V":
                guard let y = s.number() else { return path }
                ensureStarted()
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y); path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case "C":
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number() else { return path }
                ensureStarted()
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                cur = end; lastCubic = c2; lastQuad = nil
            case "S":
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return path }
                ensureStarted()
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                cur = end; lastCubic = c2; lastQuad = nil
            case "Q":
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return path }
                ensureStarted()
                let c = pt(x1, y1), end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                cur = end; lastQuad = c; lastCubic = nil
            case "T":
                guard let x = s.number(), let y = s.number() else { return path }
                ensureStarted()
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                cur = end; lastQuad = c; lastCubic = nil
            case "A":
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(),
                      let x = s.number(), let y = s.number() else { return path }
                ensureStarted()
                let end = pt(x, y)
                addArc(path, from: cur, to: end, rx: rx, ry: ry, angle: rot, largeArc: large, sweep: sweep)
                cur = end; lastCubic = nil; lastQuad = nil
            case "Z":
                if hasCurrent { path.closeSubpath() }
                cur = start; hasCurrent = false
                lastCubic = nil; lastQuad = nil
                // Z takes no numbers: the next token must be a command
                if !s.atEnd, !s.nextIsCommand { return path }
                cmd = " "
            default:
                return path
            }
        }
        return path
    }

    /// Elliptical arc as cubic Bézier curves (SVG spec, appendix F.6).
    static func addArc(_ path: CGMutablePath, from p1: CGPoint, to p2: CGPoint,
                       rx rxIn: CGFloat, ry ryIn: CGFloat, angle: CGFloat, largeArc: Bool, sweep: Bool) {
        if p1.distance(to: p2) < 1e-9 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx < 1e-9 || ry < 1e-9 { path.addLine(to: p2); return }
        let phi = angle * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den > 0 ? sqrt(max(0, num / den)) : 0
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry
        let cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p1.x + p2.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p1.y + p2.y) / 2

        func vecAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = vecAngle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = vecAngle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let count = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / CGFloat(count)
        let k = 4.0 / 3.0 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * x * cosP - ry * y * sinP, y: cy + rx * x * sinP + ry * y * cosP)
        }
        for i in 0..<count {
            let a1 = theta1 + CGFloat(i) * step, a2 = a1 + step
            let c1 = map(cos(a1) - k * sin(a1), sin(a1) + k * cos(a1))
            let c2 = map(cos(a2) + k * sin(a2), sin(a2) - k * cos(a2))
            let end = i == count - 1 ? p2 : map(cos(a2), sin(a2))
            path.addCurve(to: end, control1: c1, control2: c2)
        }
    }
}

// MARK: - Tokeniser for numbers and path commands

struct NumberScanner {
    private let bytes: [UInt8]
    private var i = 0

    init(_ s: String) { bytes = Array(s.utf8) }

    var atEnd: Bool {
        mutating get { skipSeparators(); return i >= bytes.count }
    }

    var nextIsCommand: Bool {
        mutating get {
            skipSeparators()
            return i < bytes.count && Self.isCommand(bytes[i])
        }
    }

    private static func isCommand(_ c: UInt8) -> Bool {
        // Letters except e/E (exponent)
        let l = c | 0x20
        return l >= 0x61 && l <= 0x7A && l != 0x65
    }

    private mutating func skipSeparators() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x2C].contains(bytes[i]) { i += 1 }
    }

    mutating func command() -> Character? {
        skipSeparators()
        guard i < bytes.count, Self.isCommand(bytes[i]) else { return nil }
        defer { i += 1 }
        return Character(UnicodeScalar(bytes[i]))
    }

    /// Arc flags may be written without separator: "a5 5 0 01 10 10".
    mutating func flag() -> Bool? {
        skipSeparators()
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case 0x30: i += 1; return false
        case 0x31: i += 1; return true
        default: return nil
        }
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let startIndex = i
        var j = i
        if j < bytes.count, bytes[j] == 0x2B || bytes[j] == 0x2D { j += 1 }
        var digits = false, dot = false
        while j < bytes.count {
            let c = bytes[j]
            if c >= 0x30 && c <= 0x39 { digits = true; j += 1 }
            else if c == 0x2E && !dot { dot = true; j += 1 }
            else { break }
        }
        guard digits else { return nil }
        if j < bytes.count, bytes[j] == 0x65 || bytes[j] == 0x45 {
            var k = j + 1
            if k < bytes.count, bytes[k] == 0x2B || bytes[k] == 0x2D { k += 1 }
            var expDigits = false
            while k < bytes.count, bytes[k] >= 0x30 && bytes[k] <= 0x39 { k += 1; expDigits = true }
            if expDigits { j = k }
        }
        guard let s = String(bytes: bytes[startIndex..<j], encoding: .ascii), let v = Double(s) else { return nil }
        i = j
        return CGFloat(v)
    }
}

extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
