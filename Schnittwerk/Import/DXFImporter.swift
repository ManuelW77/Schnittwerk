// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// DXF reader (ASCII) for cut lines. Supports LINE, CIRCLE, ARC,
// LWPOLYLINE (with bulges), POLYLINE/VERTEX, SPLINE and ELLIPSE.
// Blocks (INSERT) and text are skipped with a note.

import CoreGraphics
import Foundation

enum DXFImporter {
    static func parse(_ data: Data) throws -> ImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable
        }
        if text.hasPrefix("AutoCAD Binary DXF") { throw ImportError.unreadable }
        let pairs = groupPairs(text)
        guard !pairs.isEmpty else { throw ImportError.unreadable }

        let unit = unitScale(pairs)
        let entities = entityList(pairs)
        var lines: [Polyline] = []
        var warnings: [String] = []

        var i = 0
        while i < entities.count {
            let e = entities[i]
            switch e.type {
            case "LINE":
                lines.append(Polyline(points: [e.point(10), e.point(11)], closed: false))
            case "CIRCLE":
                lines.append(arc(center: e.point(10), radius: e.double(40), start: 0, sweep: 2 * .pi, closed: true))
            case "ARC":
                var a1 = e.double(50) * .pi / 180
                var a2 = e.double(51) * .pi / 180
                if a2 <= a1 { a2 += 2 * .pi }
                if a2 - a1 > 2 * .pi { a1 = 0; a2 = 2 * .pi }
                lines.append(arc(center: e.point(10), radius: e.double(40), start: a1, sweep: a2 - a1, closed: false))
            case "LWPOLYLINE":
                let xs = e.all(10), ys = e.all(20)
                let bulges = e.bulgesPerVertex()
                let verts = zip(xs, ys).map { CGPoint(x: $0, y: $1) }
                if let pl = polyline(vertices: verts, bulges: bulges, closed: e.int(70) & 1 == 1) {
                    lines.append(pl)
                }
            case "POLYLINE":
                var verts: [CGPoint] = []
                var bulges: [CGFloat] = []
                var j = i + 1
                while j < entities.count, entities[j].type == "VERTEX" {
                    verts.append(entities[j].point(10))
                    bulges.append(entities[j].double(42))
                    j += 1
                }
                if j < entities.count, entities[j].type == "SEQEND" { j += 1 }
                if let pl = polyline(vertices: verts, bulges: bulges, closed: e.int(70) & 1 == 1) {
                    lines.append(pl)
                }
                i = j
                continue
            case "SPLINE":
                if let pl = spline(e) { lines.append(pl) }
            case "ELLIPSE":
                lines.append(ellipse(e))
            case "INSERT":
                warnings.append(String(localized: "Blocks (INSERT) in the DXF were skipped. Explode them before exporting."))
            case "TEXT", "MTEXT":
                warnings.append(String(localized: "Text in the DXF was skipped. Convert text to lines before exporting."))
            default:
                break
            }
            i += 1
        }

        // DXF: y points up and units vary → mm with y down
        let t = CGAffineTransform(scaleX: unit, y: -unit)
        let result = lines.map { $0.applying(t) }.filter { $0.points.count >= 2 }
        return ImportResult(paths: result, warnings: warnings.uniqued())
    }

    // MARK: - Reading groups

    struct Pair { let code: Int; let value: String }

    static func groupPairs(_ text: String) -> [Pair] {
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [Pair] = []
        out.reserveCapacity(rows.count / 2)
        var i = 0
        while i + 1 < rows.count {
            guard let code = Int(rows[i]) else { i += 1; continue }
            out.append(Pair(code: code, value: rows[i + 1]))
            i += 2
        }
        return out
    }

    /// $INSUNITS in the header → millimetres per drawing unit.
    static func unitScale(_ pairs: [Pair]) -> CGFloat {
        guard let idx = pairs.firstIndex(where: { $0.code == 9 && $0.value == "$INSUNITS" }),
              idx + 1 < pairs.count, let u = Int(pairs[idx + 1].value) else { return 1 }
        switch u {
        case 1: return 25.4        // inch
        case 2: return 304.8       // foot
        case 4: return 1           // mm
        case 5: return 10          // cm
        case 6: return 1000        // m
        default: return 1          // unitless: assume mm
        }
    }

    struct Entity {
        let type: String
        let pairs: [Pair]

        func values(_ code: Int) -> [String] { pairs.filter { $0.code == code }.map(\.value) }
        func all(_ code: Int) -> [CGFloat] { values(code).compactMap { Double($0) }.map { CGFloat($0) } }
        func double(_ code: Int) -> CGFloat { all(code).first ?? 0 }
        func int(_ code: Int) -> Int { values(code).first.flatMap { Int($0) } ?? 0 }
        func point(_ code: Int) -> CGPoint { CGPoint(x: double(code), y: double(code + 10)) }

        /// Code 42 belongs to the vertex before it; missing values are 0.
        func bulgesPerVertex() -> [CGFloat] {
            var result: [CGFloat] = []
            for p in pairs {
                if p.code == 10 { result.append(0) }
                if p.code == 42, !result.isEmpty { result[result.count - 1] = CGFloat(Double(p.value) ?? 0) }
            }
            return result
        }
    }

    /// Entities from the ENTITIES section (or the whole file if there is none).
    static func entityList(_ pairs: [Pair]) -> [Entity] {
        var start = 0, end = pairs.count
        if let s = pairs.indices.first(where: { pairs[$0].code == 2 && pairs[$0].value == "ENTITIES" }) {
            start = s + 1
            if let e = pairs[start...].firstIndex(where: { $0.code == 0 && $0.value == "ENDSEC" }) { end = e }
        }
        var entities: [Entity] = []
        var currentType: String?
        var current: [Pair] = []
        for p in pairs[start..<end] {
            if p.code == 0 {
                if let t = currentType { entities.append(Entity(type: t, pairs: current)) }
                currentType = p.value
                current = []
            } else {
                current.append(p)
            }
        }
        if let t = currentType { entities.append(Entity(type: t, pairs: current)) }
        return entities
    }

    // MARK: - Geometry

    static func arc(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, closed: Bool) -> Polyline {
        let n = segmentCount(radius: radius, sweep: sweep)
        var pts: [CGPoint] = []
        let last = closed ? n - 1 : n
        for i in 0...last {
            let a = start + sweep * CGFloat(i) / CGFloat(n)
            pts.append(CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
        }
        return Polyline(points: pts, closed: closed)
    }

    /// Enough segments for 0.02 mm deviation (radius in drawing units ≈ mm).
    static func segmentCount(radius: CGFloat, sweep: CGFloat) -> Int {
        let r = max(abs(radius), 0.001)
        let maxStep = 2 * acos(max(-1, min(1, 1 - ShapeImporter.tolerance / r)))
        let n = Int(ceil(abs(sweep) / max(maxStep, 0.01)))
        return min(max(n, 8), 2000)
    }

    static func polyline(vertices: [CGPoint], bulges: [CGFloat], closed: Bool) -> Polyline? {
        guard vertices.count >= 2 else { return nil }
        var pts: [CGPoint] = [vertices[0]]
        let segmentCount = closed ? vertices.count : vertices.count - 1
        for k in 0..<segmentCount {
            let p1 = vertices[k], p2 = vertices[(k + 1) % vertices.count]
            let b = k < bulges.count ? bulges[k] : 0
            if abs(b) < 1e-9 {
                pts.append(p2)
            } else {
                pts.append(contentsOf: bulgeArc(p1, p2, b).dropFirst())
            }
        }
        if closed, let f = pts.first, let l = pts.last, f.distance(to: l) < 1e-9 { pts.removeLast() }
        return Polyline(points: pts, closed: closed)
    }

    /// Arc between two polyline points. The bulge is tan(angle / 4);
    /// positive means counter-clockwise (DXF, y up).
    static func bulgeArc(_ p1: CGPoint, _ p2: CGPoint, _ bulge: CGFloat) -> [CGPoint] {
        let theta = 4 * atan(bulge)
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let d = hypot(dx, dy)
        guard d > 1e-12 else { return [p1, p2] }
        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        let h = d / (2 * tan(theta / 2))           // signed distance midpoint → centre
        let nx = -dy / d, ny = dx / d               // left normal of the chord
        let c = CGPoint(x: mid.x + nx * h, y: mid.y + ny * h)
        let r = hypot(p1.x - c.x, p1.y - c.y)
        let a1 = atan2(p1.y - c.y, p1.x - c.x)
        let n = segmentCount(radius: r, sweep: theta)
        var pts: [CGPoint] = []
        for i in 0...n {
            let a = a1 + theta * CGFloat(i) / CGFloat(n)
            pts.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        }
        pts[pts.count - 1] = p2
        return pts
    }

    static func ellipse(_ e: Entity) -> Polyline {
        let c = e.point(10)
        let major = e.point(11)
        let ratio = e.double(40)
        var t1 = e.all(41).first ?? 0
        var t2 = e.all(42).first ?? 2 * .pi
        if t2 <= t1 { t2 += 2 * .pi }
        let full = abs((t2 - t1) - 2 * .pi) < 1e-6
        if full { t1 = 0; t2 = 2 * .pi }
        let minor = CGPoint(x: -major.y * ratio, y: major.x * ratio)
        let radius = hypot(major.x, major.y)
        let n = segmentCount(radius: radius, sweep: t2 - t1)
        var pts: [CGPoint] = []
        let last = full ? n - 1 : n
        for i in 0...last {
            let t = t1 + (t2 - t1) * CGFloat(i) / CGFloat(n)
            pts.append(CGPoint(x: c.x + major.x * cos(t) + minor.x * sin(t),
                               y: c.y + major.y * cos(t) + minor.y * sin(t)))
        }
        return Polyline(points: pts, closed: full)
    }

    /// B-spline via de Boor. Without control points, the fit points are used.
    static func spline(_ e: Entity) -> Polyline? {
        let closed = e.int(70) & 1 == 1
        let ctrl = zip(e.all(10), e.all(20)).map { CGPoint(x: $0, y: $1) }
        let degree = max(1, e.int(71))
        let knots = e.all(40)
        let weightsRaw = e.all(41)
        guard ctrl.count > degree, knots.count == ctrl.count + degree + 1 else {
            let fit = zip(e.all(11), e.all(21)).map { CGPoint(x: $0, y: $1) }
            return fit.count >= 2 ? Polyline(points: fit, closed: closed) : nil
        }
        let weights = weightsRaw.count == ctrl.count ? weightsRaw : Array(repeating: 1, count: ctrl.count)
        let lo = knots[degree], hi = knots[knots.count - degree - 1]
        guard hi > lo else { return nil }
        let samples = max(16, (ctrl.count - degree) * 24)
        var pts: [CGPoint] = []
        for i in 0...samples {
            let u = lo + (hi - lo) * CGFloat(i) / CGFloat(samples)
            pts.append(deBoor(u: min(u, hi - 1e-12 * max(1, abs(hi))), degree: degree, knots: knots, ctrl: ctrl, weights: weights))
        }
        pts[pts.count - 1] = deBoor(u: hi, degree: degree, knots: knots, ctrl: ctrl, weights: weights, atEnd: true)
        return Polyline(points: pts, closed: closed)
    }

    static func deBoor(u: CGFloat, degree p: Int, knots: [CGFloat], ctrl: [CGPoint], weights: [CGFloat], atEnd: Bool = false) -> CGPoint {
        if atEnd {
            // Clamped spline: the curve ends at the last control point
            let last = knots.count - p - 1
            if knots[last...].allSatisfy({ abs($0 - knots[last]) < 1e-12 }) { return ctrl[ctrl.count - 1] }
        }
        var k = p
        while k < ctrl.count - 1, u >= knots[k + 1] { k += 1 }
        // Homogeneous coordinates for rational splines
        var d: [(x: CGFloat, y: CGFloat, w: CGFloat)] = (0...p).map { j in
            let idx = j + k - p
            let w = weights[idx]
            return (ctrl[idx].x * w, ctrl[idx].y * w, w)
        }
        if p >= 1 {
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let i = j + k - p
                    let denom = knots[i + p - r + 1] - knots[i]
                    let a = denom == 0 ? 0 : (u - knots[i]) / denom
                    d[j] = ((1 - a) * d[j - 1].x + a * d[j].x,
                            (1 - a) * d[j - 1].y + a * d[j].y,
                            (1 - a) * d[j - 1].w + a * d[j].w)
                }
            }
        }
        let w = d[p].w == 0 ? 1 : d[p].w
        return CGPoint(x: d[p].x / w, y: d[p].y / w)
    }
}
