// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Edits on a set of objects, shared by the toolbar, the object list
// and the context menu of the mat. Each is one undo step.

import Foundation

extension CutDocument {
    /// Copies of the objects, slightly offset. Copies of a group form a
    /// new group of their own; copies are never locked.
    /// Returns the ids of the copies.
    @discardableResult
    func duplicate(_ ids: Set<UUID>, undoManager: UndoManager?) -> Set<UUID> {
        var newGroups: [UUID: UUID] = [:]
        let copies = data.shapes.filter { ids.contains($0.id) }.map { shape -> CutShape in
            var copy = shape.duplicated()
            copy.isLocked = false
            if let g = shape.groupID {
                if newGroups[g] == nil { newGroups[g] = UUID() }
                copy.groupID = newGroups[g]
            }
            return copy
        }
        guard !copies.isEmpty else { return [] }
        update(String(localized: "Duplicate"), undoManager: undoManager) { $0.shapes.append(contentsOf: copies) }
        return Set(copies.map(\.id))
    }

    /// Deletes the objects that are not locked. Returns the deleted ids.
    @discardableResult
    func delete(_ ids: Set<UUID>, undoManager: UndoManager?) -> Set<UUID> {
        let removable = data.unlocked(ids)
        guard !removable.isEmpty else { return [] }
        update(String(localized: "Delete"), undoManager: undoManager) { $0.shapes.removeAll { removable.contains($0.id) } }
        return removable
    }

    func group(_ ids: Set<UUID>, undoManager: UndoManager?) {
        let editable = data.unlocked(ids)
        guard data.canGroup(editable) else { return }
        update(String(localized: "Group"), undoManager: undoManager) { $0.group(editable) }
    }

    func ungroup(_ ids: Set<UUID>, undoManager: UndoManager?) {
        let editable = data.unlocked(ids)
        update(String(localized: "Ungroup"), undoManager: undoManager) { $0.ungroup(editable) }
    }

    func setLocked(_ locked: Bool, ids: Set<UUID>, undoManager: UndoManager?) {
        guard !ids.isEmpty else { return }
        update(locked ? String(localized: "Lock") : String(localized: "Unlock"), undoManager: undoManager) {
            $0.setLocked(locked, ids: ids)
        }
    }

    /// Turns cutting on or off for the objects that are not locked.
    func setCutEnabled(_ on: Bool, ids: Set<UUID>, undoManager: UndoManager?) {
        let editable = data.unlocked(ids)
        update(String(localized: "Cut on/off"), undoManager: undoManager) { data in
            for i in data.shapes.indices where editable.contains(data.shapes[i].id) {
                data.shapes[i].cutEnabled = on
            }
        }
    }

    /// Moves the objects to the front or back, keeping their order among each other.
    func reorder(_ ids: Set<UUID>, toFront: Bool, undoManager: UndoManager?) {
        update(String(localized: "Change order"), undoManager: undoManager) { data in
            let moving = data.shapes.filter { ids.contains($0.id) }
            data.shapes.removeAll { ids.contains($0.id) }
            if toFront { data.shapes.append(contentsOf: moving) } else { data.shapes.insert(contentsOf: moving, at: 0) }
        }
    }
}
