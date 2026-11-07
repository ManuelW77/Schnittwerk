// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// Settings of a text object. The cut lines are generated from it.
struct TextSpec: Codable, Equatable {
    var text: String
    /// PostScript name of the font face, e.g. "Helvetica-Bold".
    var fontName: String
    /// Font size (em height) in millimetres.
    var sizeMM: Double
}

/// One object on the mat. The geometry is stored centred around (0, 0);
/// position, scale and rotation place it on the mat.
struct CutShape: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    private(set) var paths: [Polyline]
    private(set) var localBounds: CGRect
    /// Centre of the object on the mat, in mm.
    var position: CGPoint
    var scaleX: Double = 1
    var scaleY: Double = 1
    /// Rotation in degrees, clockwise on screen.
    var rotation: Double = 0
    var text: TextSpec?
    /// Settings of a basic shape (rectangle, ellipse …), nil otherwise.
    var shapeSpec: ShapeSpec?
    /// Objects with `cutEnabled == false` stay visible but are not cut.
    var cutEnabled: Bool = true
    /// Objects with the same group id are selected and moved together.
    var groupID: UUID?
    /// Colour shown on the mat (e.g. a layer of a traced image), "#RRGGBB".
    var colorHex: String?
    /// Stored as optional so older project files still open.
    private var lock: Bool?

    /// A locked object cannot be selected on the mat, moved or edited.
    var isLocked: Bool {
        get { lock ?? false }
        set { lock = newValue ? true : nil }
    }

    /// Creates an object from geometry in mat coordinates.
    /// The object keeps its place on the mat.
    init(name: String, matPaths: [Polyline], text: TextSpec? = nil) {
        let b = matPaths.bounds
        let center = b.isNull ? .zero : CGPoint(x: b.midX, y: b.midY)
        self.name = name
        self.paths = matPaths.applying(CGAffineTransform(translationX: -center.x, y: -center.y))
        self.localBounds = paths.bounds.isNull ? .zero : paths.bounds
        self.position = center
        self.text = text
    }

    /// Replaces the geometry (e.g. after editing a text) and keeps
    /// position, scale and rotation.
    mutating func replaceGeometry(_ newPaths: [Polyline]) {
        let b = newPaths.bounds
        let center = b.isNull ? .zero : CGPoint(x: b.midX, y: b.midY)
        paths = newPaths.applying(CGAffineTransform(translationX: -center.x, y: -center.y))
        localBounds = paths.bounds.isNull ? .zero : paths.bounds
    }

    /// Local → mat coordinates: scale, then rotate, then move.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: position.x, y: position.y)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: scaleX, y: scaleY)
    }

    /// Geometry in mat coordinates (mm).
    var matPaths: [Polyline] { paths.applying(transform) }

    /// Size of the object without rotation, in mm.
    var size: CGSize {
        CGSize(width: localBounds.width * abs(scaleX), height: localBounds.height * abs(scaleY))
    }

    /// Axis-aligned bounding box on the mat (with rotation).
    var matBounds: CGRect {
        let t = transform
        let corners = [
            CGPoint(x: localBounds.minX, y: localBounds.minY),
            CGPoint(x: localBounds.maxX, y: localBounds.minY),
            CGPoint(x: localBounds.maxX, y: localBounds.maxY),
            CGPoint(x: localBounds.minX, y: localBounds.maxY),
        ].map { $0.applying(t) }
        return Polyline(points: corners, closed: true).bounds
    }

    /// Corners of the rotated selection frame on the mat:
    /// top left, top right, bottom right, bottom left.
    var matCorners: [CGPoint] {
        let t = transform
        return [
            CGPoint(x: localBounds.minX, y: localBounds.minY),
            CGPoint(x: localBounds.maxX, y: localBounds.minY),
            CGPoint(x: localBounds.maxX, y: localBounds.maxY),
            CGPoint(x: localBounds.minX, y: localBounds.maxY),
        ].map { $0.applying(t) }
    }

    /// True if the point (mat coordinates) lies on the object,
    /// with `slop` mm extra around the frame.
    func contains(matPoint: CGPoint, slop: CGFloat = 1) -> Bool {
        let local = matPoint.applying(transform.inverted())
        let sx = max(abs(scaleX), 0.0001), sy = max(abs(scaleY), 0.0001)
        return localBounds.insetBy(dx: -slop / sx, dy: -slop / sy).contains(local)
    }

    /// Copy with a new id, slightly offset.
    func duplicated(offset: CGFloat = 5) -> CutShape {
        var copy = self
        copy.id = UUID()
        copy.position.x += offset
        copy.position.y += offset
        return copy
    }

    /// Sets the size without rotation (mm). With `keepProportions`, the
    /// other side follows. Basic shapes keep their real corner radii.
    mutating func resize(width: Double?, height: Double?, keepProportions: Bool) {
        let base = localBounds
        if let width, width.isFinite, width > 0, base.width > 0 {
            let f = width / (base.width * abs(scaleX))
            scaleX *= f
            if keepProportions { scaleY *= f }
        }
        if let height, height.isFinite, height > 0, base.height > 0 {
            let f = height / (base.height * abs(scaleY))
            scaleY *= f
            if keepProportions { scaleX *= f }
        }
        bakeShapeScale()
    }
}
