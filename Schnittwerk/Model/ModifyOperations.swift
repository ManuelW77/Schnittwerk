// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// More path operations, as in the Modify panel of Silhouette Studio:
// subtract all, divide, crop, and compound paths (make and release).

import CoreGraphics
import Foundation

enum ModifyOperation: String, CaseIterable, Identifiable {
    /// The frontmost object is cut out of every other selected object.
    case subtractAll
    /// Overlapping objects are split into all their separate pieces.
    case divide
    /// The frontmost object works as a frame: only what lies inside stays.
    case crop
    /// All selected objects become one object (holes stay holes).
    case makeCompound
    /// One object is split into its separate outlines (with their holes).
    case releaseCompound

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtractAll: String(localized: "Subtract all")
        case .divide: String(localized: "Divide")
        case .crop: String(localized: "Crop")
        case .makeCompound: String(localized: "Make compound path")
        case .releaseCompound: String(localized: "Release compound path")
        }
    }

    var systemImage: String {
        switch self {
        case .subtractAll: "square.stack.3d.down.dottedline"
        case .divide: "square.split.diagonal.2x2"
        case .crop: "crop"
        case .makeCompound: "square.on.square"
        case .releaseCompound: "square.on.square.dashed"
        }
    }

    var help: String {
        switch self {
        case .subtractAll: String(localized: "Cut the frontmost object out of every other selected object")
        case .divide: String(localized: "Split overlapping objects into all their pieces")
        case .crop: String(localized: "Keep only what lies inside the frontmost object")
        case .makeCompound: String(localized: "Join the selected objects into one object without changing the lines")
        case .releaseCompound: String(localized: "Split an object into its separate outlines")
        }
    }

    /// Smallest selection the operation needs.
    var minimumCount: Int { self == .releaseCompound ? 1 : 2 }
}

extension PathOps {
    static func lines(of path: CGPath) -> [Polyline] {
        path.polylines(tolerance: ShapeImporter.tolerance)
            .filter { $0.closed && max($0.bounds.width, $0.bounds.height) >= minPartSize }
    }

    /// Splits lines into outlines, each with the holes directly inside it.
    static func outlines(_ lines: [Polyline]) -> [[Polyline]] {
        let closed = lines.filter { $0.closed && $0.points.count >= 3 }
        let open = lines.filter { !$0.closed || $0.points.count < 3 }
        let paths = closed.map { line -> CGPath in
            let p = CGMutablePath()
            p.addLines(between: line.points)
            p.closeSubpath()
            return p
        }
        let areas = closed.map { $0.bounds.width * $0.bounds.height }
        // Containers of each line: the larger lines its first point lies in
        func containers(_ j: Int) -> [Int] {
            guard let pt = closed[j].points.first else { return [] }
            return closed.indices.filter { i in i != j && areas[i] > areas[j] && paths[i].contains(pt) }
        }
        let depth = closed.indices.map { containers($0).count }
        var groups: [Int: [Polyline]] = [:]
        var order: [Int] = []
        for j in closed.indices {
            if depth[j] % 2 == 0 {
                groups[j, default: []].insert(closed[j], at: 0)
                if !order.contains(j) { order.append(j) }
            } else {
                // A hole belongs to its smallest container
                let owner = containers(j).filter { depth[$0] == depth[j] - 1 }.min { areas[$0] < areas[$1] }
                if let owner {
                    groups[owner, default: []].append(closed[j])
                    if !order.contains(owner) { order.append(owner) }
                }
            }
        }
        return order.compactMap { groups[$0] } + open.map { [$0] }
    }
}

extension CutDocument {
    /// Applies the operation. Returns the ids of the resulting objects,
    /// or an empty set if nothing changed.
    @discardableResult
    func modify(_ op: ModifyOperation, ids: Set<UUID>, undoManager: UndoManager?) -> Set<UUID> {
        let ids = data.unlocked(ids)
        let selected = data.shapes.filter { ids.contains($0.id) } // back to front
        guard selected.count >= op.minimumCount else { return [] }

        func make(_ lines: [Polyline], like base: CutShape, name: String? = nil) -> CutShape {
            var s = CutShape(name: name ?? base.name, matPaths: lines)
            s.cutEnabled = base.cutEnabled
            s.toolSlot = base.toolSlot
            s.colorHex = base.colorHex
            return s
        }

        var results: [CutShape] = []
        switch op {
        case .subtractAll:
            guard let cutter = selected.last else { return [] }
            let cutterArea = PathOps.area(of: cutter.matPaths)
            for shape in selected.dropLast() {
                let lines = PathOps.lines(of: PathOps.area(of: shape.matPaths).subtracting(cutterArea))
                if !lines.isEmpty { results.append(make(lines, like: shape)) }
            }
        case .divide:
            // Every region covered by a distinct set of objects becomes one piece
            var pieces: [(CGPath, CutShape)] = []
            for shape in selected {
                var area = PathOps.area(of: shape.matPaths)
                var next: [(CGPath, CutShape)] = []
                for (piece, owner) in pieces {
                    let inside = piece.intersection(area)
                    let outside = piece.subtracting(area)
                    if !inside.isEmpty { next.append((inside, owner)) }
                    if !outside.isEmpty { next.append((outside, owner)) }
                    area = area.subtracting(piece)
                }
                if !area.isEmpty { next.append((area, shape)) }
                pieces = next
            }
            for (piece, owner) in pieces {
                for outline in PathOps.outlines(PathOps.lines(of: piece)) {
                    results.append(make(outline, like: owner))
                }
            }
        case .crop:
            guard let frame = selected.last else { return [] }
            let frameArea = PathOps.area(of: frame.matPaths)
            for shape in selected.dropLast() {
                let lines = PathOps.lines(of: PathOps.area(of: shape.matPaths).intersection(frameArea))
                if !lines.isEmpty { results.append(make(lines, like: shape)) }
            }
        case .makeCompound:
            results = [make(selected.flatMap(\.matPaths), like: selected[0])]
        case .releaseCompound:
            for shape in selected {
                let parts = PathOps.outlines(shape.matPaths)
                guard parts.count > 1 else { continue }
                for (n, part) in parts.enumerated() {
                    results.append(make(part, like: shape, name: "\(shape.name) \(n + 1)"))
                }
            }
            if results.isEmpty { return [] }
        }
        guard !results.isEmpty else { return [] }

        let removed: Set<UUID> = op == .releaseCompound
            ? Set(selected.filter { PathOps.outlines($0.matPaths).count > 1 }.map(\.id))
            : ids
        update(op.title, undoManager: undoManager) { data in
            let at = data.shapes.lastIndex { removed.contains($0.id) } ?? data.shapes.count - 1
            let removedBefore = data.shapes[..<at].filter { removed.contains($0.id) }.count
            data.shapes.removeAll { removed.contains($0.id) }
            data.shapes.insert(contentsOf: results, at: max(0, min(at - removedBefore, data.shapes.count)))
        }
        return Set(results.map(\.id))
    }
}
