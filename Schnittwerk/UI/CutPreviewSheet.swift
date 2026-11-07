// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Cut preview: shows the order of the cut lines and tools before the job
// goes to the plotter, with an estimate of the time. The slider steps
// through the job.

import SwiftUI

struct CutPreviewSheet: View {
    let data: ProjectData
    let model: PlotterModel
    let onCut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var plan: CutPlan
    @State private var shown: Double

    init(data: ProjectData, model: PlotterModel, onCut: @escaping () -> Void) {
        self.data = data
        self.model = model
        self.onCut = onCut
        let plan = CutPlan.make(for: data, model: model)
        _plan = State(initialValue: plan)
        _shown = State(initialValue: Double(plan.steps.count))
    }

    private var duration: String {
        let s = Int(plan.seconds.rounded())
        return s < 60 ? String(localized: "about \(max(s, 1)) s")
            : String(localized: "about \(s / 60) min \(s % 60) s")
    }

    private func mm(_ v: CGFloat) -> String {
        if LengthUnit.current == .inch { return LengthUnit.inch.text(Double(v)) }
        return v >= 1000 ? (Double(v) / 1000).formatted(.number.precision(.fractionLength(2))) + " m"
            : Double(v).formatted(.number.precision(.fractionLength(0))) + " mm"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cut preview").font(.title2.bold())
            HStack(spacing: 22) {
                stat("Lines", "\(plan.steps.count)")
                stat("Cut length", mm(plan.cutLengthMM))
                stat("Travel", mm(plan.travelMM))
                stat("Time", duration)
                if plan.toolChanges > 0 { stat("Tool changes", "\(plan.toolChanges)") }
            }
            canvas
                .frame(minWidth: 520, minHeight: 420)
                .background(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.96),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !plan.steps.isEmpty {
                HStack {
                    Text("Step").foregroundStyle(.secondary)
                    Slider(value: $shown, in: 0...Double(plan.steps.count), step: 1)
                    Text(verbatim: "\(Int(shown)) / \(plan.steps.count)")
                        .monospacedDigit()
                        .frame(minWidth: 70, alignment: .trailing)
                }
                if let step = plan.steps.dropFirst(max(Int(shown) - 1, 0)).first, shown > 0 {
                    HStack(spacing: 6) {
                        ToolSlotBadge(slot: step.slot)
                        Text(verbatim: step.tool.title)
                        if step.pass > 1 { Text("Pass \(step.pass)").foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                }
            }
            Text("Lines inside others are cut first, so the material does not move. Grey dashes show the moves with the tool up. The time is an estimate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    onCut()
                } label: { Label("Cut", systemImage: "scissors") }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.steps.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 640)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline.monospacedDigit())
        }
    }

    private var canvas: some View {
        Canvas { ctx, size in
            // Fit the used part of the mat
            var area = data.mat.displaySize
            let maxY = plan.steps.flatMap(\.points).map(\.y).max() ?? 0
            area.height = min(max(area.height, maxY + 10), data.mat.size.height)
            let scale = min(size.width / area.width, size.height / area.height)
            let ox = (size.width - area.width * scale) / 2, oy = (size.height - area.height * scale) / 2
            func v(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + p.x * scale, y: oy + p.y * scale) }
            ctx.stroke(Path(CGRect(x: ox, y: oy, width: area.width * scale, height: area.height * scale)),
                       with: .color(.secondary.opacity(0.5)), lineWidth: 1)

            let count = Int(shown)
            for (n, step) in plan.steps.enumerated() {
                let done = n < count
                let color = ToolSlotStyle.color(step.slot)
                if done, let start = step.points.first {
                    var travel = Path()
                    travel.move(to: v(step.travelFrom))
                    travel.addLine(to: v(start))
                    ctx.stroke(travel, with: .color(.gray.opacity(0.45)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                }
                var line = Path()
                line.addLines(step.points.map(v))
                if step.tool == .punch, let p = step.points.first {
                    let c = v(p)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)),
                             with: .color(done ? color : color.opacity(0.15)))
                } else {
                    ctx.stroke(line, with: .color(done ? color : color.opacity(0.15)),
                               lineWidth: n == count - 1 ? 2.5 : 1.2)
                }
            }
            // Head position after the shown step
            if count > 0, let p = plan.steps[count - 1].points.last {
                let c = v(p)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.accentColor))
            }
        }
        .accessibilityLabel(Text("Cut preview"))
    }
}
