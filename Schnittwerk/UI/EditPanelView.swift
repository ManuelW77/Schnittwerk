// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// "Edit" panel of the inspector: transform, replicate, modify, offset,
// fill patterns and stippling for the selected objects.

import SwiftUI

struct EditPanelView: View {
    @ObservedObject var document: CutDocument
    @Binding var selection: Set<UUID>
    @Environment(\.undoManager) private var undoManager

    @AppStorage("edit.moveDistance") private var moveDistance = 5.0
    @AppStorage("edit.scalePercent") private var scalePercent = 100.0
    @AppStorage("edit.rotateDegrees") private var rotateDegrees = 15.0
    @AppStorage("edit.gap") private var gap = 2.0
    @AppStorage("edit.rows") private var rows = 2
    @AppStorage("edit.columns") private var columns = 2
    @AppStorage("offset.distance") private var offsetDistance = 3.0
    @AppStorage("offset.roundCorners") private var offsetRound = true
    @AppStorage("fill.pattern") private var fillPattern: String = FillPattern.lines.rawValue
    @AppStorage("fill.spacing") private var fillSpacing = 2.0
    @AppStorage("fill.angle") private var fillAngle = 45.0
    @AppStorage("stipple.mode") private var stippleMode: String = StippleMode.outline.rawValue
    @AppStorage("stipple.spacing") private var stippleSpacing = 2.5
    @AppStorage("stipple.replace") private var stippleReplace = false
    @State private var failure: String?
    @AppStorage("edit.open.transform") private var openTransform = true
    @AppStorage("edit.open.replicate") private var openReplicate = true
    @AppStorage("edit.open.modify") private var openModify = true
    @AppStorage("edit.open.offset") private var openOffset = false
    @AppStorage("edit.open.fill") private var openFill = false
    @AppStorage("edit.open.stipple") private var openStipple = false
    @AppStorage("edit.open.weed") private var openWeed = true
    @AppStorage("weed.margin") private var weedMargin = 4.0
    @AppStorage("weed.horizontal") private var weedHorizontal = 1
    @AppStorage("weed.vertical") private var weedVertical = 1

    private var editable: Set<UUID> { document.data.unlocked(selection) }
    private var hasSelection: Bool { !editable.isEmpty }

    private let mm = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))

    var body: some View {
        Form {
            if !hasSelection {
                Section {
                    Label("Select one or more objects to edit them.", systemImage: "cursorarrow.click")
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                transformSection
                replicateSection
                modifySection
                weedSection
                offsetSection
                fillSection
                stippleSection
            }
            .disabled(!hasSelection)
        }
        .formStyle(.grouped)
        .alert("Nothing changed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: failure ?? "")
        }
    }

    private func select(_ ids: Set<UUID>, orFail text: String) {
        if ids.isEmpty { failure = text } else { selection = ids }
    }

    // MARK: Transform

    private var transformSection: some View {
        Section("Transform", isExpanded: $openTransform) {
            LabeledContent("Scale") {
                HStack(spacing: 4) {
                    ForEach([33.0, 50.0, 200.0, 300.0], id: \.self) { p in
                        Button("\(Int(p)) %") { document.scale(editable, percent: p, undoManager: undoManager) }
                    }
                }
                .controlSize(.small)
            }
            HStack {
                TextField("Scale (%)", value: $scalePercent, format: .number.precision(.fractionLength(0...1)))
                Button("Apply") { document.scale(editable, percent: scalePercent, undoManager: undoManager) }
                    .disabled(!(scalePercent > 0) || scalePercent == 100)
            }

            LabeledContent("Move by") {
                HStack(spacing: 4) {
                    ForEach(ReplicateDirection.allCases) { d in
                        Button {
                            let v = d.step
                            document.move(editable, dx: v.dx * moveDistance, dy: v.dy * moveDistance, undoManager: undoManager)
                        } label: { Label(d.title, systemImage: d.systemImage) }
                            .help(d.title)
                    }
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
            }
            TextField("Distance (mm)", value: $moveDistance, format: mm)

            LabeledContent("Rotate by") {
                HStack(spacing: 4) {
                    ForEach([-90.0, -45.0, 45.0, 90.0, 180.0], id: \.self) { a in
                        Button(a > 0 ? "+\(Int(a))°" : "\(Int(a))°") {
                            document.rotate(editable, by: a, undoManager: undoManager)
                        }
                    }
                }
                .controlSize(.small)
            }
            HStack {
                TextField("Angle (°)", value: $rotateDegrees, format: .number.precision(.fractionLength(0...1)))
                Button("Rotate") { document.rotate(editable, by: rotateDegrees, undoManager: undoManager) }
            }
            LabeledContent("Mirror") {
                HStack(spacing: 4) {
                    Button { document.mirror(editable, horizontally: true, undoManager: undoManager) } label: {
                        Label("Mirror horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Button { document.mirror(editable, horizontally: false, undoManager: undoManager) } label: {
                        Label("Mirror vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
            }
            .help("Mirror, e.g. for heat transfer vinyl")
        }
    }

    // MARK: Replicate

    private var replicateSection: some View {
        Section("Replicate", isExpanded: $openReplicate) {
            LabeledContent("Duplicate") {
                directionButtons { d in
                    select(document.duplicate(selection, toward: d, gap: CGFloat(gap), undoManager: undoManager),
                           orFail: String(localized: "Nothing to copy."))
                }
            }
            LabeledContent("Mirror copy") {
                directionButtons { d in
                    select(document.mirrorCopy(selection, toward: d, undoManager: undoManager),
                           orFail: String(localized: "Nothing to copy."))
                }
            }
            TextField("Gap (mm)", value: $gap, format: mm)
            HStack {
                Stepper("Rows: \(rows)", value: $rows, in: 1...50)
                Stepper("Columns: \(columns)", value: $columns, in: 1...50)
            }
            Button {
                select(document.replicateGrid(selection, rows: rows, columns: columns, gap: CGFloat(gap), undoManager: undoManager),
                       orFail: String(localized: "Choose more than one row or column."))
            } label: {
                Label("Rows and columns", systemImage: "square.grid.3x2").frame(maxWidth: .infinity)
            }
            HStack {
                Button {
                    select(document.fillMat(selection, gap: CGFloat(gap), undoManager: undoManager),
                           orFail: String(localized: "The objects are too large to fill the mat."))
                } label: { Label("Fill mat", systemImage: "square.grid.4x3.fill").frame(maxWidth: .infinity) }
                    .help("As many copies as fit onto the mat")
            }
            LabeledContent("Rotate copies") {
                HStack(spacing: 4) {
                    ForEach([2, 4, 6, 8, 12], id: \.self) { n in
                        Button("\(n)×") {
                            select(document.rotateCopies(selection, count: n, undoManager: undoManager),
                                   orFail: String(localized: "Nothing to copy."))
                        }
                    }
                }
                .controlSize(.small)
            }
            .help("Copies turned evenly in a ring, e.g. for flowers and mandalas")
        }
    }

    private func directionButtons(_ action: @escaping (ReplicateDirection) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(ReplicateDirection.allCases) { d in
                Button { action(d) } label: { Label(d.title, systemImage: d.systemImage) }
                    .help(d.title)
            }
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
    }

    // MARK: Modify

    private var modifySection: some View {
        Section("Modify", isExpanded: $openModify) {
            let count = editable.count
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                ForEach(PathOperation.allCases) { op in
                    Button { combine(op) } label: { Label(op.title, systemImage: op.systemImage).frame(maxWidth: .infinity, alignment: .leading) }
                        .help(op.help)
                        .disabled(count < 2)
                }
                ForEach(ModifyOperation.allCases) { op in
                    Button { modify(op) } label: { Label(op.title, systemImage: op.systemImage).frame(maxWidth: .infinity, alignment: .leading) }
                        .help(op.help)
                        .disabled(count < op.minimumCount)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if count < 2 {
                Text("Most of these need two or more objects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func combine(_ op: PathOperation) {
        if let id = document.combine(op, ids: editable, undoManager: undoManager) {
            selection = [id]
        } else {
            failure = String(localized: "The result would be empty. Check that the objects overlap.")
        }
    }

    private func modify(_ op: ModifyOperation) {
        select(document.modify(op, ids: editable, undoManager: undoManager),
               orFail: op == .releaseCompound
                   ? String(localized: "The object has only one outline.")
                   : String(localized: "The result would be empty. Check that the objects overlap."))
    }

    // MARK: Weeding

    private var weedSection: some View {
        Section("Weeding lines", isExpanded: $openWeed) {
            TextField("Box margin (mm)", value: $weedMargin, format: mm)
            HStack {
                Stepper("Across: \(weedHorizontal)", value: $weedHorizontal, in: 0...20)
                Stepper("Down: \(weedVertical)", value: $weedVertical, in: 0...20)
            }
            Button {
                if let id = document.addWeedingLines(ids: selection, margin: CGFloat(max(weedMargin, 0)),
                                                     horizontal: weedHorizontal, vertical: weedVertical,
                                                     undoManager: undoManager) {
                    selection = [id]
                } else {
                    failure = String(localized: "Nothing to copy.")
                }
            } label: { Label("Add weeding lines", systemImage: "square.dashed").frame(maxWidth: .infinity) }
            Text("A box around the motif and lines through the free space, so the waste vinyl comes off in small pieces.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Offset

    private var offsetSection: some View {
        Section("Offset", isExpanded: $openOffset) {
            TextField("Distance (mm)", value: $offsetDistance, format: mm)
            Picker("Corners", selection: $offsetRound) {
                Text("Round").tag(true)
                Text("Sharp").tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                Button { addOffset(inner: false) } label: { Label("Offset", systemImage: "circle.dashed") }
                    .help("Add an outline at this distance, e.g. for stickers")
                Button { addOffset(inner: true) } label: { Label("Inner offset", systemImage: "circle.dashed.inset.filled") }
                    .help("Add an outline at this distance inside the object")
            }
            .disabled(!offsetDistance.isFinite || abs(offsetDistance) < 0.01)
        }
    }

    private func addOffset(inner: Bool) {
        let d = CGFloat(min(abs(offsetDistance), 100)) * (inner ? -1 : 1)
        if let id = document.addOffset(ids: selection, distance: d, roundCorners: offsetRound, undoManager: undoManager) {
            selection = [id]
        } else {
            failure = String(localized: "The object is too small for this inner offset.")
        }
    }

    // MARK: Fill and stipple

    private var fillSection: some View {
        Section(isExpanded: $openFill) {
            Picker("Pattern", selection: $fillPattern) {
                ForEach(FillPattern.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0.rawValue) }
            }
            TextField("Spacing (mm)", value: $fillSpacing, format: mm)
            if fillPattern != FillPattern.concentric.rawValue {
                TextField("Angle (°)", value: $fillAngle, format: .number.precision(.fractionLength(0...1)))
            }
            Button {
                let pattern = FillPattern(rawValue: fillPattern) ?? .lines
                if let id = document.addFill(ids: selection, pattern: pattern, spacing: CGFloat(max(fillSpacing, 0.2)),
                                             angle: fillAngle, undoManager: undoManager) {
                    selection = [id]
                } else {
                    failure = String(localized: "Only closed outlines can be filled.")
                }
            } label: { Label("Add fill", systemImage: "line.3.horizontal.decrease") }
            Text("Lines inside the object, for the pen or the embossing tool. Choose that tool for the fill in the Object panel.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Sketch and emboss fill")
        }
    }

    private var stippleSection: some View {
        Section(isExpanded: $openStipple) {
            Picker("Dots", selection: $stippleMode) {
                ForEach(StippleMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            TextField("Spacing (mm)", value: $stippleSpacing, format: mm)
            Toggle("Replace the object", isOn: $stippleReplace)
            Button {
                let mode = StippleMode(rawValue: stippleMode) ?? .outline
                if let id = document.addStipple(ids: selection, mode: mode, spacing: CGFloat(max(stippleSpacing, 0.5)),
                                                replace: stippleReplace, undoManager: undoManager) {
                    selection = [id]
                } else {
                    failure = String(localized: "No dots fit with this spacing.")
                }
            } label: { Label("Stipple", systemImage: "circle.dotted") }
            Text("Small dots along or inside the object. The punch tool pierces each dot; a pen draws small circles.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Stippling (punch tool)")
        }
    }
}
