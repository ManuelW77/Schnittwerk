// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class GroupingTests: XCTestCase {
    private func project(_ count: Int) -> ProjectData {
        var data = ProjectData()
        data.shapes = (0..<count).map { i in
            CutShape.basic(.standard(.rectangle), at: CGPoint(x: Double(i) * 60, y: 0))
        }
        return data
    }

    func testGroupExpandsSelection() {
        var data = project(3)
        let a = data.shapes[0].id, b = data.shapes[1].id, c = data.shapes[2].id
        XCTAssertTrue(data.canGroup([a, b]))
        data.group([a, b])
        XCTAssertEqual(data.expandedToGroups([a]), [a, b])
        XCTAssertEqual(data.expandedToGroups([c]), [c])
        XCTAssertFalse(data.canGroup([a, b]), "already one group")
        XCTAssertTrue(data.canUngroup([b]))
        data.ungroup([b])
        XCTAssertEqual(data.expandedToGroups([a]), [a])
        XCTAssertFalse(data.canUngroup([a, b]))
    }

    func testOneObjectCannotBeGrouped() {
        let data = project(2)
        XCTAssertFalse(data.canGroup([data.shapes[0].id]))
    }

    func testLockedObjectsAreFilteredOut() {
        var data = project(2)
        let a = data.shapes[0].id, b = data.shapes[1].id
        data.setLocked(true, ids: [a])
        XCTAssertTrue(data.shapes[0].isLocked)
        XCTAssertEqual(data.unlocked([a, b]), [b])
        data.setLocked(false, ids: [a])
        XCTAssertEqual(data.unlocked([a, b]), [a, b])
    }

    func testOldFilesWithoutGroupOrLockStillOpen() throws {
        var data = project(1)
        data.group([]) // no-op
        let json = try JSONEncoder().encode(data)
        // Unlocked, ungrouped objects write no extra keys
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("lock"))
        XCTAssertFalse(text.contains("groupID"))
        let back = try JSONDecoder().decode(ProjectData.self, from: json)
        XCTAssertFalse(back.shapes[0].isLocked)
    }

    func testLockAndGroupAreSaved() throws {
        var data = project(2)
        data.group(Set(data.shapes.map(\.id)))
        data.setLocked(true, ids: [data.shapes[1].id])
        let back = try JSONDecoder().decode(ProjectData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(back, data)
        XCTAssertNotNil(back.shapes[0].groupID)
        XCTAssertTrue(back.shapes[1].isLocked)
    }

    @MainActor func testMCPRefusesToChangeLockedObjects() throws {
        var data = project(2)
        data.setLocked(true, ids: [data.shapes[0].id])
        XCTAssertThrowsError(try MCPTools.resolve(["#1"], in: data, editing: true))
        XCTAssertNoThrow(try MCPTools.resolve(["#1"], in: data))
        XCTAssertNoThrow(try MCPTools.resolve(["#2"], in: data, editing: true))
    }
}
