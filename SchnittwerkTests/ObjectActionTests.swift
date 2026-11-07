// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class ObjectActionTests: XCTestCase {
    private func document(_ count: Int) -> CutDocument {
        let doc = CutDocument()
        doc.data.shapes = (0..<count).map { i in
            CutShape.basic(.standard(.rectangle), at: CGPoint(x: Double(i) * 60, y: 0))
        }
        return doc
    }

    func testDeleteSkipsLockedObjects() {
        let doc = document(2)
        let a = doc.data.shapes[0].id, b = doc.data.shapes[1].id
        doc.data.setLocked(true, ids: [a])
        XCTAssertEqual(doc.delete([a, b], undoManager: nil), [b])
        XCTAssertEqual(doc.data.shapes.map(\.id), [a])
    }

    func testDuplicatedGroupGetsOwnGroupAndIsUnlocked() {
        let doc = document(2)
        let ids = Set(doc.data.shapes.map(\.id))
        doc.data.group(ids)
        doc.data.setLocked(true, ids: ids)
        let copies = doc.duplicate(ids, undoManager: nil)
        XCTAssertEqual(copies.count, 2)
        let copyShapes = doc.data.shapes.filter { copies.contains($0.id) }
        XCTAssertEqual(Set(copyShapes.map(\.groupID)).count, 1)
        XCTAssertNotEqual(copyShapes[0].groupID, doc.data.shapes[0].groupID)
        XCTAssertFalse(copyShapes.contains(where: \.isLocked))
    }

    func testReorderKeepsOrderAmongMovedObjects() {
        let doc = document(4)
        let ids = doc.data.shapes.map(\.id)
        doc.reorder([ids[0], ids[2]], toFront: true, undoManager: nil)
        XCTAssertEqual(doc.data.shapes.map(\.id), [ids[1], ids[3], ids[0], ids[2]])
        doc.reorder([ids[3], ids[2]], toFront: false, undoManager: nil)
        XCTAssertEqual(doc.data.shapes.map(\.id), [ids[3], ids[2], ids[1], ids[0]])
    }

    func testCutToggleLeavesLockedObjectsAlone() {
        let doc = document(2)
        let a = doc.data.shapes[0].id, b = doc.data.shapes[1].id
        doc.data.setLocked(true, ids: [a])
        doc.setCutEnabled(false, ids: [a, b], undoManager: nil)
        XCTAssertTrue(doc.data.shapes[0].cutEnabled)
        XCTAssertFalse(doc.data.shapes[1].cutEnabled)
    }

    func testGroupIgnoresLockedObjects() {
        let doc = document(3)
        let ids = doc.data.shapes.map(\.id)
        doc.data.setLocked(true, ids: [ids[2]])
        doc.group(Set(ids), undoManager: nil)
        XCTAssertNotNil(doc.data.shapes[0].groupID)
        XCTAssertEqual(doc.data.shapes[0].groupID, doc.data.shapes[1].groupID)
        XCTAssertNil(doc.data.shapes[2].groupID)
    }
}
