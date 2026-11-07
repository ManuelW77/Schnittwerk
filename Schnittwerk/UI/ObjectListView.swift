// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Left side panel: all objects on the mat.
struct ObjectListView: View {
    @ObservedObject var document: CutDocument
    @Binding var selection: Set<UUID>
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: $selection) {
            Section("Objects") {
                ForEach(document.data.shapes.reversed()) { shape in
                    HStack {
                        Image(systemName: shape.text != nil ? "textformat"
                              : shape.shapeSpec?.kind.systemImage ?? "scribble.variable")
                            .foregroundStyle(shape.colorHex.flatMap(RGB.init(hex:))
                                .map { Color(red: $0.r, green: $0.g, blue: $0.b) }
                                ?? (shape.cutEnabled ? ToolSlotStyle.color(shape.toolSlot) : Color.gray))
                        Text(verbatim: shape.name.isEmpty ? "–" : shape.name)
                            .lineLimit(1)
                        Spacer()
                        ToolSlotBadge(slot: shape.toolSlot)
                            .opacity(shape.cutEnabled ? 1 : 0.35)
                            .tip(ToolSlotStyle.title(shape.toolSlot))
                        if shape.groupID != nil {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                                .tip("In a group")
                        }
                        Button { setLocked(!shape.isLocked, id: shape.id) } label: {
                            Image(systemName: shape.isLocked ? "lock.fill" : "lock.open")
                                .foregroundStyle(shape.isLocked ? Color.primary : Color.secondary.opacity(0.4))
                        }
                        .buttonStyle(.borderless)
                        .tip(shape.isLocked ? "Locked: click to unlock" : "Lock so it cannot be changed")
                        if !shape.cutEnabled {
                            Image(systemName: "scissors")
                                .foregroundStyle(.secondary)
                                .overlay(Image(systemName: "line.diagonal").foregroundStyle(.secondary))
                                .tip("Not cut")
                        }
                    }
                    .tag(shape.id)
                    .contextMenu {
                        Button(shape.isLocked ? "Unlock" : "Lock") { setLocked(!shape.isLocked, id: shape.id) }
                        if shape.groupID != nil {
                            Button("Ungroup") { ungroup(shape.id) }
                        }
                        Menu("Cut with") {
                            ForEach([1, 2], id: \.self) { slot in
                                Button(ToolSlotStyle.title(slot)) {
                                    document.setToolSlot(slot, ids: [shape.id], undoManager: undoManager)
                                }
                            }
                        }
                        .disabled(shape.isLocked)
                        Divider()
                        Button("Duplicate") { duplicate(shape.id) }
                        Button("Bring to front") { reorder(shape.id, toFront: true) }
                        Button("Send to back") { reorder(shape.id, toFront: false) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(shape.id) }
                            .disabled(shape.isLocked)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if document.data.shapes.isEmpty {
                Text("No objects yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func duplicate(_ id: UUID) {
        var newID: UUID?
        document.update(String(localized: "Duplicate"), undoManager: undoManager) { data in
            guard let i = data.shapes.firstIndex(where: { $0.id == id }) else { return }
            var copy = data.shapes[i].duplicated()
            copy.groupID = nil
            copy.isLocked = false
            newID = copy.id
            data.shapes.append(copy)
        }
        if let newID { selection = [newID] }
    }

    private func setLocked(_ locked: Bool, id: UUID) {
        document.update(locked ? String(localized: "Lock") : String(localized: "Unlock"),
                        undoManager: undoManager) { $0.setLocked(locked, ids: [id]) }
    }

    private func ungroup(_ id: UUID) {
        document.update(String(localized: "Ungroup"), undoManager: undoManager) { $0.ungroup([id]) }
    }

    private func delete(_ id: UUID) {
        document.update(String(localized: "Delete"), undoManager: undoManager) { data in
            data.shapes.removeAll { $0.id == id }
        }
        selection.remove(id)
    }

    private func reorder(_ id: UUID, toFront: Bool) {
        document.update(String(localized: "Change order"), undoManager: undoManager) { data in
            guard let i = data.shapes.firstIndex(where: { $0.id == id }) else { return }
            let s = data.shapes.remove(at: i)
            if toFront { data.shapes.append(s) } else { data.shapes.insert(s, at: 0) }
        }
    }
}
