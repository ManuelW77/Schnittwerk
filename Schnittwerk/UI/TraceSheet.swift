// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Window for tracing an image: live preview of the cut lines and the
// settings. Two modes: one outline (black and white), or one layer per
// colour (e.g. for vinyl in several colours).

import SwiftUI

/// An image waiting to be traced.
struct TraceInput: Identifiable {
    let id = UUID()
    let image: CGImage
    let name: String
}

struct TraceSheet: View {
    enum Mode: Hashable { case outline, colors }

    let input: TraceInput
    /// Called with the layers (mm, top left at 0, 0), back to front.
    let onAdd: ([TraceLayer]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .outline
    @State private var settings = TraceSettings()
    @State private var layers: [TraceLayer] = []
    @State private var working = false
    @State private var failed = false
    @State private var showImage = true

    // Colour mode
    @State private var colorCount = 4
    @State private var analysis: ColorAnalysis?
    /// Layer number per colour, nil = left out.
    @State private var layerOf: [Int?] = []
    @State private var addOutline = false

    private let transparent: Bool

    init(input: TraceInput, onAdd: @escaping ([TraceLayer]) -> Void) {
        self.input = input
        self.onAdd = onAdd
        transparent = ImageTracer.hasTransparency(input.image)
        var s = TraceSettings()
        s.useTransparency = transparent
        // Fit into 100 × 100 mm
        let aspect = Double(input.image.width) / Double(max(input.image.height, 1))
        s.widthMM = aspect >= 1 ? 100 : (100 * aspect).rounded()
        _settings = State(initialValue: s)
    }

    private var heightMM: Double { ImageTracer.heightMM(for: input.image, widthMM: settings.widthMM) }

    /// Everything the preview depends on; a change traces again.
    private struct TraceKey: Equatable {
        var mode: Mode, settings: TraceSettings, layerOf: [Int?], outline: Bool, analysed: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Trace image").font(.headline)
                Spacer()
                Picker("Mode", selection: $mode) {
                    Text("Outline").tag(Mode.outline)
                    Text("Colours").tag(Mode.colors)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .tip("Outline: one cut line around the motif. Colours: one layer per colour, e.g. for vinyl in several colours.")
            }
            HStack(alignment: .top, spacing: 18) {
                preview
                    .frame(width: 440, height: 420)
                    .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                controls
                    .frame(width: 300, height: 420)
            }
            HStack {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(failed ? .red : .secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to mat") {
                    onAdd(layers)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(layers.isEmpty || working)
            }
        }
        .padding(20)
        .task(id: colorCount) { if mode == .colors { await analyse() } }
        .task(id: mode) { if mode == .colors && analysis == nil { await analyse() } }
        .task(id: TraceKey(mode: mode, settings: settings, layerOf: layerOf, outline: addOutline,
                           analysed: analysis != nil)) { await retrace() }
    }

    private var statusText: String {
        if failed { return String(localized: "The image could not be traced.") }
        if working && layers.isEmpty { return String(localized: "Tracing …") }
        if layers.isEmpty { return String(localized: "No outlines found. Try another threshold or Invert.") }
        let count = layers.reduce(0) { $0 + $1.lines.count }
        if mode == .colors {
            return String(localized: "\(layers.count) layers, \(count) cut lines")
        }
        return String(localized: "\(count) cut lines")
    }

    // MARK: - Preview

    private var preview: some View {
        Canvas { ctx, size in
            let w = settings.widthMM, h = heightMM
            guard w > 0, h > 0 else { return }
            let scale = min((size.width - 24) / w, (size.height - 24) / h)
            let box = CGRect(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2,
                             width: w * scale, height: h * scale)
            if showImage {
                var c = ctx
                c.opacity = mode == .colors ? 0.2 : 0.35
                c.draw(Image(decorative: input.image, scale: 1), in: box)
            }
            let t = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: scale, y: scale)
            for layer in layers {
                let shown = path(layer.lines).applying(t)
                if let rgb = layer.color {
                    let color = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
                    ctx.fill(shown, with: .color(color.opacity(0.85)), style: FillStyle(eoFill: true))
                    ctx.stroke(shown, with: .color(.black.opacity(0.6)), lineWidth: 0.6)
                } else {
                    ctx.fill(shown, with: .color(.red.opacity(0.12)), style: FillStyle(eoFill: true))
                    ctx.stroke(shown, with: .color(.red), lineWidth: 1)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if working { ProgressView().controlSize(.small).padding(8) }
        }
    }

    private func path(_ lines: [Polyline]) -> Path {
        var p = Path()
        for line in lines {
            guard let first = line.points.first else { continue }
            p.move(to: first)
            for pt in line.points.dropFirst() { p.addLine(to: pt) }
            if line.closed { p.closeSubpath() }
        }
        return p
    }

    // MARK: - Settings

    private var controls: some View {
        Form {
            if mode == .outline {
                outlineSection
            } else {
                colorSection
            }
            Section {
                LabeledContent("Smoothing") {
                    Slider(value: $settings.smoothing, in: 0...1)
                }
                .tip("Left: follow the pixels. Right: rounder lines. Sharp corners stay.")
                LabeledContent("Remove specks") {
                    Slider(value: $settings.minSizeMM, in: 0...10)
                }
                .tip("Outlines smaller than \(settings.minSizeMM.formatted(.number.precision(.fractionLength(1)))) mm are left out")
                Toggle("Show image", isOn: $showImage)
            }
            Section {
                LengthField("Width", mm: Binding(
                    get: { settings.widthMM },
                    set: { v in if v.isFinite, v >= 1 { settings.widthMM = min(v, 3000) } }
                ))
                LabeledContent("Height") {
                    Text(verbatim: LengthUnit.current.text(heightMM))
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var outlineSection: some View {
        Section {
            if transparent {
                Picker("Detect by", selection: $settings.useTransparency) {
                    Text("Transparency").tag(true)
                    Text("Brightness").tag(false)
                }
                .tip("The image has see-through parts. Transparency usually works best for logos.")
            }
            LabeledContent("Threshold") {
                Slider(value: $settings.threshold, in: 0.05...0.95)
            }
            .disabled(settings.useTransparency)
            .tip("Which brightness counts as part of the motif")
            Toggle("Invert", isOn: $settings.invert)
                .tip("Trace the light parts instead of the dark ones")
        }
    }

    @ViewBuilder
    private var colorSection: some View {
        Section {
            Stepper(value: $colorCount, in: ColorTracer.colorRange) {
                LabeledContent("Colours", value: "\(colorCount)")
            }
            .tip("How many colours the image is reduced to")
            Toggle("Outline as base layer", isOn: $addOutline)
                .tip("Adds the outline of the whole motif, e.g. as a base for layered vinyl")
        }
        Section {
            if let analysis {
                ForEach(analysis.colors.indices, id: \.self) { c in
                    colorRow(c, analysis)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } header: {
            Text("Colours found")
        } footer: {
            Text("Give colours the same layer number to cut them as one piece.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func colorRow(_ c: Int, _ a: ColorAnalysis) -> some View {
        let rgb = a.colors[c]
        return HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: rgb.hex).font(.callout.monospaced())
                Text(c == a.background ? String(localized: "Background")
                                       : a.shares[c].formatted(.percent.precision(.fractionLength(1))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Layer", selection: Binding(
                get: { c < layerOf.count ? layerOf[c] : nil },
                set: { v in if c < layerOf.count { layerOf[c] = v } }
            )) {
                Text("Leave out").tag(Int?.none)
                ForEach(a.colors.indices, id: \.self) { n in
                    Text("Layer \(n + 1)").tag(Int?.some(n))
                }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }

    // MARK: - Work

    private func analyse() async {
        working = true
        let image = UncheckedImage(image: input.image), count = colorCount
        let result = await Task.detached(priority: .userInitiated) {
            ColorTracer.analyze(image.image, colorCount: count)
        }.value
        guard !Task.isCancelled else { return }
        analysis = result
        // Each colour its own layer; the background is left out
        layerOf = result.map { a in a.colors.indices.map { $0 == a.background ? nil : $0 } } ?? []
        failed = result == nil
        working = false
    }

    private func retrace() async {
        // Wait a moment while sliders are being dragged
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let current = settings, image = UncheckedImage(image: input.image)
        let result: [TraceLayer]?
        switch mode {
        case .outline:
            working = true
            let name = input.name
            result = await Task.detached(priority: .userInitiated) {
                (try? ImageTracer.trace(image.image, settings: current)).map {
                    [TraceLayer(id: 0, name: name, color: nil, lines: $0)]
                }
            }.value
        case .colors:
            guard let analysis else { layers = []; return }
            working = true
            let map = layerOf, outline = addOutline
            result = await Task.detached(priority: .userInitiated) {
                try? ColorTracer.layers(analysis, layerOf: map, outline: outline, settings: current)
            }.value
        }
        guard !Task.isCancelled else { return }
        failed = result == nil
        // Big areas first, so small details lie on top
        layers = (result ?? []).sorted { a, b in
            if a.id == -1 || b.id == -1 { return a.id == -1 }
            return area(a) > area(b)
        }
        working = false
    }

    /// Covered area (sum of the outlines' areas).
    private func area(_ layer: TraceLayer) -> Double {
        layer.lines.reduce(0) { sum, line in
            let p = line.points
            guard p.count >= 3 else { return sum }
            var a: Double = 0
            for i in p.indices {
                let q = p[(i + 1) % p.count]
                a += Double(p[i].x * q.y - q.x * p[i].y)
            }
            return sum + abs(a) / 2
        }
    }
}

/// CGImage is immutable, so it is safe to hand to the tracing task.
private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
}
