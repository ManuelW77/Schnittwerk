// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Aligning and distributing objects by their bounding boxes on the mat.

import CoreGraphics
import Foundation

enum AlignEdge: String, CaseIterable, Identifiable {
    case left, centerX, right, top, centerY, bottom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: String(localized: "Align left")
        case .centerX: String(localized: "Align centres horizontally")
        case .right: String(localized: "Align right")
        case .top: String(localized: "Align top")
        case .centerY: String(localized: "Align centres vertically")
        case .bottom: String(localized: "Align bottom")
        }
    }

    var systemImage: String {
        switch self {
        case .left: "align.horizontal.left"
        case .centerX: "align.horizontal.center"
        case .right: "align.horizontal.right"
        case .top: "align.vertical.top"
        case .centerY: "align.vertical.center"
        case .bottom: "align.vertical.bottom"
        }
    }

    /// Shift that brings `box` onto this edge of `reference`.
    func shift(of box: CGRect, to reference: CGRect) -> CGVector {
        switch self {
        case .left: CGVector(dx: reference.minX - box.minX, dy: 0)
        case .centerX: CGVector(dx: reference.midX - box.midX, dy: 0)
        case .right: CGVector(dx: reference.maxX - box.maxX, dy: 0)
        case .top: CGVector(dx: 0, dy: reference.minY - box.minY)
        case .centerY: CGVector(dx: 0, dy: reference.midY - box.midY)
        case .bottom: CGVector(dx: 0, dy: reference.maxY - box.maxY)
        }
    }
}

enum DistributeAxis: String, CaseIterable, Identifiable {
    case horizontal, vertical
    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontal: String(localized: "Distribute horizontally")
        case .vertical: String(localized: "Distribute vertically")
        }
    }

    var systemImage: String {
        switch self {
        case .horizontal: "distribute.horizontal.center"
        case .vertical: "distribute.vertical.center"
        }
    }
}

extension CutDocument {
    /// Aligns the objects to each other. A single object is aligned
    /// to the mat instead.
    func align(_ edge: AlignEdge, ids: Set<UUID>, undoManager: UndoManager?) {
        let selected = data.shapes.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let reference = selected.count == 1
            ? CGRect(origin: .zero, size: data.mat.displaySize)
            : selected.reduce(CGRect.null) { $0.union($1.matBounds) }
        update(edge.title, undoManager: undoManager) { data in
            for i in data.shapes.indices where ids.contains(data.shapes[i].id) {
                let v = edge.shift(of: data.shapes[i].matBounds, to: reference)
                data.shapes[i].position.x += v.dx
                data.shapes[i].position.y += v.dy
            }
        }
    }

    /// Spaces three or more objects evenly between the outermost two,
    /// with equal gaps between their bounding boxes.
    func distribute(_ axis: DistributeAxis, ids: Set<UUID>, undoManager: UndoManager?) {
        let horizontal = axis == .horizontal
        func start(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
        func length(_ r: CGRect) -> CGFloat { horizontal ? r.width : r.height }

        let selected = data.shapes.filter { ids.contains($0.id) }
            .sorted { start($0.matBounds) < start($1.matBounds) }
        guard selected.count >= 3, let first = selected.first, let last = selected.last else { return }
        let total = start(last.matBounds) + length(last.matBounds) - start(first.matBounds)
        let gap = (total - selected.reduce(0) { $0 + length($1.matBounds) }) / CGFloat(selected.count - 1)

        var targets: [UUID: CGFloat] = [:]
        var cursor = start(first.matBounds)
        for shape in selected {
            targets[shape.id] = cursor
            cursor += length(shape.matBounds) + gap
        }
        update(axis.title, undoManager: undoManager) { data in
            for i in data.shapes.indices {
                guard let target = targets[data.shapes[i].id] else { continue }
                let d = target - start(data.shapes[i].matBounds)
                if horizontal { data.shapes[i].position.x += d } else { data.shapes[i].position.y += d }
            }
        }
    }
}
