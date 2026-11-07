// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Combining objects: weld, subtract, intersect. Uses the boolean path
// operations of Core Graphics. Holes follow the even-odd rule, the same
// rule the mat uses to draw objects (e.g. the inside of an "O").

import CoreGraphics
import Foundation

enum PathOperation: String, CaseIterable, Identifiable {
    /// All objects become one outline; overlaps disappear.
    case weld
    /// The objects in front are cut out of the backmost object.
    case subtract
    /// Only the area where all objects overlap stays.
    case intersect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weld: String(localized: "Weld")
        case .subtract: String(localized: "Subtract")
        case .intersect: String(localized: "Intersect")
        }
    }

    var systemImage: String {
        switch self {
        case .weld: "square.on.square.squareshape.controlhandles"
        case .subtract: "square.on.square.dashed"
        case .intersect: "square.on.square.intersection.dashed"
        }
    }

    var help: String {
        switch self {
        case .weld: String(localized: "Join the selected objects into one outline")
        case .subtract: String(localized: "Cut the front objects out of the backmost object")
        case .intersect: String(localized: "Keep only the area where all selected objects overlap")
        }
    }
}

enum PathOps {
    /// Smallest part (mm) that is kept; smaller leftovers are dropped.
    static let minPartSize: CGFloat = 0.05

    /// Applies the operation to the objects (back to front order).
    /// Returns the resulting cut lines in mat coordinates; empty if
    /// nothing is left (e.g. the objects do not overlap).
    static func apply(_ op: PathOperation, to shapes: [CutShape]) -> [Polyline] {
        guard !shapes.isEmpty else { return [] }
        let areas = shapes.map { area(of: $0.matPaths) }
        var result: CGPath
        switch op {
        case .weld:
            result = areas.dropFirst().reduce(areas[0]) { $0.union($1) }
        case .subtract:
            let cutters = areas.dropFirst()
            result = cutters.reduce(areas[0]) { $0.subtracting($1) }
        case .intersect:
            result = areas.dropFirst().reduce(areas[0]) { $0.intersection($1) }
        }
        var lines = result.polylines(tolerance: ShapeImporter.tolerance)
            .filter { $0.closed && max($0.bounds.width, $0.bounds.height) >= minPartSize }
        // Open lines (no area) cannot be welded; keep them unchanged
        if op == .weld {
            lines += shapes.flatMap { $0.matPaths.filter { !$0.closed } }
        }
        return lines
    }

    /// Filled area of the closed lines, normalised with the even-odd rule
    /// so that the later operations (non-zero rule) see the same holes.
    static func area(of lines: [Polyline]) -> CGPath {
        let path = CGMutablePath()
        for line in lines where line.closed && line.points.count >= 3 {
            path.addLines(between: line.points)
            path.closeSubpath()
        }
        return path.normalized(using: .evenOdd)
    }
}

extension CutDocument {
    /// Combines the selected objects into one new object. Returns its id,
    /// or nil if nothing could be combined (then nothing is changed).
    @discardableResult
    func combine(_ op: PathOperation, ids: Set<UUID>, undoManager: UndoManager?) -> UUID? {
        let selected = data.shapes.filter { ids.contains($0.id) } // back to front
        guard selected.count >= 2 else { return nil }
        let lines = PathOps.apply(op, to: selected)
        guard !lines.isEmpty else { return nil }
        let base = selected[0]
        var result = CutShape(name: base.name, matPaths: lines)
        result.cutEnabled = selected.contains { $0.cutEnabled }
        update(op.title, undoManager: undoManager) { data in
            // The result takes the place of the frontmost selected object
            let at = data.shapes.lastIndex { ids.contains($0.id) } ?? data.shapes.count - 1
            let removedBefore = data.shapes[..<at].filter { ids.contains($0.id) }.count
            data.shapes.removeAll { ids.contains($0.id) }
            data.shapes.insert(result, at: min(at - removedBefore, data.shapes.count))
        }
        return result.id
    }
}

// MARK: - Offset

extension PathOps {
    /// Outline at a fixed distance around the objects (all together).
    /// Positive `distance` goes outwards, negative inwards (mm).
    /// `roundCorners` rounds outer corners; otherwise they stay sharp.
    static func offset(_ shapes: [CutShape], by distance: CGFloat, roundCorners: Bool) -> [Polyline] {
        guard distance.isFinite, abs(distance) >= 0.01 else { return [] }
        let lines = shapes.flatMap(\.matPaths)
        let filled = area(of: lines)
        // Stroke along every line, closed and open, at the given distance
        let outline = CGMutablePath()
        for line in lines where line.points.count >= 2 {
            outline.addLines(between: line.points)
            if line.closed { outline.closeSubpath() }
        }
        let band = outline.copy(strokingWithWidth: abs(distance) * 2, lineCap: .round,
                                lineJoin: roundCorners ? .round : .miter, miterLimit: 10)
        let result = distance > 0 ? filled.union(band) : filled.subtracting(band)
        return result.polylines(tolerance: ShapeImporter.tolerance)
            .filter { $0.closed && max($0.bounds.width, $0.bounds.height) >= minPartSize }
    }
}

extension CutDocument {
    /// Adds an offset outline behind the selected objects. Returns its id,
    /// or nil if the outline would be empty (then nothing is changed).
    @discardableResult
    func addOffset(ids: Set<UUID>, distance: CGFloat, roundCorners: Bool, undoManager: UndoManager?) -> UUID? {
        let selected = data.shapes.filter { ids.contains($0.id) }
        guard let first = selected.first else { return nil }
        let lines = PathOps.offset(selected, by: distance, roundCorners: roundCorners)
        guard !lines.isEmpty else { return nil }
        let name = selected.count == 1 ? String(localized: "\(first.name) offset") : String(localized: "Offset")
        let result = CutShape(name: name, matPaths: lines)
        update(String(localized: "Add offset"), undoManager: undoManager) { data in
            let at = data.shapes.firstIndex { ids.contains($0.id) } ?? 0
            data.shapes.insert(result, at: at)
        }
        return result.id
    }
}
