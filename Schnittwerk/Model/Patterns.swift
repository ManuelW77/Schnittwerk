// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Fill patterns and stippling, as in Silhouette Studio's "Sketch and
// stipple" and embossing panels. A fill draws lines inside an object
// (for the pen or the embossing tool); stippling places small dots
// along the outline or inside it (for the punch tool or a pen).

import CoreGraphics
import Foundation

enum FillPattern: String, CaseIterable, Identifiable {
    case lines, crossHatch, concentric
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lines: String(localized: "Lines")
        case .crossHatch: String(localized: "Cross-hatch")
        case .concentric: String(localized: "Concentric")
        }
    }

    var systemImage: String {
        switch self {
        case .lines: "line.3.horizontal"
        case .crossHatch: "number"
        case .concentric: "circle.circle"
        }
    }
}

enum StippleMode: String, CaseIterable, Identifiable {
    /// Dots along the outline.
    case outline
    /// Dots in a grid inside the object.
    case fill
    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: String(localized: "Along the outline")
        case .fill: String(localized: "Fill the area")
        }
    }
}

enum Patterns {
    /// Radius of one stipple dot on the mat (mm).
    static let dotRadius: CGFloat = 0.3
    static let maxLines = 4000
    static let maxDots = 20000

    /// Straight lines inside the closed lines (even-odd), `spacing` mm apart,
    /// turned by `angle` degrees. Neighbouring lines run in turns, so the
    /// tool travels little.
    static func hatch(_ lines: [Polyline], spacing: CGFloat, angle: Double) -> [Polyline] {
        let closed = lines.filter { $0.closed && $0.points.count >= 3 }
        guard spacing >= 0.2, !closed.isEmpty else { return [] }
        let a = angle * .pi / 180
        // Turn the shape so the lines are horizontal, then turn back
        let toFlat = CGAffineTransform(rotationAngle: -a)
        let back = CGAffineTransform(rotationAngle: a)
        let flat = closed.map { $0.applying(toFlat) }
        let box = flat.bounds
        guard !box.isNull else { return [] }
        var result: [Polyline] = []
        var y = box.minY + spacing / 2
        var row = 0
        while y < box.maxY, result.count < maxLines {
            var xs: [CGFloat] = []
            for line in flat {
                let pts = line.points + [line.points[0]]
                for (p, q) in zip(pts, pts.dropFirst()) where (p.y <= y) != (q.y <= y) {
                    xs.append(p.x + (y - p.y) / (q.y - p.y) * (q.x - p.x))
                }
            }
            xs.sort()
            var segments: [Polyline] = []
            var i = 0
            while i + 1 < xs.count {
                if xs[i + 1] - xs[i] > 0.05 {
                    segments.append(Polyline(points: [CGPoint(x: xs[i], y: y), CGPoint(x: xs[i + 1], y: y)], closed: false))
                }
                i += 2
            }
            if row % 2 == 1 {
                segments = segments.reversed().map { Polyline(points: $0.points.reversed(), closed: false) }
            }
            result += segments
            y += spacing
            row += 1
        }
        return result.map { $0.applying(back) }
    }

    /// Rings inside the object, `spacing` mm apart.
    static func concentric(_ shapes: [CutShape], spacing: CGFloat) -> [Polyline] {
        guard spacing >= 0.2 else { return [] }
        var result: [Polyline] = []
        var d = spacing
        while result.count < maxLines {
            let ring = PathOps.offset(shapes, by: -d, roundCorners: true)
            if ring.isEmpty { break }
            result += ring
            d += spacing
        }
        return result
    }

    static func fill(_ shapes: [CutShape], pattern: FillPattern, spacing: CGFloat, angle: Double) -> [Polyline] {
        let lines = shapes.flatMap(\.matPaths)
        switch pattern {
        case .lines: return hatch(lines, spacing: spacing, angle: angle)
        case .crossHatch: return hatch(lines, spacing: spacing, angle: angle) + hatch(lines, spacing: spacing, angle: angle + 90)
        case .concentric: return concentric(shapes, spacing: spacing)
        }
    }

    /// A small round dot at `p`.
    static func dot(at p: CGPoint) -> Polyline {
        let r = dotRadius
        let pts = (0..<8).map { i -> CGPoint in
            let a = CGFloat(i) / 8 * 2 * .pi
            return CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
        }
        return Polyline(points: pts, closed: true)
    }

    /// Dot positions along or inside the objects.
    static func stipplePoints(_ shapes: [CutShape], mode: StippleMode, spacing: CGFloat) -> [CGPoint] {
        guard spacing >= 0.5 else { return [] }
        let lines = shapes.flatMap(\.matPaths)
        var points: [CGPoint] = []
        switch mode {
        case .outline:
            for line in lines where line.points.count >= 2 {
                let pts = line.closed ? line.points + [line.points[0]] : line.points
                var carry: CGFloat = 0 // distance since the last dot
                points.append(pts[0])
                for (a, b) in zip(pts, pts.dropFirst()) {
                    let d = a.distance(to: b)
                    guard d > 1e-9 else { continue }
                    var t = spacing - carry
                    while t <= d {
                        points.append(CGPoint(x: a.x + (b.x - a.x) * t / d, y: a.y + (b.y - a.y) * t / d))
                        t += spacing
                        if points.count >= maxDots { return points }
                    }
                    carry = d - (t - spacing)
                }
                // A closed line ends where it started: no second dot there
                if line.closed, let last = points.last, last.distance(to: pts[0]) < spacing / 2 { points.removeLast() }
            }
        case .fill:
            let area = PathOps.area(of: lines)
            let box = area.boundingBoxOfPath
            guard !box.isNull else { return [] }
            var y = box.minY + spacing / 2
            var row = 0
            while y < box.maxY {
                // Every other row is shifted by half a step (honeycomb)
                var x = box.minX + spacing / 2 + (row % 2 == 1 ? spacing / 2 : 0)
                var rowPoints: [CGPoint] = []
                while x < box.maxX {
                    let p = CGPoint(x: x, y: y)
                    if area.contains(p, using: .evenOdd) { rowPoints.append(p) }
                    x += spacing
                }
                points += row % 2 == 1 ? rowPoints.reversed() : rowPoints
                if points.count >= maxDots { return Array(points.prefix(maxDots)) }
                y += spacing * 0.866
                row += 1
            }
        }
        return points
    }

    static func stipple(_ shapes: [CutShape], mode: StippleMode, spacing: CGFloat) -> [Polyline] {
        stipplePoints(shapes, mode: mode, spacing: spacing).map(dot(at:))
    }
}

extension CutDocument {
    /// Adds a fill pattern in front of the objects. Returns its id, or nil
    /// if the pattern would be empty (open lines have no inside).
    @discardableResult
    func addFill(ids: Set<UUID>, pattern: FillPattern, spacing: CGFloat, angle: Double,
                 undoManager: UndoManager?) -> UUID? {
        let selected = data.shapes.filter { ids.contains($0.id) }
        guard let first = selected.first else { return nil }
        let lines = Patterns.fill(selected, pattern: pattern, spacing: spacing, angle: angle)
        guard !lines.isEmpty else { return nil }
        var result = CutShape(name: String(localized: "\(first.name) fill"), matPaths: lines)
        result.toolSlot = first.toolSlot
        update(String(localized: "Add fill"), undoManager: undoManager) { $0.shapes.append(result) }
        return result.id
    }

    /// Adds dots along or inside the objects (one object). With `replace`,
    /// the objects themselves are removed, so only the dots stay.
    @discardableResult
    func addStipple(ids: Set<UUID>, mode: StippleMode, spacing: CGFloat, replace: Bool,
                    undoManager: UndoManager?) -> UUID? {
        let selected = data.shapes.filter { ids.contains($0.id) }
        guard let first = selected.first else { return nil }
        let dots = Patterns.stipple(selected, mode: mode, spacing: spacing)
        guard !dots.isEmpty else { return nil }
        var result = CutShape(name: String(localized: "\(first.name) stipple"), matPaths: dots)
        result.toolSlot = first.toolSlot
        let removable = replace ? data.unlocked(ids) : []
        update(String(localized: "Stipple"), undoManager: undoManager) { data in
            data.shapes.removeAll { removable.contains($0.id) }
            data.shapes.append(result)
        }
        return result.id
    }
}
