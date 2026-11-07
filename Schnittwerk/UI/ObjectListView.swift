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
                            .foregroundStyle(shape.cutEnabled ? Color.red : Color.gray)
                        Text(verbatim: shape.name.isEmpty ? "–" : shape.name)
                            .lineLimit(1)
                        Spacer()
                        if !shape.cutEnabled {
                            Image(systemName: "scissors")
                                .foregroundStyle(.secondary)
                                .overlay(Image(systemName: "line.diagonal").foregroundStyle(.secondary))
                                .help("Not cut")
                        }
                    }
                    .tag(shape.id)
                    .contextMenu {
                        Button("Duplicate") { duplicate(shape.id) }
                        Button("Bring to front") { reorder(shape.id, toFront: true) }
                        Button("Send to back") { reorder(shape.id, toFront: false) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(shape.id) }
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
            let copy = data.shapes[i].duplicated()
            newID = copy.id
            data.shapes.append(copy)
        }
        if let newID { selection = [newID] }
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
