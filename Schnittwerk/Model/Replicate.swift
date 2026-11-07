// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Transform and replicate, as in the Transform and Replicate panels of
// Silhouette Studio: scale and move the selection, copy it next to
// itself, into rows and columns, over the whole mat, mirrored or
// rotated around its centre. Each action is one undo step.

import CoreGraphics
import Foundation

enum ReplicateDirection: String, CaseIterable, Identifiable {
    case left, right, up, down
    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        case .up: String(localized: "Above")
        case .down: String(localized: "Below")
        }
    }

    var systemImage: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }

    /// Unit step on the mat (y grows downwards).
    var step: CGVector {
        switch self {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        }
    }
}

extension CutShape {
    /// Mirrors the object at the vertical line x = `axisX` (mat).
    mutating func mirrorX(at axisX: CGFloat) {
        scaleX = -scaleX
        rotation = -rotation
        position.x = 2 * axisX - position.x
    }

    /// Mirrors the object at the horizontal line y = `axisY` (mat).
    mutating func mirrorY(at axisY: CGFloat) {
        scaleY = -scaleY
        rotation = -rotation
        position.y = 2 * axisY - position.y
    }

    /// Turns the object by `degrees` around `centre` (mat).
    mutating func rotate(by degrees: Double, around centre: CGPoint) {
        let a = degrees * .pi / 180
        let dx = position.x - centre.x, dy = position.y - centre.y
        position = CGPoint(x: centre.x + dx * cos(a) - dy * sin(a), y: centre.y + dx * sin(a) + dy * cos(a))
        var r = (rotation + degrees).truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        rotation = r
    }

    /// Scales the object by `factor` around `centre` (mat).
    mutating func scale(by factor: Double, around centre: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        position = CGPoint(x: centre.x + (position.x - centre.x) * factor, y: centre.y + (position.y - centre.y) * factor)
        scaleX *= factor
        scaleY *= factor
        bakeShapeScale()
    }
}

extension ProjectData {
    /// Bounding box of the objects on the mat.
    func bounds(of ids: Set<UUID>) -> CGRect {
        shapes.filter { ids.contains($0.id) }.reduce(CGRect.null) { $0.union($1.matBounds) }
    }

    /// Copies of the objects, moved by `offset`, with new group ids.
    func copies(of ids: Set<UUID>, transform: (inout CutShape) -> Void) -> [CutShape] {
        var newGroups: [UUID: UUID] = [:]
        return shapes.filter { ids.contains($0.id) }.map { shape in
            var copy = shape
            copy.id = UUID()
            copy.isLocked = false
            if let g = shape.groupID {
                if newGroups[g] == nil { newGroups[g] = UUID() }
                copy.groupID = newGroups[g]
            }
            transform(&copy)
            return copy
        }
    }
}

extension CutDocument {
    private func editable(_ ids: Set<UUID>) -> Set<UUID> { data.unlocked(data.expandedToGroups(ids)) }

    /// Adds copies; returns their ids (empty if nothing was added).
    private func addCopies(_ copies: [CutShape], action: String, undoManager: UndoManager?) -> Set<UUID> {
        guard !copies.isEmpty else { return [] }
        update(action, undoManager: undoManager) { $0.shapes.append(contentsOf: copies) }
        return Set(copies.map(\.id))
    }

    // MARK: Transform

    /// Moves the objects by `dx`, `dy` mm.
    func move(_ ids: Set<UUID>, dx: CGFloat, dy: CGFloat, undoManager: UndoManager?) {
        let ids = editable(ids)
        update(String(localized: "Move"), undoManager: undoManager) { data in
            for i in data.shapes.indices where ids.contains(data.shapes[i].id) {
                data.shapes[i].position.x += dx
                data.shapes[i].position.y += dy
            }
        }
    }

    /// Scales the objects together around the centre of their box.
    func scale(_ ids: Set<UUID>, percent: Double, undoManager: UndoManager?) {
        let ids = editable(ids)
        let box = data.bounds(of: ids)
        guard !box.isNull, percent.isFinite, percent > 0, abs(percent - 100) > 0.01 else { return }
        let centre = CGPoint(x: box.midX, y: box.midY)
        update(String(localized: "Scale"), undoManager: undoManager) { data in
            for i in data.shapes.indices where ids.contains(data.shapes[i].id) {
                data.shapes[i].scale(by: percent / 100, around: centre)
            }
        }
    }

    /// Turns the objects together around the centre of their box.
    func rotate(_ ids: Set<UUID>, by degrees: Double, undoManager: UndoManager?) {
        let ids = editable(ids)
        let box = data.bounds(of: ids)
        guard !box.isNull, degrees.isFinite, degrees.truncatingRemainder(dividingBy: 360) != 0 else { return }
        let centre = CGPoint(x: box.midX, y: box.midY)
        update(String(localized: "Rotate"), undoManager: undoManager) { data in
            for i in data.shapes.indices where ids.contains(data.shapes[i].id) {
                data.shapes[i].rotate(by: degrees, around: centre)
            }
        }
    }

    /// Mirrors the objects together at the middle of their box.
    func mirror(_ ids: Set<UUID>, horizontally: Bool, undoManager: UndoManager?) {
        let ids = editable(ids)
        let box = data.bounds(of: ids)
        guard !box.isNull else { return }
        update(String(localized: "Mirror"), undoManager: undoManager) { data in
            for i in data.shapes.indices where ids.contains(data.shapes[i].id) {
                if horizontally { data.shapes[i].mirrorX(at: box.midX) } else { data.shapes[i].mirrorY(at: box.midY) }
            }
        }
    }

    // MARK: Replicate

    /// One copy right next to the objects.
    @discardableResult
    func duplicate(_ ids: Set<UUID>, toward direction: ReplicateDirection, gap: CGFloat,
                   undoManager: UndoManager?) -> Set<UUID> {
        replicate(ids, toward: direction, count: 1, gap: gap, undoManager: undoManager)
    }

    /// `count` copies in a row in one direction.
    @discardableResult
    func replicate(_ ids: Set<UUID>, toward direction: ReplicateDirection, count: Int, gap: CGFloat,
                   undoManager: UndoManager?) -> Set<UUID> {
        let ids = data.expandedToGroups(ids)
        let box = data.bounds(of: ids)
        guard !box.isNull, count >= 1 else { return [] }
        let step = CGVector(dx: direction.step.dx * (box.width + gap), dy: direction.step.dy * (box.height + gap))
        var all: [CutShape] = []
        for n in 1...min(count, 500) {
            all += data.copies(of: ids) {
                $0.position.x += step.dx * CGFloat(n)
                $0.position.y += step.dy * CGFloat(n)
            }
        }
        return addCopies(all, action: String(localized: "Replicate"), undoManager: undoManager)
    }

    /// Rows and columns: the objects stay at the top left of the grid.
    @discardableResult
    func replicateGrid(_ ids: Set<UUID>, rows: Int, columns: Int, gap: CGFloat,
                       undoManager: UndoManager?) -> Set<UUID> {
        let ids = data.expandedToGroups(ids)
        let box = data.bounds(of: ids)
        guard !box.isNull, rows >= 1, columns >= 1, rows * columns > 1, rows * columns <= 2000 else { return [] }
        var all: [CutShape] = []
        for r in 0..<rows {
            for c in 0..<columns where r > 0 || c > 0 {
                all += data.copies(of: ids) {
                    $0.position.x += CGFloat(c) * (box.width + gap)
                    $0.position.y += CGFloat(r) * (box.height + gap)
                }
            }
        }
        return addCopies(all, action: String(localized: "Rows and columns"), undoManager: undoManager)
    }

    /// Fills the mat with copies, starting at the top left of the mat.
    @discardableResult
    func fillMat(_ ids: Set<UUID>, gap: CGFloat, undoManager: UndoManager?) -> Set<UUID> {
        let ids = data.expandedToGroups(ids)
        let box = data.bounds(of: ids)
        let area = data.mat.displaySize
        guard !box.isNull, box.width > 0.1, box.height > 0.1 else { return [] }
        let columns = Int((area.width + gap) / (box.width + gap))
        let rows = Int((area.height + gap) / (box.height + gap))
        guard columns >= 1, rows >= 1, rows * columns > 1, rows * columns <= 2000 else { return [] }
        let originalIDs = ids
        var result: Set<UUID> = []
        update(String(localized: "Fill mat"), undoManager: undoManager) { data in
            // Move the originals to the top left corner first
            for i in data.shapes.indices where originalIDs.contains(data.shapes[i].id) {
                data.shapes[i].position.x -= box.minX
                data.shapes[i].position.y -= box.minY
            }
            for r in 0..<rows {
                for c in 0..<columns where r > 0 || c > 0 {
                    let copies = data.copies(of: originalIDs) {
                        $0.position.x += CGFloat(c) * (box.width + gap)
                        $0.position.y += CGFloat(r) * (box.height + gap)
                    }
                    data.shapes.append(contentsOf: copies)
                    result.formUnion(copies.map(\.id))
                }
            }
        }
        return result
    }

    /// A mirrored copy next to the objects (as on a fold).
    @discardableResult
    func mirrorCopy(_ ids: Set<UUID>, toward direction: ReplicateDirection, undoManager: UndoManager?) -> Set<UUID> {
        let ids = data.expandedToGroups(ids)
        let box = data.bounds(of: ids)
        guard !box.isNull else { return [] }
        let copies = data.copies(of: ids) { s in
            switch direction {
            case .left: s.mirrorX(at: box.minX)
            case .right: s.mirrorX(at: box.maxX)
            case .up: s.mirrorY(at: box.minY)
            case .down: s.mirrorY(at: box.maxY)
            }
        }
        return addCopies(copies, action: String(localized: "Mirror copy"), undoManager: undoManager)
    }

    /// `count` objects in all (the original and copies) turned evenly
    /// around the centre of the objects, e.g. for flowers or mandalas.
    @discardableResult
    func rotateCopies(_ ids: Set<UUID>, count: Int, undoManager: UndoManager?) -> Set<UUID> {
        let ids = data.expandedToGroups(ids)
        let box = data.bounds(of: ids)
        guard !box.isNull, count >= 2, count <= 72 else { return [] }
        // Turn around the bottom centre, so the copies form a ring
        let centre = CGPoint(x: box.midX, y: box.maxY)
        var all: [CutShape] = []
        for n in 1..<count {
            all += data.copies(of: ids) { $0.rotate(by: 360 / Double(count) * Double(n), around: centre) }
        }
        return addCopies(all, action: String(localized: "Rotate copies"), undoManager: undoManager)
    }
}
