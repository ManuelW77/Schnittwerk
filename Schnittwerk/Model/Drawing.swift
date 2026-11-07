// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Drawing on the mat: freehand lines and curves made of anchor points
// (pen tool). Both end up as plain cut lines.

import CoreGraphics
import Foundation

/// What a click on the mat does.
enum DrawingTool: String, CaseIterable, Identifiable {
    case select, points, text, freehand, curve, knife, eraser
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: String(localized: "Select")
        case .text: String(localized: "Text")
        case .freehand: String(localized: "Freehand")
        case .curve: String(localized: "Curve")
        case .points: String(localized: "Edit points")
        case .knife: String(localized: "Knife")
        case .eraser: String(localized: "Eraser")
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .freehand: "scribble"
        case .curve: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .points: "point.topleft.down.to.point.bottomright.curvepath"
        case .knife: "line.diagonal"
        case .eraser: "eraser"
        }
    }

    /// Key on the mat that picks the tool.
    var key: Character {
        switch self {
        case .select: "v"
        case .text: "t"
        case .freehand: "f"
        case .curve: "p"
        case .points: "a"
        case .knife: "k"
        case .eraser: "e"
        }
    }

    var help: String {
        switch self {
        case .select: String(localized: "Select and move objects (V)")
        case .text: String(localized: "Click on the mat to place text (T)")
        case .freehand: String(localized: "Draw a freehand line (F)")
        case .curve: String(localized: "Draw curves: click for corners, drag for round points. Return or double-click ends, click the first point to close (P)")
        case .points: String(localized: "Edit the points of one object: drag a point, double-click a point to delete it, double-click a line to add a point, right-click a point to split the line there (A)")
        case .knife: String(localized: "Drag a straight line across objects to cut them into pieces (K)")
        case .eraser: String(localized: "Drag over objects to erase parts of them (E)")
        }
    }
}

enum FreehandBuilder {
    /// Smooth cut line through the drawn points (mat mm).
    /// `tolerance` is how far the line may leave the drawn points.
    /// The line is closed if it ends within `closeDistance` of its start.
    static func polyline(from raw: [CGPoint], tolerance: CGFloat, closeDistance: CGFloat) -> Polyline? {
        let points = raw.filter { $0.x.isFinite && $0.y.isFinite }
        guard points.count >= 2, Polyline(points: points, closed: false).length >= 1 else { return nil }
        var simple = simplify(points, tolerance: max(tolerance, 0.01))
        var closed = false
        if simple.count >= 3, let f = simple.first, let l = simple.last, f.distance(to: l) <= closeDistance {
            closed = true
            simple.removeLast()
            if simple.count < 3 { return nil }
        }
        let path = smoothPath(through: simple, closed: closed)
        let lines = path.polylines(tolerance: ShapeImporter.tolerance)
        guard var line = lines.first else { return nil }
        line.closed = closed && line.points.count >= 3
        return line
    }

    /// Ramer–Douglas–Peucker: drops points that lie within `tolerance`
    /// of the line between their neighbours.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var maxDist: CGFloat = 0, index = a
            for i in (a + 1)..<b {
                let d = distance(points[i], toSegment: points[a], points[b])
                if d > maxDist { maxDist = d; index = i }
            }
            if maxDist > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Catmull–Rom spline through the points, as Bézier curves.
    static func smoothPath(through p: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = p.first else { return path }
        path.move(to: first)
        let n = p.count
        guard n > 1 else { return path }
        func at(_ i: Int) -> CGPoint {
            closed ? p[(i % n + n) % n] : p[min(max(i, 0), n - 1)]
        }
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-12 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

/// A curve under construction with the pen tool.
struct PenCurve: Equatable {
    struct Anchor: Equatable {
        var point: CGPoint
        /// Outgoing handle, relative to the point. The incoming handle is
        /// the mirror image. Zero means a sharp corner.
        var handle: CGPoint = .zero
    }

    var anchors: [Anchor] = []

    /// Bézier path through the anchors (mat mm).
    func path(closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = anchors.first else { return path }
        path.move(to: first.point)
        var list = anchors
        if closed, anchors.count >= 2 { list.append(first) }
        for i in 1..<max(list.count, 1) {
            let a = list[i - 1], b = list[i]
            let c1 = CGPoint(x: a.point.x + a.handle.x, y: a.point.y + a.handle.y)
            let c2 = CGPoint(x: b.point.x - b.handle.x, y: b.point.y - b.handle.y)
            if a.handle == .zero && b.handle == .zero {
                path.addLine(to: b.point)
            } else {
                path.addCurve(to: b.point, control1: c1, control2: c2)
            }
        }
        if closed { path.closeSubpath() }
        return path
    }

    /// The finished cut line, nil if there is not enough to cut.
    func polyline(closed: Bool) -> Polyline? {
        guard anchors.count >= 2 else { return nil }
        let isClosed = closed && (anchors.count >= 3 || anchors.contains { $0.handle != .zero })
        let lines = path(closed: isClosed).polylines(tolerance: ShapeImporter.tolerance)
        guard let line = lines.first, line.length >= 0.5 else { return nil }
        return line
    }
}

extension CutShape {
    /// New object from one drawn line (mat coordinates).
    static func drawn(_ line: Polyline, name: String) -> CutShape {
        CutShape(name: name, matPaths: [line])
    }
}
