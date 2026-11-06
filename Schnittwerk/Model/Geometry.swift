// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Basic geometry: polylines in millimetres, y axis pointing down
// (same orientation as the cutting mat and the plotter).

import CoreGraphics
import Foundation

/// One continuous cut line. All coordinates are in millimetres.
struct Polyline: Codable, Equatable, Hashable {
    var points: [CGPoint]
    var closed: Bool

    init(points: [CGPoint], closed: Bool) {
        self.points = points
        self.closed = closed
    }

    var bounds: CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func applying(_ t: CGAffineTransform) -> Polyline {
        Polyline(points: points.map { $0.applying(t) }, closed: closed)
    }

    /// Length of the line in millimetres.
    var length: CGFloat {
        guard points.count > 1 else { return 0 }
        var sum: CGFloat = 0
        for i in 1..<points.count { sum += points[i - 1].distance(to: points[i]) }
        if closed, let f = points.first, let l = points.last { sum += l.distance(to: f) }
        return sum
    }
}

extension Array where Element == Polyline {
    var bounds: CGRect {
        reduce(CGRect.null) { $0.union($1.bounds) }
    }

    func applying(_ t: CGAffineTransform) -> [Polyline] {
        map { $0.applying(t) }
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

// MARK: - Flattening CGPath into polylines

extension CGPath {
    /// Converts the path into polylines. `tolerance` is the maximum
    /// deviation from the real curve, in the units of the path.
    func polylines(tolerance: CGFloat = 0.02) -> [Polyline] {
        let flattener = PathFlattener(tolerance: tolerance)
        applyWithBlock { element in
            flattener.handle(element.pointee)
        }
        flattener.finish(closed: false)
        return flattener.result
    }
}

private final class PathFlattener {
    let tolerance: CGFloat
    var result: [Polyline] = []
    var current: [CGPoint] = []
    var start = CGPoint.zero
    var last = CGPoint.zero

    init(tolerance: CGFloat) { self.tolerance = max(tolerance, 0.001) }

    func handle(_ e: CGPathElement) {
        let p = e.points
        switch e.type {
        case .moveToPoint:
            finish(closed: false)
            guard p[0].x.isFinite, p[0].y.isFinite else { current = []; return }
            start = p[0]; last = p[0]; current = [p[0]]
        case .addLineToPoint:
            append(p[0])
        case .addQuadCurveToPoint:
            let c = p[0], end = p[1]
            let d = hypot(last.x - 2 * c.x + end.x, last.y - 2 * c.y + end.y)
            let n = segments(maxSecondDerivative: 2 * d)
            let p0 = last
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n), mt = 1 - t
                append(CGPoint(x: mt * mt * p0.x + 2 * mt * t * c.x + t * t * end.x,
                               y: mt * mt * p0.y + 2 * mt * t * c.y + t * t * end.y))
            }
        case .addCurveToPoint:
            let c1 = p[0], c2 = p[1], end = p[2], p0 = last
            let d1 = hypot(p0.x - 2 * c1.x + c2.x, p0.y - 2 * c1.y + c2.y)
            let d2 = hypot(c1.x - 2 * c2.x + end.x, c1.y - 2 * c2.y + end.y)
            let n = segments(maxSecondDerivative: 6 * max(d1, d2))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n), mt = 1 - t
                let a = mt * mt * mt, b = 3 * mt * mt * t, cc = 3 * mt * t * t, dd = t * t * t
                append(CGPoint(x: a * p0.x + b * c1.x + cc * c2.x + dd * end.x,
                               y: a * p0.y + b * c1.y + cc * c2.y + dd * end.y))
            }
        case .closeSubpath:
            finish(closed: true)
            last = start
        @unknown default:
            break
        }
    }

    /// Number of straight pieces so that the chord error stays below the
    /// tolerance: error ≤ M / (8 n²), M = largest second derivative.
    private func segments(maxSecondDerivative m: CGFloat) -> Int {
        let q = sqrt(m / (8 * tolerance))
        guard q.isFinite else { return 1 }
        return Swift.min(Swift.max(Int(Swift.min(q, 1000).rounded(.up)), 1), 1000)
    }

    private func append(_ p: CGPoint) {
        // Broken input can overflow to Inf/NaN after transforms: drop such points
        guard p.x.isFinite, p.y.isFinite else { return }
        if current.isEmpty { current = [last] }
        if let l = current.last, l.distance(to: p) < 1e-6 { last = p; return }
        current.append(p)
        last = p
    }

    func finish(closed: Bool) {
        var pts = current
        if closed, pts.count > 1, let f = pts.first, let l = pts.last, f.distance(to: l) < 1e-6 {
            pts.removeLast()
        }
        if pts.count >= 2 {
            result.append(Polyline(points: pts, closed: closed && pts.count >= 3))
        }
        current = []
    }
}
