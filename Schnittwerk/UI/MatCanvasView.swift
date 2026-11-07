// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// The cutting mat: draws all objects and handles selecting,
// moving, scaling (corner handles) and rotating (round handle).

import AppKit
import SwiftUI

/// Converts between mat millimetres and view points.
struct MatViewport {
    let pxPerMM: CGFloat
    let margin: CGFloat

    var matToView: CGAffineTransform {
        CGAffineTransform(translationX: margin, y: margin).scaledBy(x: pxPerMM, y: pxPerMM)
    }

    func view(_ p: CGPoint) -> CGPoint { p.applying(matToView) }
    func mat(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - margin) / pxPerMM, y: (p.y - margin) / pxPerMM) }
}

struct MatCanvasView: View {
    @ObservedObject var document: CutDocument
    @Binding var selection: Set<UUID>
    let zoom: CGFloat

    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var drag: DragState?
    /// Rubber band while dragging on the empty mat (mat coordinates).
    @State private var marquee: CGRect?
    @FocusState private var focused: Bool

    static let basePxPerMM: CGFloat = 2.6
    static let margin: CGFloat = 28
    private static let handleRadius: CGFloat = 5
    private static let rotateHandleDistance: CGFloat = 26

    private var viewport: MatViewport { MatViewport(pxPerMM: Self.basePxPerMM * zoom, margin: Self.margin) }

    /// Shown mat area; a roll grows with its content.
    private var matSize: CGSize {
        let mat = document.data.mat
        var size = mat.displaySize
        if mat == .roll {
            let maxY = document.data.shapes.map(\.matBounds.maxY).max() ?? 0
            size.height = min(max(size.height, maxY + 100), mat.size.height)
        }
        return size
    }

    var body: some View {
        let vp = viewport
        let size = CGSize(width: matSize.width * vp.pxPerMM + 2 * vp.margin,
                          height: matSize.height * vp.pxPerMM + 2 * vp.margin)
        Canvas { ctx, _ in
            drawMat(&ctx, vp)
            for shape in document.data.shapes {
                drawShape(shape, &ctx, vp)
            }
            let selected = document.data.shapes.filter { selection.contains($0.id) }
            for shape in selected {
                drawSelection(shape, handles: selected.count == 1, &ctx, vp)
            }
            if let marquee {
                let r = Path(marquee.applying(vp.matToView))
                ctx.fill(r, with: .color(.accentColor.opacity(0.08)))
                ctx.stroke(r, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(dragGesture(vp))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            nudge(press)
        }
        .onDeleteCommand { deleteSelection() }
        .accessibilityLabel(Text("Cutting mat"))
    }

    // MARK: - Drawing

    private var matColor: Color { colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.96) }
    private var gridColor: Color { colorScheme == .dark ? Color(white: 0.30) : Color(white: 0.86) }
    private var gridStrongColor: Color { colorScheme == .dark ? Color(white: 0.40) : Color(white: 0.72) }

    private func drawMat(_ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let rect = CGRect(origin: .zero, size: matSize).applying(vp.matToView)
        ctx.fill(Path(rect), with: .color(matColor))

        // Grid: 10 mm thin, 50 mm stronger with cm labels
        var thin = Path(), strong = Path()
        var x: CGFloat = 0
        while x <= matSize.width + 0.01 {
            var p = Path()
            p.move(to: vp.view(CGPoint(x: x, y: 0)))
            p.addLine(to: vp.view(CGPoint(x: x, y: matSize.height)))
            if Int(x.rounded()) % 50 == 0 { strong.addPath(p) } else { thin.addPath(p) }
            if Int(x.rounded()) % 50 == 0 {
                ctx.draw(Text(verbatim: "\(Int(x / 10))").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: vp.view(CGPoint(x: x, y: 0)).x, y: vp.margin / 2))
            }
            x += 10
        }
        var y: CGFloat = 0
        while y <= matSize.height + 0.01 {
            var p = Path()
            p.move(to: vp.view(CGPoint(x: 0, y: y)))
            p.addLine(to: vp.view(CGPoint(x: matSize.width, y: y)))
            if Int(y.rounded()) % 50 == 0 { strong.addPath(p) } else { thin.addPath(p) }
            if Int(y.rounded()) % 50 == 0 {
                ctx.draw(Text(verbatim: "\(Int(y / 10))").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: vp.margin / 2, y: vp.view(CGPoint(x: 0, y: y)).y))
            }
            y += 10
        }
        ctx.stroke(thin, with: .color(gridColor), lineWidth: 0.5)
        ctx.stroke(strong, with: .color(gridStrongColor), lineWidth: 0.8)
        ctx.stroke(Path(rect), with: .color(gridStrongColor), lineWidth: 1)
    }

    private func path(for shape: CutShape, _ vp: MatViewport) -> Path {
        var p = Path()
        for line in shape.paths {
            guard let first = line.points.first else { continue }
            p.move(to: first)
            for pt in line.points.dropFirst() { p.addLine(to: pt) }
            if line.closed { p.closeSubpath() }
        }
        return p.applying(shape.transform.concatenating(vp.matToView))
    }

    private func drawShape(_ shape: CutShape, _ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let p = path(for: shape, vp)
        let outside = !shape.fits(in: document.data.mat.size)
        let color: Color = !shape.cutEnabled ? .gray : (outside ? .orange : .red)
        ctx.fill(p, with: .color(color.opacity(0.10)), style: FillStyle(eoFill: true))
        if shape.cutEnabled {
            ctx.stroke(p, with: .color(color), lineWidth: 1)
        } else {
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// Selection frame; with `handles`, also the scale and rotate handles
    /// (only shown when exactly one object is selected).
    private func drawSelection(_ shape: CutShape, handles: Bool, _ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let corners = shape.matCorners.map(vp.view)
        var frame = Path()
        frame.addLines(corners)
        frame.closeSubpath()
        ctx.stroke(frame, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        guard handles else { return }

        let rotate = rotateHandle(shape, vp)
        var stem = Path()
        stem.move(to: CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2))
        stem.addLine(to: rotate)
        ctx.stroke(stem, with: .color(.accentColor), lineWidth: 1)

        let r = Self.handleRadius
        for c in corners {
            let box = Path(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(box, with: .color(.white))
            ctx.stroke(box, with: .color(.accentColor), lineWidth: 1.2)
        }
        let circle = Path(ellipseIn: CGRect(x: rotate.x - r, y: rotate.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(circle, with: .color(.white))
        ctx.stroke(circle, with: .color(.accentColor), lineWidth: 1.2)
    }

    /// Round handle above the top edge (view coordinates).
    private func rotateHandle(_ shape: CutShape, _ vp: MatViewport) -> CGPoint {
        let c = shape.matCorners.map(vp.view)
        let top = CGPoint(x: (c[0].x + c[1].x) / 2, y: (c[0].y + c[1].y) / 2)
        let a = shape.rotation * .pi / 180
        // Up direction of the object on screen (y down)
        var dir = CGPoint(x: sin(a), y: -cos(a))
        if shape.scaleY < 0 { dir = CGPoint(x: -dir.x, y: -dir.y) }
        return CGPoint(x: top.x + dir.x * Self.rotateHandleDistance, y: top.y + dir.y * Self.rotateHandleDistance)
    }

    // MARK: - Mouse

    private enum DragKind {
        /// Moves all selected objects; start position per object.
        case move(startPositions: [UUID: CGPoint])
        case scale(id: UUID, startScaleX: Double, startScaleY: Double, startDistance: CGFloat)
        case rotate(id: UUID, startRotation: Double, startAngle: CGFloat)
        /// Rubber band; `base` stays selected (shift/command held).
        case marquee(base: Set<UUID>)
        case none
    }

    private struct DragState {
        let kind: DragKind
        let before: ProjectData
        let startMat: CGPoint
    }

    private func dragGesture(_ vp: MatViewport) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil { beginDrag(at: value.startLocation, vp) }
                continueDrag(to: value.location, vp)
            }
            .onEnded { _ in
                guard let d = drag else { return }
                let name: String
                switch d.kind {
                case .move: name = String(localized: "Move")
                case .scale: name = String(localized: "Resize")
                case .rotate: name = String(localized: "Rotate")
                case .marquee, .none: name = ""
                }
                document.commitChange(from: d.before, actionName: name, undoManager: undoManager)
                drag = nil
                marquee = nil
            }
    }

    private func beginDrag(at point: CGPoint, _ vp: MatViewport) {
        focused = true
        let matPoint = vp.mat(point)
        let before = document.data
        let hit = Self.handleRadius + 3
        let flags = NSEvent.modifierFlags
        let extend = flags.contains(.shift) || flags.contains(.command)

        // 1. Handles of the selected object (only with one selected)
        if selection.count == 1, let id = selection.first,
           let shape = document.data.shapes.first(where: { $0.id == id }) {
            if rotateHandle(shape, vp).distance(to: point) <= hit {
                let angle = atan2(matPoint.y - shape.position.y, matPoint.x - shape.position.x)
                drag = DragState(kind: .rotate(id: id, startRotation: shape.rotation, startAngle: angle),
                                 before: before, startMat: matPoint)
                return
            }
            if shape.matCorners.map(vp.view).contains(where: { $0.distance(to: point) <= hit }) {
                drag = DragState(kind: .scale(id: id, startScaleX: shape.scaleX, startScaleY: shape.scaleY,
                                              startDistance: max(matPoint.distance(to: shape.position), 0.1)),
                                 before: before, startMat: matPoint)
                return
            }
        }
        // 2. Topmost object under the mouse
        if let shape = document.data.shapes.last(where: { $0.contains(matPoint: matPoint, slop: 4 / vp.pxPerMM) }) {
            if extend {
                // Shift/command click adds or removes one object
                if selection.contains(shape.id) {
                    selection.remove(shape.id)
                    drag = DragState(kind: .none, before: before, startMat: matPoint)
                    return
                }
                selection.insert(shape.id)
            } else if !selection.contains(shape.id) {
                selection = [shape.id]
            }
            let starts = Dictionary(uniqueKeysWithValues: document.data.shapes
                .filter { selection.contains($0.id) }.map { ($0.id, $0.position) })
            drag = DragState(kind: .move(startPositions: starts), before: before, startMat: matPoint)
            return
        }
        // 3. Empty mat: rubber band selection
        if !extend { selection = [] }
        drag = DragState(kind: .marquee(base: selection), before: before, startMat: matPoint)
    }

    private func continueDrag(to point: CGPoint, _ vp: MatViewport) {
        guard let d = drag else { return }
        let matPoint = vp.mat(point)
        let shift = NSEvent.modifierFlags.contains(.shift)

        switch d.kind {
        case .move(let starts):
            var dx = matPoint.x - d.startMat.x, dy = matPoint.y - d.startMat.y
            if shift { // only horizontal or vertical
                if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
            }
            for i in document.data.shapes.indices {
                guard let start = starts[document.data.shapes[i].id] else { continue }
                document.data.shapes[i].position = CGPoint(x: start.x + dx, y: start.y + dy)
            }
        case .scale(let id, let sx, let sy, let startDistance):
            guard let index = document.data.shapes.firstIndex(where: { $0.id == id }) else { return }
            var shape = document.data.shapes[index]
            var factor = matPoint.distance(to: shape.position) / startDistance
            // At least 1 mm in both directions
            let base = shape.localBounds
            let minFactor = max(1 / max(base.width * abs(sx), 0.001), 1 / max(base.height * abs(sy), 0.001))
            factor = max(factor, min(minFactor, 1))
            shape.scaleX = sx * factor
            shape.scaleY = sy * factor
            document.data.shapes[index] = shape
        case .rotate(let id, let startRotation, let startAngle):
            guard let index = document.data.shapes.firstIndex(where: { $0.id == id }) else { return }
            let shape = document.data.shapes[index]
            let angle = atan2(matPoint.y - shape.position.y, matPoint.x - shape.position.x)
            var r = startRotation + Double((angle - startAngle) * 180 / .pi)
            if shift { r = (r / 15).rounded() * 15 }
            document.data.shapes[index].rotation = normalizedDegrees(r)
        case .marquee(let base):
            let rect = CGRect(x: min(d.startMat.x, matPoint.x), y: min(d.startMat.y, matPoint.y),
                              width: abs(matPoint.x - d.startMat.x), height: abs(matPoint.y - d.startMat.y))
            marquee = rect
            let hits = document.data.shapes.filter { $0.matBounds.intersects(rect) }.map(\.id)
            selection = base.union(hits)
        case .none:
            return
        }
    }

    // MARK: - Keyboard

    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard !selection.isEmpty else { return .ignored }
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch press.key {
        case .leftArrow: dx = -step
        case .rightArrow: dx = step
        case .upArrow: dy = -step
        case .downArrow: dy = step
        default: return .ignored
        }
        let ids = selection
        document.update(String(localized: "Move"), undoManager: undoManager) { data in
            for i in data.shapes.indices where ids.contains(data.shapes[i].id) {
                data.shapes[i].position.x += dx
                data.shapes[i].position.y += dy
            }
        }
        return .handled
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        document.update(String(localized: "Delete"), undoManager: undoManager) { data in
            data.shapes.removeAll { ids.contains($0.id) }
        }
        selection = []
    }
}

/// Angle in the range -180…180.
func normalizedDegrees(_ value: Double) -> Double {
    var r = value.truncatingRemainder(dividingBy: 360)
    if r > 180 { r -= 360 }
    if r <= -180 { r += 360 }
    return r
}
