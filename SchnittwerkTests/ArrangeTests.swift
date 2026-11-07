// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class ArrangeTests: XCTestCase {
    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CutShape {
        CutShape.basic(ShapeSpec(kind: .rectangle, widthMM: w, heightMM: h), at: CGPoint(x: x, y: y))
    }

    private func doc(_ shapes: [CutShape]) -> CutDocument {
        let d = CutDocument()
        d.data.shapes = shapes
        return d
    }

    func testAlignLeftAndBottom() {
        let d = doc([box(10, 10, 20, 20), box(40, 50, 10, 10)])
        let ids = Set(d.data.shapes.map(\.id))
        d.align(.left, ids: ids, undoManager: nil)
        XCTAssertEqual(d.data.shapes.map { $0.matBounds.minX }, [10, 10])
        d.align(.bottom, ids: ids, undoManager: nil)
        XCTAssertEqual(d.data.shapes[0].matBounds.maxY, 60, accuracy: 0.001)
        XCTAssertEqual(d.data.shapes[1].matBounds.maxY, 60, accuracy: 0.001)
    }

    func testSingleObjectAlignsToMat() {
        let d = doc([box(10, 10, 20, 20)])
        d.align(.centerX, ids: [d.data.shapes[0].id], undoManager: nil)
        XCTAssertEqual(d.data.shapes[0].matBounds.midX, d.data.mat.displaySize.width / 2, accuracy: 0.001)
    }

    func testDistributeGivesEqualGaps() {
        let d = doc([box(0, 0, 10, 10), box(15, 0, 30, 10), box(100, 0, 20, 10)])
        d.distribute(.horizontal, ids: Set(d.data.shapes.map(\.id)), undoManager: nil)
        let b = d.data.shapes.map(\.matBounds).sorted { $0.minX < $1.minX }
        XCTAssertEqual(b[1].minX - b[0].maxX, b[2].minX - b[1].maxX, accuracy: 0.001)
        XCTAssertEqual(b[0].minX, 0, accuracy: 0.001)
        XCTAssertEqual(b[2].maxX, 120, accuracy: 0.001)
    }

    func testDistributeNeedsThree() {
        let d = doc([box(0, 0, 10, 10), box(50, 0, 10, 10)])
        let before = d.data
        d.distribute(.horizontal, ids: Set(before.shapes.map(\.id)), undoManager: nil)
        XCTAssertEqual(d.data, before)
    }
}
