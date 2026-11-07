// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Right side panel: position, size, rotation and text of the selected object.
struct InspectorView: View {
    @ObservedObject var document: CutDocument
    @Binding var selection: Set<UUID>

    @Environment(\.undoManager) private var undoManager
    @AppStorage("inspector.lockAspect") private var lockAspect = true

    /// Number of locked objects in the selection, nil if none.
    private var lockedInSelection: Int? {
        let n = document.data.shapes.filter { selection.contains($0.id) && $0.isLocked }.count
        return n > 0 ? n : nil
    }

    /// The one selected object; nil with none or several selected.
    private var selectedID: UUID? { selection.count == 1 ? selection.first : nil }

    private var index: Int? {
        guard let selectedID else { return nil }
        return document.data.shapes.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        Form {
            if let locked = lockedInSelection {
                Section {
                    Label(locked == 1 && selection.count == 1 ? "This object is locked." : "\(locked) locked objects selected.",
                          systemImage: "lock.fill")
                    Button("Unlock") {
                        let ids = selection
                        document.update(String(localized: "Unlock"), undoManager: undoManager) {
                            $0.setLocked(false, ids: ids)
                        }
                    }
                }
            } else if let index {
                objectSection(index)
                if document.data.shapes[index].text != nil {
                    textSection(index)
                }
                if let spec = document.data.shapes[index].effectiveShapeSpec {
                    shapeSection(spec)
                }
                alignSection
            } else if selection.count > 1 {
                Section {
                    Text("\(selection.count) objects selected")
                    toolPicker
                }
                alignSection
                Section {
                    Text("Transform, replicate, combine and offset in the Edit panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("Select an object on the mat, or import a file.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)

    }

    // MARK: - Align

    private var alignSection: some View {
        Section(selection.count == 1 ? "Align on mat" : "Align") {
            HStack {
                ForEach(AlignEdge.allCases) { edge in
                    Button { document.align(edge, ids: selection, undoManager: undoManager) } label: {
                        Label(edge.title, systemImage: edge.systemImage)
                    }
                    .help(edge.title)
                }
            }
            .labelStyle(.iconOnly)
            if selection.count > 1 {
                HStack {
                    ForEach(DistributeAxis.allCases) { axis in
                        Button { document.distribute(axis, ids: selection, undoManager: undoManager) } label: {
                            Label(axis.title, systemImage: axis.systemImage)
                        }
                        .help(axis.title)
                        .disabled(selection.count < 3)
                    }
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    // MARK: - Tool

    /// Tool 1 or 2 of the selection; nil if mixed.
    private var toolPicker: some View {
        let slots = Set(document.data.shapes.filter { selection.contains($0.id) }.map(\.toolSlot))
        return ToolSlotPicker(current: slots.count == 1 ? slots.first : nil, data: document.data) { slot in
            document.setToolSlot(slot, ids: selection, undoManager: undoManager)
        }
    }

    // MARK: - Changes

    private func change(_ action: String, _ body: @escaping (inout CutShape) -> Void) {
        guard let id = selectedID else { return }
        document.update(action, undoManager: undoManager) { data in
            guard let i = data.shapes.firstIndex(where: { $0.id == id }) else { return }
            body(&data.shapes[i])
        }
    }

    private func value(_ get: @escaping (CutShape) -> Double, action: String,
                       set: @escaping (inout CutShape, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { index.map { get(document.data.shapes[$0]) } ?? 0 },
            set: { newValue in
                guard newValue.isFinite else { return }
                change(action) { set(&$0, newValue) }
            }
        )
    }

    // MARK: - Object

    @ViewBuilder
    private func objectSection(_ i: Int) -> some View {
        let shape = document.data.shapes[i]
        let mm = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))

        Section("Object") {
            TextField("Name", text: Binding(
                get: { shape.name },
                set: { name in change(String(localized: "Rename")) { $0.name = name } }
            ))
            Toggle("Cut this object", isOn: Binding(
                get: { shape.cutEnabled },
                set: { on in change(String(localized: "Cut on/off")) { $0.cutEnabled = on } }
            ))
            toolPicker
            if !shape.fits(in: document.data.mat.size) {
                Label("Sticks out over the cutting area; that part is not cut", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }

        Section("Position (mm, top left)") {
            TextField("X", value: value({ Double($0.matBounds.minX) }, action: String(localized: "Move")) { s, v in
                s.position.x += CGFloat(v) - s.matBounds.minX
            }, format: mm)
            TextField("Y", value: value({ Double($0.matBounds.minY) }, action: String(localized: "Move")) { s, v in
                s.position.y += CGFloat(v) - s.matBounds.minY
            }, format: mm)
            Button("Center on mat") {
                let mat = document.data.mat.displaySize
                change(String(localized: "Center on mat")) { s in
                    let b = s.matBounds
                    s.position.x += mat.width / 2 - b.midX
                    s.position.y += mat.height / 2 - b.midY
                }
            }
        }

        Section("Size (mm)") {
            TextField("Width", value: value({ Double($0.size.width) }, action: String(localized: "Resize")) { s, v in
                resize(&s, width: v, height: nil)
            }, format: mm)
            TextField("Height", value: value({ Double($0.size.height) }, action: String(localized: "Resize")) { s, v in
                resize(&s, width: nil, height: v)
            }, format: mm)
            Toggle("Keep proportions", isOn: $lockAspect)
        }

        Section("Rotate and mirror") {
            TextField("Angle (°)", value: value({ $0.rotation }, action: String(localized: "Rotate")) { s, v in
                s.rotation = normalizedDegrees(v)
            }, format: .number.precision(.fractionLength(0...1)))
            HStack {
                Button { change(String(localized: "Rotate")) { $0.rotation = normalizedDegrees($0.rotation - 90) } } label: {
                    Label("−90°", systemImage: "rotate.left")
                }
                Button { change(String(localized: "Rotate")) { $0.rotation = normalizedDegrees($0.rotation + 90) } } label: {
                    Label("+90°", systemImage: "rotate.right")
                }
            }
            HStack {
                Button { change(String(localized: "Mirror")) { $0.scaleX = -$0.scaleX } } label: {
                    Label("Mirror horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                Button { change(String(localized: "Mirror")) { $0.scaleY = -$0.scaleY } } label: {
                    Label("Mirror vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
            }
            .labelStyle(.iconOnly)
            .help("Mirror, e.g. for heat transfer vinyl")
        }
    }

    private func resize(_ s: inout CutShape, width: Double?, height: Double?) {
        s.resize(width: width, height: height, keepProportions: lockAspect)
    }

    // MARK: - Basic shape

    @ViewBuilder
    private func shapeSection(_ spec: ShapeSpec) -> some View {
        let mm = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        Section(spec.kind.title) {
            switch spec.kind {
            case .rectangle:
                TextField("Corner radius (mm)", value: Binding(
                    get: { spec.cornerRadiusMM },
                    set: { v in guard v.isFinite else { return }; updateShape { $0.cornerRadiusMM = v } }
                ), format: mm)
            case .ellipse:
                Button("Make it a circle") {
                    updateShape { s in
                        let d = max(s.widthMM, s.heightMM)
                        s.widthMM = d
                        s.heightMM = d
                    }
                }
            case .polygon, .star:
                Stepper(value: Binding(
                    get: { spec.sides },
                    set: { n in updateShape { $0.sides = n } }
                ), in: ShapeSpec.sidesRange) {
                    Text(spec.kind == .star ? "Points: \(spec.sides)" : "Corners: \(spec.sides)")
                }
                if spec.kind == .star {
                    // Depth = 1 − inner ratio, so dragging right makes deeper points
                    Slider(value: Binding(
                        get: { 1 - spec.innerRatio },
                        set: { d in updateShape { $0.innerRatio = 1 - d } }
                    ), in: (1 - ShapeSpec.innerRatioRange.upperBound)...(1 - ShapeSpec.innerRatioRange.lowerBound)) {
                        Text("Point depth")
                    } minimumValueLabel: {
                        Text(verbatim: "")
                    } maximumValueLabel: {
                        Text(verbatim: "\(Int((1 - spec.innerRatio) * 100)) %")
                    }
                }
            }
        }
    }

    private func updateShape(_ edit: @escaping (inout ShapeSpec) -> Void) {
        change(String(localized: "Edit shape")) { shape in
            guard var spec = shape.effectiveShapeSpec else { return }
            edit(&spec)
            shape.updateShapeSpec(spec)
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func textSection(_ i: Int) -> some View {
        let spec = document.data.shapes[i].text ?? FontCatalog.defaultSpec()
        let family = FontCatalog.family(ofPostScriptName: spec.fontName) ?? "Helvetica Neue"

        Section("Text") {
            TextField("Text", text: Binding(
                get: { spec.text },
                set: { newText in updateText { $0.text = newText } }
            ), axis: .vertical)
            .lineLimit(1...6)

            Picker("Font", selection: Binding(
                get: { family },
                set: { newFamily in
                    let faces = FontCatalog.faces(of: newFamily)
                    // Keep the style (e.g. Bold) if the new family has it
                    let oldStyle = FontCatalog.faces(of: family).first { $0.postScriptName == spec.fontName }?.styleName
                    let face = faces.first { $0.styleName == oldStyle } ?? faces.first
                    if let face { updateText { $0.fontName = face.postScriptName } }
                }
            )) {
                ForEach(FontCatalog.families, id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }

            Picker("Style", selection: Binding(
                get: { spec.fontName },
                set: { name in updateText { $0.fontName = name } }
            )) {
                ForEach(FontCatalog.faces(of: family)) { face in
                    Text(verbatim: face.styleName).tag(face.postScriptName)
                }
            }

            TextField("Font size (mm)", value: Binding(
                get: { spec.sizeMM },
                set: { size in
                    guard size.isFinite, size > 0 else { return }
                    updateText { $0.sizeMM = min(size, 1000) }
                }
            ), format: .number.precision(.fractionLength(0...1)))
        }
    }

    private func updateText(_ edit: @escaping (inout TextSpec) -> Void) {
        change(String(localized: "Edit text")) { shape in
            guard var spec = shape.text else { return }
            edit(&spec)
            shape.updateText(spec)
        }
    }
}
