// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Weeding lines: a box around the motif and lines through the free
// space, so the waste vinyl comes off in small pieces. The lines keep
// a distance to the motif and never cut into it.

import CoreGraphics
import Foundation

enum Weeding {
    /// Box at `margin` mm around the objects, plus `horizontal` and
    /// `vertical` lines evenly spread inside it. Lines stop half the
    /// margin before the motif, so they also reach in from the box.
    static func lines(around shapes: [CutShape], margin: CGFloat, horizontal: Int, vertical: Int) -> [Polyline] {
        let box = shapes.reduce(CGRect.null) { $0.union($1.matBounds) }
        guard !box.isNull, margin >= 0 else { return [] }
        let frame = box.insetBy(dx: -margin, dy: -margin)
        var result = [Polyline(points: [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                                        CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)],
                               closed: true)]
        // Keep-out area: the motif, grown by the margin
        var keepOut = PathOps.offset(shapes, by: max(margin / 2, 0.5), roundCorners: true)
        if keepOut.isEmpty { keepOut = shapes.flatMap(\.matPaths).filter(\.closed) }

        let keepOutArea = PathOps.area(of: keepOut)

        /// The parts of the line from `p` to `q` that stay outside the keep-out area.
        func outside(_ p: CGPoint, _ q: CGPoint) -> [Polyline] {
            let len = p.distance(to: q)
            guard len > 0.5 else { return [] }
            // Break points: where the line crosses an edge of the keep-out area
            var ts: [CGFloat] = [0, 1]
            for line in keepOut {
                let pts = line.points + [line.points[0]]
                for (a, b) in zip(pts, pts.dropFirst()) {
                    if let t = Weeding.intersection(p, q, a, b) { ts.append(t) }
                }
            }
            ts.sort()
            var out: [Polyline] = []
            var runStart: CGFloat?
            func at(_ t: CGFloat) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
            for (t0, t1) in zip(ts, ts.dropFirst()) where t1 - t0 > 1e-6 {
                let free = !keepOutArea.contains(at((t0 + t1) / 2), using: .evenOdd)
                if free, runStart == nil { runStart = t0 }
                if !free, let s0 = runStart {
                    out.append(Polyline(points: [at(s0), at(t0)], closed: false))
                    runStart = nil
                }
            }
            if let s0 = runStart { out.append(Polyline(points: [at(s0), q], closed: false)) }
            return out.filter { $0.length > 0.5 }
        }

        if horizontal > 0 {
            for n in 1...horizontal {
                let y = frame.minY + frame.height * CGFloat(n) / CGFloat(horizontal + 1)
                result += outside(CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y))
            }
        }
        if vertical > 0 {
            for n in 1...vertical {
                let x = frame.minX + frame.width * CGFloat(n) / CGFloat(vertical + 1)
                result += outside(CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.maxY))
            }
        }
        return result
    }

    /// Where segment p→q crosses segment a→b, as a fraction of p→q.
    static func intersection(_ p: CGPoint, _ q: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat? {
        let r = CGPoint(x: q.x - p.x, y: q.y - p.y), s = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-12 else { return nil }
        let t = ((a.x - p.x) * s.y - (a.y - p.y) * s.x) / denom
        let u = ((a.x - p.x) * r.y - (a.y - p.y) * r.x) / denom
        return (0...1).contains(t) && (0...1).contains(u) ? t : nil
    }
}

extension CutDocument {
    /// Adds weeding lines around the objects. Returns the new object's id.
    @discardableResult
    func addWeedingLines(ids: Set<UUID>, margin: CGFloat, horizontal: Int, vertical: Int,
                         undoManager: UndoManager?) -> UUID? {
        let selected = data.shapes.filter { ids.contains($0.id) }
        guard let first = selected.first else { return nil }
        let lines = Weeding.lines(around: selected, margin: margin, horizontal: horizontal, vertical: vertical)
        guard !lines.isEmpty else { return nil }
        var result = CutShape(name: String(localized: "Weeding lines"), matPaths: lines)
        result.toolSlot = first.toolSlot
        update(String(localized: "Add weeding lines"), undoManager: undoManager) { $0.shapes.append(result) }
        return result.id
    }
}
