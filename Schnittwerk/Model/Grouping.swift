// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Groups (objects that move together) and locked objects.

import Foundation

extension ProjectData {
    /// The ids plus all other members of their groups.
    func expandedToGroups(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(shapes.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !groups.isEmpty else { return ids }
        return ids.union(shapes.filter { $0.groupID.map(groups.contains) == true }.map(\.id))
    }

    /// The ids without locked objects.
    func unlocked(_ ids: Set<UUID>) -> Set<UUID> {
        Set(shapes.filter { ids.contains($0.id) && !$0.isLocked }.map(\.id))
    }

    /// True if at least two of the objects can form a new group.
    func canGroup(_ ids: Set<UUID>) -> Bool {
        let members = shapes.filter { ids.contains($0.id) }
        guard members.count >= 2 else { return false }
        // Already exactly one group: nothing to do
        let groups = Set(members.map(\.groupID))
        return !(groups.count == 1 && groups.first! != nil)
    }

    func canUngroup(_ ids: Set<UUID>) -> Bool {
        shapes.contains { ids.contains($0.id) && $0.groupID != nil }
    }

    /// Puts the objects into one new group (old groups of them dissolve).
    mutating func group(_ ids: Set<UUID>) {
        guard canGroup(ids) else { return }
        let group = UUID()
        for i in shapes.indices where ids.contains(shapes[i].id) {
            shapes[i].groupID = group
        }
    }

    /// Dissolves all groups the objects belong to.
    mutating func ungroup(_ ids: Set<UUID>) {
        let groups = Set(shapes.filter { ids.contains($0.id) }.compactMap(\.groupID))
        for i in shapes.indices where shapes[i].groupID.map(groups.contains) == true {
            shapes[i].groupID = nil
        }
    }

    mutating func setLocked(_ locked: Bool, ids: Set<UUID>) {
        for i in shapes.indices where ids.contains(shapes[i].id) {
            shapes[i].isLocked = locked
        }
    }
}
