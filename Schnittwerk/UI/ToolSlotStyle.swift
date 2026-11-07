// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// How tool 1 and tool 2 look everywhere: on the mat, in the object
// list, in the inspector and in the cut panel.

import SwiftUI

enum ToolSlotStyle {
    static func color(_ slot: Int) -> Color { slot == 2 ? .blue : .red }

    static func title(_ slot: Int) -> String {
        slot == 2 ? String(localized: "Tool 2") : String(localized: "Tool 1")
    }
}

/// Small number badge, e.g. ① in red for tool 1.
struct ToolSlotBadge: View {
    let slot: Int
    var body: some View {
        Text(verbatim: "\(slot)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(ToolSlotStyle.color(slot), in: Circle())
            .accessibilityLabel(Text(ToolSlotStyle.title(slot)))
    }
}

/// Picker for the tool of the selected objects: 1 or 2, with the tool
/// name underneath.
struct ToolSlotPicker: View {
    let current: Int?
    let data: ProjectData
    let onPick: (Int) -> Void

    var body: some View {
        LabeledContent("Cut with") {
            VStack(alignment: .trailing, spacing: 4) {
                Picker("Cut with", selection: Binding(get: { current ?? 0 }, set: { if $0 != 0 { onPick($0) } })) {
                    ForEach([1, 2], id: \.self) { slot in
                        Text(ToolSlotStyle.title(slot)).tag(slot)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let current {
                    HStack(spacing: 4) {
                        Circle().fill(ToolSlotStyle.color(current)).frame(width: 8, height: 8)
                        Text(verbatim: data.settings(slot: current).tool.title)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Mixed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tip("Which tool holder cuts, draws or embosses this object")
    }
}

/// Legend at the bottom of the mat: which colour is which tool.
struct ToolLegend: View {
    let data: ProjectData

    var body: some View {
        HStack(spacing: 14) {
            ForEach([1, 2], id: \.self) { slot in
                let count = data.shapes.filter { $0.toolSlot == slot && $0.cutEnabled }.count
                HStack(spacing: 6) {
                    ToolSlotBadge(slot: slot)
                    Text(verbatim: data.settings(slot: slot).tool.title)
                    Text(verbatim: "(\(count))").foregroundStyle(.secondary)
                }
                .opacity(count == 0 ? 0.5 : 1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.5)))
    }
}
