// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// The cutting mat: draws all objects and handles selecting,
// moving, scaling (corner handles) and rotating (round handle).
// With a drawing tool, clicks place text or draw lines and curves.

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

/// The printed grid of Silhouette mats.
enum MatGrid {
    static let inch: CGFloat = 25.4
    /// Thin lines per inch.
    static let subdivisions = 4
}

struct MatCanvasView: View {
    @ObservedObject var document: CutDocument
    @Binding var selection: Set<UUID>
    let zoom: CGFloat
    @Binding var tool: DrawingTool
    /// Called after a new object was drawn or placed.
    var onCreated: () -> Void = {}
    /// Called to edit the text of a text object (double-click).
    var onEditText: (UUID) -> Void = { _ in }
    /// Called to paste a drawing from the clipboard (⌘V, context menu).
    var onPaste: () -> Void = {}

    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var drag: DragState?
    /// Rubber band while dragging on the empty mat (mat coordinates).
    @State private var marquee: CGRect?
    @FocusState private var focused: Bool
    /// Freehand line while drawing (mat coordinates).
    @State private var freehand: [CGPoint] = []
    /// Curve under construction with the curve tool.
    @State private var pen = PenCurve()
    /// True while the mouse is down on a new curve point.
    @State private var penDragging = false
    /// Mouse position over the mat (view coordinates).
    @State private var hover: CGPoint?
    /// Point being dragged with the point tool.
    @State private var pointDrag: PointDrag?
    /// Straight line of the knife while dragging (mat coordinates).
    @State private var knifeLine: (CGPoint, CGPoint)?
    /// Stroke of the eraser while dragging (mat coordinates).
    @State private var eraserStroke: [CGPoint] = []
    @AppStorage("eraser.radius") private var eraserRadius = 2.0

    private struct PointDrag {
        let id: UUID
        let ref: PointRef
        let before: ProjectData
    }

    /// Most points shown for editing; more would cover the object.
    private static let maxEditablePoints = 2000

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
            if document.data.usesPrintAndCut { drawPrintAndCut(&ctx, vp) }
            for shape in document.data.shapes {
                drawShape(shape, &ctx, vp)
            }
            let selected = document.data.shapes.filter { selection.contains($0.id) }
            for shape in selected {
                drawSelection(shape, handles: selected.count == 1 && !shape.isLocked, &ctx, vp)
            }
            // Tool number at the selected objects; the colour shows it for all
            for shape in selected where shape.cutEnabled { drawToolBadge(shape, &ctx, vp) }
            if tool == .points, let target = pointTarget {
                drawPoints(target, &ctx, vp)
            }
            drawToolPreview(&ctx, vp)
            if let marquee {
                let r = Path(marquee.applying(vp.matToView))
                ctx.fill(r, with: .color(.accentColor.opacity(0.08)))
                ctx.stroke(r, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(dragGesture(vp))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            if tool == .points {
                pointDoubleClick(at: vp.mat(tap.location), vp)
                return
            }
            guard tool == .select else { return }
            let p = vp.mat(tap.location)
            if let shape = topmostUnlocked(at: p, vp), shape.text != nil {
                selection = [shape.id]
                onEditText(shape.id)
            }
        })
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            nudge(press)
        }
        .onKeyPress(.return) {
            guard !pen.anchors.isEmpty else { return .ignored }
            finishPen(closed: false)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "vtfpakeVTFPAKE"), phases: .down) { press in
            guard press.modifiers.isEmpty || press.modifiers == .shift,
                  let picked = DrawingTool.allCases.first(where: { String($0.key) == press.characters.lowercased() })
            else { return .ignored }
            tool = picked
            return .handled
        }
        .onExitCommand {
            if !pen.anchors.isEmpty { finishPen(closed: false) } else { tool = .select }
        }
        .onChange(of: tool) {
            if !pen.anchors.isEmpty { finishPen(closed: false) }
            freehand = []
            knifeLine = nil
            eraserStroke = []
            if hover != nil { updateCursor() }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                hover = p
                updateCursor()
            case .ended:
                hover = nil
                if !MatNavigator.handActive { NSCursor.arrow.set() }
            }
        }
        .contextMenu { contextMenu(vp) }
        .onPasteCommand(of: PasteboardImport.acceptedTypes) { _ in onPaste() }
        .onAppear { focused = true }
        .onDeleteCommand {
            if !pen.anchors.isEmpty { pen.anchors.removeLast() } else { deleteSelection() }
        }
        .accessibilityLabel(Text("Cutting mat"))
    }

    // MARK: - Drawing

    private var matColor: Color { colorScheme == .dark ? Color(white: 0.20) : Color(white: 0.96) }
    private var gridColor: Color { colorScheme == .dark ? Color(white: 0.30) : Color(white: 0.86) }
    private var gridStrongColor: Color { colorScheme == .dark ? Color(white: 0.40) : Color(white: 0.72) }

    private func drawMat(_ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let rect = CGRect(origin: .zero, size: matSize).applying(vp.matToView)
        ctx.fill(Path(rect), with: .color(matColor))

        // Grid like the printed Silhouette mat: 1 inch squares numbered in
        // inches, thin lines every quarter inch
        var thin = Path(), strong = Path()
        let step = MatGrid.inch / CGFloat(MatGrid.subdivisions)
        var i = 0
        while CGFloat(i) * step <= matSize.width + 0.01 {
            let x = CGFloat(i) * step
            var p = Path()
            p.move(to: vp.view(CGPoint(x: x, y: 0)))
            p.addLine(to: vp.view(CGPoint(x: x, y: matSize.height)))
            if i % MatGrid.subdivisions == 0 {
                strong.addPath(p)
                ctx.draw(Text(verbatim: "\(i / MatGrid.subdivisions)").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: vp.view(CGPoint(x: x, y: 0)).x, y: vp.margin / 2))
            } else {
                thin.addPath(p)
            }
            i += 1
        }
        i = 0
        while CGFloat(i) * step <= matSize.height + 0.01 {
            let y = CGFloat(i) * step
            var p = Path()
            p.move(to: vp.view(CGPoint(x: 0, y: y)))
            p.addLine(to: vp.view(CGPoint(x: matSize.width, y: y)))
            if i % MatGrid.subdivisions == 0 {
                strong.addPath(p)
                ctx.draw(Text(verbatim: "\(i / MatGrid.subdivisions)").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: vp.margin / 2, y: vp.view(CGPoint(x: 0, y: y)).y))
            } else {
                thin.addPath(p)
            }
            i += 1
        }
        ctx.stroke(thin, with: .color(gridColor), lineWidth: 0.5)
        ctx.stroke(strong, with: .color(gridStrongColor), lineWidth: 0.8)
        ctx.stroke(Path(rect), with: .color(gridStrongColor), lineWidth: 1)
    }

    private func path(for shape: CutShape, _ vp: MatViewport, closedOnly: Bool = false) -> Path {
        var p = Path()
        for line in shape.paths where !closedOnly || line.closed {
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
        let color: Color = !shape.cutEnabled ? .gray : (outside ? .orange : ToolSlotStyle.color(shape.toolSlot))
        let fill = shape.colorHex.flatMap(RGB.init(hex:)).map { Color(red: $0.r, green: $0.g, blue: $0.b).opacity(0.55) }
            ?? color.opacity(0.10)
        ctx.fill(path(for: shape, vp, closedOnly: true), with: .color(fill), style: FillStyle(eoFill: true))
        if shape.cutEnabled {
            ctx.stroke(p, with: .color(color), lineWidth: 1)
        } else {
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// Number of the tool at the top left of a selected object.
    private func drawToolBadge(_ shape: CutShape, _ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let b = shape.matBounds
        guard !b.isNull else { return }
        let at = vp.view(CGPoint(x: b.minX, y: b.minY))
        let r = CGRect(x: at.x - 7, y: at.y - 7, width: 14, height: 14)
        ctx.fill(Path(ellipseIn: r), with: .color(ToolSlotStyle.color(shape.toolSlot)))
        ctx.draw(Text(verbatim: "\(shape.toolSlot)").font(.system(size: 9, weight: .bold)).foregroundColor(.white),
                 at: CGPoint(x: r.midX, y: r.midY))
    }

    /// Paper sheet with the registration marks at the top left of the mat.
    private func drawPrintAndCut(_ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let pc = document.data.printCut
        let paper = CGRect(origin: .zero, size: pc.paperSize).applying(vp.matToView)
        ctx.fill(Path(paper), with: .color(colorScheme == .dark ? Color(white: 0.32) : .white))
        ctx.stroke(Path(paper), with: .color(.secondary.opacity(0.6)), lineWidth: 0.8)
        let area = pc.designArea.applying(vp.matToView)
        ctx.stroke(Path(area), with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6, dash: [4, 3]))
        var marks = Path()
        for m in pc.marks {
            marks.addLines(m.points.map(vp.view))
            marks.closeSubpath()
        }
        ctx.fill(marks, with: .color(colorScheme == .dark ? .white : .black))
    }

    // MARK: - Point tool

    /// The one selected, unlocked object whose points are edited.
    private var pointTarget: CutShape? {
        guard selection.count == 1, let id = selection.first,
              let s = document.data.shapes.first(where: { $0.id == id }), !s.isLocked else { return nil }
        return s
    }

    private func drawPoints(_ shape: CutShape, _ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let all = shape.matPoints
        guard all.reduce(0, { $0 + $1.count }) <= Self.maxEditablePoints else { return }
        let r: CGFloat = 3.5
        for line in all {
            for (j, p) in line.enumerated() {
                let v = vp.view(p)
                let box = Path(CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(box, with: .color(j == 0 ? .accentColor : .white))
                ctx.stroke(box, with: .color(.accentColor), lineWidth: 1)
            }
        }
    }

    private func pointRadius(_ vp: MatViewport) -> CGFloat { (Self.handleRadius + 3) / vp.pxPerMM }

    private func pointDoubleClick(at p: CGPoint, _ vp: MatViewport) {
        guard let target = pointTarget, let i = document.data.shapes.firstIndex(where: { $0.id == target.id }) else { return }
        if let ref = target.point(near: p, radius: pointRadius(vp)) {
            document.update(String(localized: "Delete point"), undoManager: undoManager) { $0.shapes[i].deletePoint(ref) }
        } else if let (seg, at) = target.segment(near: p, radius: pointRadius(vp)) {
            document.update(String(localized: "Add point"), undoManager: undoManager) { $0.shapes[i].insertPoint(after: seg, atMat: at) }
        }
        // An object without lines left is removed
        if document.data.shapes.indices.contains(i), document.data.shapes[i].paths.isEmpty {
            let id = document.data.shapes[i].id
            document.update(String(localized: "Delete point"), undoManager: undoManager) { $0.shapes.removeAll { $0.id == id } }
            selection = []
        }
    }

    /// Freehand line and curve while they are being drawn.
    private func drawToolPreview(_ ctx: inout GraphicsContext, _ vp: MatViewport) {
        if let (a, b) = knifeLine {
            var line = Path()
            line.move(to: vp.view(a))
            line.addLine(to: vp.view(b))
            ctx.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
        }
        if !eraserStroke.isEmpty {
            var stroke = Path()
            stroke.addLines(eraserStroke.map(vp.view))
            ctx.stroke(stroke, with: .color(.gray.opacity(0.35)),
                       style: StrokeStyle(lineWidth: max(eraserRadius * 2 * vp.pxPerMM, 2), lineCap: .round, lineJoin: .round))
        }
        let ink = Color.accentColor
        if freehand.count > 1 {
            var p = Path()
            p.addLines(freehand.map(vp.view))
            ctx.stroke(p, with: .color(ink), lineWidth: 1.5)
        }
        guard tool == .curve, !pen.anchors.isEmpty else { return }
        let curve = Path(pen.path(closed: false)).applying(vp.matToView)
        ctx.stroke(curve, with: .color(ink), lineWidth: 1.5)
        // Rubber line to the mouse
        if !penDragging, let hover, let last = pen.anchors.last {
            var next = PenCurve(anchors: [last, PenCurve.Anchor(point: vp.mat(hover))])
            next.anchors[1].handle = .zero
            ctx.stroke(Path(next.path(closed: false)).applying(vp.matToView), with: .color(ink.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        let r: CGFloat = 3.5
        for (i, a) in pen.anchors.enumerated() {
            let c = vp.view(a.point)
            if a.handle != .zero {
                let hOut = vp.view(CGPoint(x: a.point.x + a.handle.x, y: a.point.y + a.handle.y))
                let hIn = vp.view(CGPoint(x: a.point.x - a.handle.x, y: a.point.y - a.handle.y))
                var stem = Path()
                stem.move(to: hIn); stem.addLine(to: hOut)
                ctx.stroke(stem, with: .color(ink.opacity(0.6)), lineWidth: 0.8)
                for h in [hIn, hOut] {
                    ctx.fill(Path(ellipseIn: CGRect(x: h.x - 2.5, y: h.y - 2.5, width: 5, height: 5)), with: .color(ink))
                }
            }
            let box = Path(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            // The first point gets bigger under the mouse: a click closes the curve
            let closing = i == 0 && pen.anchors.count >= 2 && hover.map { $0.distance(to: c) <= Self.handleRadius + 3 } == true
            let shown = closing ? Path(CGRect(x: c.x - r - 2, y: c.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)) : box
            ctx.fill(shown, with: .color(i == 0 ? ink : .white))
            ctx.stroke(shown, with: .color(ink), lineWidth: 1.2)
        }
    }

    /// Selection frame; with `handles`, also the scale and rotate handles
    /// (only shown when exactly one object is selected).
    private func drawSelection(_ shape: CutShape, handles: Bool, _ ctx: inout GraphicsContext, _ vp: MatViewport) {
        let corners = shape.matCorners.map(vp.view)
        var frame = Path()
        frame.addLines(corners)
        frame.closeSubpath()
        ctx.stroke(frame, with: .color(shape.isLocked ? .gray : .accentColor), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
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
                if tool != .select {
                    toolDragChanged(value, vp)
                    return
                }
                if drag == nil { beginDrag(at: value.startLocation, vp) }
                continueDrag(to: value.location, vp)
            }
            .onEnded { value in
                if tool != .select {
                    toolDragEnded(value, vp)
                    return
                }
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
           let shape = document.data.shapes.first(where: { $0.id == id }), !shape.isLocked {
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
        //    (locked objects are ignored; a click takes the whole group)
        if let shape = topmostUnlocked(at: matPoint, vp) {
            let members = document.data.expandedToGroups([shape.id])
            if extend {
                // Shift/command click adds or removes one object (or group)
                if selection.contains(shape.id) {
                    selection.subtract(members)
                    drag = DragState(kind: .none, before: before, startMat: matPoint)
                    return
                }
                selection.formUnion(members)
            } else if !selection.contains(shape.id) {
                selection = members
            }
            let starts = Dictionary(document.data.shapes
                .filter { selection.contains($0.id) && !$0.isLocked }.map { ($0.id, $0.position) },
                uniquingKeysWith: { first, _ in first })
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
            let hits = document.data.shapes.filter { !$0.isLocked && $0.matBounds.intersects(rect) }.map(\.id)
            selection = base.union(document.data.expandedToGroups(Set(hits)))
        case .none:
            return
        }
    }

    // MARK: - Drawing tools

    private func toolDragChanged(_ value: DragGesture.Value, _ vp: MatViewport) {
        let start = vp.mat(value.startLocation), now = vp.mat(value.location)
        switch tool {
        case .select, .text:
            return
        case .points:
            focused = true
            if pointDrag == nil, let target = pointTarget,
               let ref = target.point(near: start, radius: pointRadius(vp)) {
                pointDrag = PointDrag(id: target.id, ref: ref, before: document.data)
            }
            guard let d = pointDrag, let i = document.data.shapes.firstIndex(where: { $0.id == d.id }) else { return }
            document.data.shapes[i].movePoint(d.ref, toMat: now)
        case .knife:
            focused = true
            var end = now
            if NSEvent.modifierFlags.contains(.shift) { // only horizontal or vertical
                if abs(now.x - start.x) > abs(now.y - start.y) { end.y = start.y } else { end.x = start.x }
            }
            knifeLine = (start, end)
        case .eraser:
            if eraserStroke.isEmpty {
                focused = true
                eraserStroke = [start]
            }
            if let last = eraserStroke.last, last.distance(to: now) >= 1 / vp.pxPerMM {
                eraserStroke.append(now)
            }
        case .freehand:
            if freehand.isEmpty {
                focused = true
                freehand = [start]
            }
            // Skip points closer than about one screen pixel
            if let last = freehand.last, last.distance(to: now) >= 1 / vp.pxPerMM {
                freehand.append(now)
            }
        case .curve:
            if !penDragging {
                focused = true
                penDragging = true
                pen.anchors.append(PenCurve.Anchor(point: start))
            }
            // Dragging pulls out the handles: a round point
            guard let i = pen.anchors.indices.last else { return }
            let d = CGPoint(x: now.x - start.x, y: now.y - start.y)
            pen.anchors[i].handle = hypot(d.x, d.y) * vp.pxPerMM >= 3 ? d : .zero
        }
    }

    private func toolDragEnded(_ value: DragGesture.Value, _ vp: MatViewport) {
        let start = vp.mat(value.startLocation)
        switch tool {
        case .select:
            return
        case .points:
            if let d = pointDrag {
                pointDrag = nil
                document.commitChange(from: d.before, actionName: String(localized: "Move point"), undoManager: undoManager)
            } else if vp.view(start).distance(to: value.location) < 4 {
                // A click picks the object whose points are edited
                if let shape = topmostUnlocked(at: start, vp) { selection = [shape.id] }
            }
        case .knife:
            guard let (a, b) = knifeLine else { return }
            knifeLine = nil
            let pieces = document.knife(from: a, to: b, selection: document.data.unlocked(selection), undoManager: undoManager)
            if !pieces.isEmpty { selection = pieces }
        case .eraser:
            let stroke = eraserStroke
            eraserStroke = []
            let changed = document.erase(along: stroke, radius: CGFloat(eraserRadius),
                                         selection: document.data.unlocked(selection), undoManager: undoManager)
            if !changed.isEmpty, !selection.isEmpty { selection = changed }
        case .text:
            focused = true
            guard let shape = CutShape.text(FontCatalog.defaultSpec(), at: start) else { return }
            add(shape, actionName: String(localized: "Add text"))
            tool = .select
            onEditText(shape.id)
        case .freehand:
            let points = freehand
            freehand = []
            let px = 1 / vp.pxPerMM
            guard let line = FreehandBuilder.polyline(from: points, tolerance: 1.2 * px, closeDistance: 10 * px)
            else { return }
            add(.drawn(line, name: String(localized: "Freehand")), actionName: String(localized: "Draw"))
        case .curve:
            penDragging = false
            let count = pen.anchors.count
            guard count >= 2 else { return }
            let new = pen.anchors[count - 1]
            let hit = (Self.handleRadius + 3) / vp.pxPerMM
            // Click on the first point: close the curve
            if count >= 3, new.point.distance(to: pen.anchors[0].point) <= hit {
                pen.anchors.removeLast()
                if new.handle != .zero { pen.anchors[0].handle = new.handle }
                finishPen(closed: true)
            // Click on the last point again (double-click): end the curve
            } else if new.point.distance(to: pen.anchors[count - 2].point) <= hit {
                pen.anchors.removeLast()
                if new.handle != .zero { pen.anchors[count - 2].handle = new.handle }
                if new.handle == .zero { finishPen(closed: false) }
            }
        }
    }

    private func finishPen(closed: Bool) {
        let curve = pen
        pen = PenCurve()
        penDragging = false
        guard let line = curve.polyline(closed: closed) else { return }
        add(.drawn(line, name: String(localized: "Curve")), actionName: String(localized: "Draw"))
    }

    /// Cursor for the current tool (the hand wins while moving the mat).
    private func updateCursor() {
        guard !MatNavigator.handActive else { return }
        switch tool {
        case .select: NSCursor.arrow.set()
        case .text: NSCursor.iBeam.set()
        case .freehand, .curve, .knife, .eraser: NSCursor.crosshair.set()
        case .points: NSCursor.arrow.set()
        }
    }

    // MARK: - Context menu

    /// Objects the context menu works on: the selection if the pointer is
    /// over it, else the object (and its group) under the pointer.
    /// Locked objects count here, so they can be unlocked.
    private func contextTargets(_ vp: MatViewport) -> Set<UUID> {
        guard let hover else { return selection }
        let p = vp.mat(hover)
        guard let shape = document.data.shapes.last(where: { $0.contains(matPoint: p, slop: 4 / vp.pxPerMM) })
        else { return [] }
        if selection.contains(shape.id) { return selection }
        return document.data.expandedToGroups([shape.id])
    }

    @ViewBuilder
    private func contextMenu(_ vp: MatViewport) -> some View {
        let ids = contextTargets(vp)
        let data = document.data
        let targets = data.shapes.filter { ids.contains($0.id) }
        let editable = data.unlocked(ids)
        let um = undoManager
        if tool == .points, let target = pointTarget, let hover,
           let ref = target.point(near: vp.mat(hover), radius: pointRadius(vp)),
           let i = data.shapes.firstIndex(where: { $0.id == target.id }) {
            Button("Split line here") {
                document.update(String(localized: "Split line"), undoManager: um) { $0.shapes[i].splitLine(at: ref) }
            }
            Button("Delete point", role: .destructive) {
                document.update(String(localized: "Delete point"), undoManager: um) { $0.shapes[i].deletePoint(ref) }
            }
            Divider()
        }
        if targets.isEmpty {
            Button("Paste") { onPaste() }
                .disabled(!PasteboardImport.canPaste())
            Divider()
            Button("Select all") { selection = data.unlocked(Set(data.shapes.map(\.id))) }
                .disabled(data.unlocked(Set(data.shapes.map(\.id))).isEmpty)
            if data.shapes.contains(where: \.isLocked) {
                Button("Unlock all") {
                    document.setLocked(false, ids: Set(data.shapes.map(\.id)), undoManager: um)
                }
            }
        } else {
            if targets.count == 1, let t = targets.first, t.text != nil, !t.isLocked {
                Button("Edit text…") { selection = [t.id]; onEditText(t.id) }
                Divider()
            }
            Button("Duplicate") {
                let copies = document.duplicate(ids, undoManager: um)
                if !copies.isEmpty { selection = copies }
            }
            Button("Delete", role: .destructive) {
                selection.subtract(document.delete(ids, undoManager: um))
            }
            .disabled(editable.isEmpty)
            Divider()
            Menu("Cut with") {
                ForEach([1, 2], id: \.self) { slot in
                    Button("\(ToolSlotStyle.title(slot)) · \(data.settings(slot: slot).tool.title)") {
                        document.setToolSlot(slot, ids: ids, undoManager: um)
                    }
                }
            }
            .disabled(editable.isEmpty)
            if data.canGroup(editable) {
                Button("Group") { document.group(ids, undoManager: um); selection = ids }
            }
            if data.canUngroup(editable) {
                Button("Ungroup") { document.ungroup(ids, undoManager: um); selection = ids }
            }
            if !editable.isEmpty {
                Button("Lock") {
                    document.setLocked(true, ids: ids, undoManager: um)
                    selection.subtract(ids)
                }
            }
            if editable.count < ids.count {
                Button("Unlock") { document.setLocked(false, ids: ids, undoManager: um); selection = ids }
            }
            if !editable.isEmpty {
                Divider()
                let allCut = targets.filter { !$0.isLocked }.allSatisfy(\.cutEnabled)
                Button(allCut ? "Turn cutting off" : "Turn cutting on") {
                    document.setCutEnabled(!allCut, ids: ids, undoManager: um)
                }
                Button("Bring to front") { document.reorder(editable, toFront: true, undoManager: um) }
                Button("Send to back") { document.reorder(editable, toFront: false, undoManager: um) }
            }
        }
    }

    /// Topmost object under the point that is not locked.
    private func topmostUnlocked(at matPoint: CGPoint, _ vp: MatViewport) -> CutShape? {
        document.data.shapes.last { !$0.isLocked && $0.contains(matPoint: matPoint, slop: 4 / vp.pxPerMM) }
    }

    private func add(_ shape: CutShape, actionName: String) {
        document.update(actionName, undoManager: undoManager) { $0.shapes.append(shape) }
        selection = [shape.id]
        onCreated()
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
        let ids = document.data.unlocked(selection)
        guard !ids.isEmpty else { return .ignored }
        document.update(String(localized: "Move"), undoManager: undoManager) { data in
            for i in data.shapes.indices where ids.contains(data.shapes[i].id) {
                data.shapes[i].position.x += dx
                data.shapes[i].position.y += dy
            }
        }
        return .handled
    }

    private func deleteSelection() {
        let ids = document.data.unlocked(selection)
        guard !ids.isEmpty else { return }
        document.update(String(localized: "Delete"), undoManager: undoManager) { data in
            data.shapes.removeAll { ids.contains($0.id) }
        }
        selection.subtract(ids)
    }
}

/// Angle in the range -180…180.
func normalizedDegrees(_ value: Double) -> Double {
    var r = value.truncatingRemainder(dividingBy: 360)
    if r > 180 { r -= 360 }
    if r <= -180 { r += 360 }
    return r
}
