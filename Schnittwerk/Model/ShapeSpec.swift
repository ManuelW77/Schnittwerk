// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Basic shapes (rectangle, ellipse, polygon, star). Like text, a shape
// keeps its settings, so they can still be changed after drawing.

import CoreGraphics
import Foundation

/// Settings of a basic shape. All sizes are in millimetres.
struct ShapeSpec: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case rectangle, ellipse, polygon, star
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rectangle: String(localized: "Rectangle")
            case .ellipse: String(localized: "Ellipse")
            case .polygon: String(localized: "Polygon")
            case .star: String(localized: "Star")
            }
        }

        var systemImage: String {
            switch self {
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .polygon: "hexagon"
            case .star: "star"
            }
        }
    }

    static let sidesRange = 3...64
    static let innerRatioRange = 0.1...0.95

    var kind: Kind
    var widthMM: Double
    var heightMM: Double
    /// Rectangle only.
    var cornerRadiusMM: Double = 0
    /// Polygon: number of corners. Star: number of points.
    var sides: Int = 6
    /// Star only: inner radius as part of the outer radius.
    var innerRatio: Double = 0.5

    static func standard(_ kind: Kind) -> ShapeSpec {
        switch kind {
        case .rectangle: ShapeSpec(kind: kind, widthMM: 50, heightMM: 50)
        case .ellipse: ShapeSpec(kind: kind, widthMM: 50, heightMM: 50)
        case .polygon: ShapeSpec(kind: kind, widthMM: 50, heightMM: 50, sides: 6)
        case .star: ShapeSpec(kind: kind, widthMM: 50, heightMM: 50, sides: 5, innerRatio: 0.45)
        }
    }

    /// Same spec with all values in their allowed ranges.
    var clamped: ShapeSpec {
        var s = self
        s.widthMM = min(max(widthMM.isFinite ? widthMM : 1, 1), 5000)
        s.heightMM = min(max(heightMM.isFinite ? heightMM : 1, 1), 5000)
        let maxRadius = min(s.widthMM, s.heightMM) / 2
        s.cornerRadiusMM = min(max(cornerRadiusMM.isFinite ? cornerRadiusMM : 0, 0), maxRadius)
        s.sides = min(max(sides, Self.sidesRange.lowerBound), Self.sidesRange.upperBound)
        s.innerRatio = min(max(innerRatio.isFinite ? innerRatio : 0.5, Self.innerRatioRange.lowerBound),
                           Self.innerRatioRange.upperBound)
        return s
    }
}

enum ShapeFactory {
    /// Cut line of the shape, filling a box of width × height mm
    /// with its top left corner at (0, 0).
    static func paths(for spec: ShapeSpec) -> [Polyline] {
        let s = spec.clamped
        let box = CGRect(x: 0, y: 0, width: s.widthMM, height: s.heightMM)
        let path: CGPath
        switch s.kind {
        case .rectangle:
            let r = s.cornerRadiusMM
            path = r > 0.001 ? CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
                             : CGPath(rect: box, transform: nil)
        case .ellipse:
            path = CGPath(ellipseIn: box, transform: nil)
        case .polygon:
            path = fitted(corners(count: s.sides, inner: nil), into: box)
        case .star:
            path = fitted(corners(count: s.sides, inner: s.innerRatio), into: box)
        }
        return path.polylines(tolerance: ShapeImporter.tolerance)
    }

    /// Corners on the unit circle, first corner at the top (y down).
    /// With `inner`, every second corner lies on the inner circle.
    private static func corners(count: Int, inner: Double?) -> [CGPoint] {
        let n = inner == nil ? count : count * 2
        return (0..<n).map { i in
            let angle = -Double.pi / 2 + Double(i) * 2 * .pi / Double(n)
            let r = (inner != nil && i % 2 == 1) ? inner! : 1
            return CGPoint(x: r * cos(angle), y: r * sin(angle))
        }
    }

    /// Closed path through the points, stretched to fill the box.
    private static func fitted(_ points: [CGPoint], into box: CGRect) -> CGPath {
        let b = Polyline(points: points, closed: true).bounds
        let sx = box.width / max(b.width, 0.0001), sy = box.height / max(b.height, 0.0001)
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: box.minX + ($0.x - b.minX) * sx,
                                                    y: box.minY + ($0.y - b.minY) * sy) })
        path.closeSubpath()
        return path
    }
}

extension CutShape {
    /// New basic shape; its top left corner sits at `origin` on the mat.
    static func basic(_ spec: ShapeSpec, at origin: CGPoint) -> CutShape {
        let lines = ShapeFactory.paths(for: spec)
            .applying(CGAffineTransform(translationX: origin.x, y: origin.y))
        var shape = CutShape(name: spec.kind.title, matPaths: lines)
        shape.shapeSpec = spec.clamped
        return shape
    }

    /// The shape settings as seen on the mat, i.e. with the current
    /// scale already applied. Nil for objects that are no basic shape.
    var effectiveShapeSpec: ShapeSpec? {
        guard var s = shapeSpec else { return nil }
        let sx = abs(scaleX), sy = abs(scaleY)
        s.widthMM *= sx
        s.heightMM *= sy
        s.cornerRadiusMM *= min(sx, sy)
        return s.clamped
    }

    /// Applies new shape settings (in mm on the mat) and rebuilds the
    /// cut line. The centre and mirroring stay; the scale goes into the
    /// settings, so rounded corners keep their real radius.
    mutating func updateShapeSpec(_ spec: ShapeSpec) {
        guard shapeSpec != nil else { return }
        let s = spec.clamped
        shapeSpec = s
        replaceGeometry(ShapeFactory.paths(for: s))
        scaleX = scaleX < 0 ? -1 : 1
        scaleY = scaleY < 0 ? -1 : 1
    }

    /// Moves the current scale into the shape settings (after a resize).
    mutating func bakeShapeScale() {
        if let s = effectiveShapeSpec { updateShapeSpec(s) }
    }
}
