// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Editing single points of an object, and the knife and eraser tools.
// An edited text or basic shape becomes plain lines (its settings would
// otherwise rebuild the old geometry).

import CoreGraphics
import Foundation

/// One point of an object: line number and point number.
struct PointRef: Hashable {
    var path: Int
    var index: Int
}

extension CutShape {
    /// Changes the geometry in object coordinates without moving the object.
    mutating func editLocalPaths(_ edit: (inout [Polyline]) -> Void) {
        var p = paths
        edit(&p)
        p = p.filter { !$0.points.isEmpty }
        text = nil
        shapeSpec = nil
        setLocalPaths(p)
    }

    /// Points of the object on the mat, line by line.
    var matPoints: [[CGPoint]] {
        let t = transform
        return paths.map { $0.points.map { $0.applying(t) } }
    }

    /// Mat point → object coordinates.
    func local(_ matPoint: CGPoint) -> CGPoint { matPoint.applying(transform.inverted()) }

    /// Nearest point within `radius` mm (mat).
    func point(near p: CGPoint, radius: CGFloat) -> PointRef? {
        var best: PointRef?
        var bestD = radius
        for (i, line) in matPoints.enumerated() {
            for (j, q) in line.enumerated() where q.distance(to: p) <= bestD {
                bestD = q.distance(to: p)
                best = PointRef(path: i, index: j)
            }
        }
        return best
    }

    /// Nearest line segment within `radius` mm: the point is inserted
    /// after `index` on line `path`; returns the spot on the segment.
    func segment(near p: CGPoint, radius: CGFloat) -> (PointRef, CGPoint)? {
        var best: (PointRef, CGPoint)?
        var bestD = radius
        for (i, line) in matPoints.enumerated() where line.count >= 2 {
            let closed = paths[i].closed
            let count = closed ? line.count : line.count - 1
            for j in 0..<count {
                let a = line[j], b = line[(j + 1) % line.count]
                let q = Self.closest(on: a, b, to: p)
                if q.distance(to: p) <= bestD {
                    bestD = q.distance(to: p)
                    best = (PointRef(path: i, index: j), q)
                }
            }
        }
        return best
    }

    static func closest(on a: CGPoint, _ b: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-12 else { return a }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    }

    mutating func movePoint(_ ref: PointRef, toMat p: CGPoint) {
        let l = local(p)
        editLocalPaths { paths in
            guard paths.indices.contains(ref.path), paths[ref.path].points.indices.contains(ref.index) else { return }
            paths[ref.path].points[ref.index] = l
        }
    }

    /// Removes a point. A line that gets too short disappears.
    mutating func deletePoint(_ ref: PointRef) {
        editLocalPaths { paths in
            guard paths.indices.contains(ref.path), paths[ref.path].points.indices.contains(ref.index) else { return }
            paths[ref.path].points.remove(at: ref.index)
            let line = paths[ref.path]
            if line.points.count < 2 || (line.closed && line.points.count < 3) { paths.remove(at: ref.path) }
        }
    }

    mutating func insertPoint(after ref: PointRef, atMat p: CGPoint) {
        let l = local(p)
        editLocalPaths { paths in
            guard paths.indices.contains(ref.path) else { return }
            paths[ref.path].points.insert(l, at: min(ref.index + 1, paths[ref.path].points.count))
        }
    }

    /// Opens the line at the point: a closed line becomes an open one that
    /// starts and ends there; an open line becomes two lines.
    mutating func splitLine(at ref: PointRef) {
        editLocalPaths { paths in
            guard paths.indices.contains(ref.path) else { return }
            let line = paths[ref.path]
            let pts = line.points
            guard pts.indices.contains(ref.index) else { return }
            if line.closed {
                let rotated = Array(pts[ref.index...] + pts[..<ref.index]) + [pts[ref.index]]
                paths[ref.path] = Polyline(points: rotated, closed: false)
            } else {
                guard ref.index > 0, ref.index < pts.count - 1 else { return }
                paths[ref.path] = Polyline(points: Array(pts[...ref.index]), closed: false)
                paths.insert(Polyline(points: Array(pts[ref.index...]), closed: false), at: ref.path + 1)
            }
        }
    }
}

extension PathOps {
    /// Area of `shape` with a band along `stroke` removed, split into
    /// separate outlines. Open lines of the shape are kept unchanged.
    static func cutAway(_ shape: CutShape, band: CGPath) -> [[Polyline]] {
        let area = PathOps.area(of: shape.matPaths)
        let rest = lines(of: area.subtracting(band))
        return outlines(rest)
    }

    static func band(along points: [CGPoint], width: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        return p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }
}

extension CutDocument {
    /// Objects the knife or eraser works on: the selection if there is one,
    /// else every unlocked object that the stroke touches.
    private func targets(for stroke: [CGPoint], width: CGFloat, selection: Set<UUID>) -> [CutShape] {
        let band = PathOps.band(along: stroke, width: max(width, 0.5)).boundingBoxOfPath
        return data.shapes.filter { s in
            !s.isLocked && s.matBounds.intersects(band) && (selection.isEmpty || selection.contains(s.id))
                && s.matPaths.contains { $0.closed }
        }
    }

    /// Replaces objects by the pieces left after removing the band.
    private func replace(_ shapes: [CutShape], band: CGPath, split: Bool, action: String,
                         undoManager: UndoManager?) -> Set<UUID> {
        var replacements: [UUID: [CutShape]] = [:]
        for s in shapes {
            let pieces = PathOps.cutAway(s, band: band)
            let open = s.matPaths.filter { !$0.closed }
            // Nothing was cut: leave the object alone
            if pieceAreaUnchanged(s, band) { continue }
            func make(_ lines: [Polyline], _ n: Int?) -> CutShape {
                var r = CutShape(name: n.map { "\(s.name) \($0)" } ?? s.name, matPaths: lines)
                r.cutEnabled = s.cutEnabled
                r.toolSlot = s.toolSlot
                r.colorHex = s.colorHex
                r.groupID = s.groupID
                return r
            }
            if split, pieces.count > 1 {
                replacements[s.id] = pieces.enumerated().map { make($0.element, $0.offset + 1) }
                    + (open.isEmpty ? [] : [make(open, nil)])
            } else {
                let all = pieces.flatMap { $0 } + open
                replacements[s.id] = all.isEmpty ? [] : [make(all, nil)]
            }
        }
        guard !replacements.isEmpty else { return [] }
        update(action, undoManager: undoManager) { data in
            var result: [CutShape] = []
            for s in data.shapes {
                if let r = replacements[s.id] { result += r } else { result.append(s) }
            }
            data.shapes = result
        }
        return Set(replacements.values.flatMap { $0.map(\.id) })
    }

    /// True if the band does not touch the filled area of the object.
    private func pieceAreaUnchanged(_ s: CutShape, _ band: CGPath) -> Bool {
        PathOps.area(of: s.matPaths).intersection(band).isEmpty
    }

    /// Knife: cuts the objects along the straight line a → b into pieces.
    @discardableResult
    func knife(from a: CGPoint, to b: CGPoint, selection: Set<UUID>, undoManager: UndoManager?) -> Set<UUID> {
        guard a.distance(to: b) >= 0.5 else { return [] }
        let width: CGFloat = 0.05
        let shapes = targets(for: [a, b], width: width, selection: selection)
        return replace(shapes, band: PathOps.band(along: [a, b], width: width), split: true,
                       action: String(localized: "Knife"), undoManager: undoManager)
    }

    /// Eraser: removes everything within `radius` mm of the stroke.
    @discardableResult
    func erase(along stroke: [CGPoint], radius: CGFloat, selection: Set<UUID>, undoManager: UndoManager?) -> Set<UUID> {
        guard !stroke.isEmpty, radius > 0 else { return [] }
        let points = stroke.count == 1 ? [stroke[0], CGPoint(x: stroke[0].x + 0.01, y: stroke[0].y)] : stroke
        let shapes = targets(for: points, width: radius * 2, selection: selection)
        return replace(shapes, band: PathOps.band(along: points, width: radius * 2), split: false,
                       action: String(localized: "Erase"), undoManager: undoManager)
    }
}
