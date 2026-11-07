// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class PathOperationTests: XCTestCase {
    /// Square of `size` mm with its top left corner at (x, y).
    private func square(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 20) -> CutShape {
        CutShape.basic(ShapeSpec(kind: .rectangle, widthMM: size, heightMM: size), at: CGPoint(x: x, y: y))
    }

    private func area(_ lines: [Polyline]) -> CGFloat {
        // Shoelace formula; holes count negative because they run the other way
        lines.reduce(0) { sum, l in
            let p = l.points
            var a: CGFloat = 0
            for i in p.indices { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
            return sum + a / 2
        }
    }

    func testWeldTwoOverlappingSquares() {
        let lines = PathOps.apply(.weld, to: [square(0, 0), square(10, 10)])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(abs(area(lines)), 400 + 400 - 100, accuracy: 0.5)
        XCTAssertEqual(lines.bounds, CGRect(x: 0, y: 0, width: 30, height: 30))
    }

    func testSubtractCutsFrontFromBack() {
        let lines = PathOps.apply(.subtract, to: [square(0, 0), square(10, 10)])
        XCTAssertEqual(abs(area(lines)), 300, accuracy: 0.5)
        XCTAssertEqual(lines.bounds, CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testSubtractInsideMakesHole() {
        let lines = PathOps.apply(.subtract, to: [square(0, 0, 40), square(10, 10)])
        XCTAssertEqual(lines.count, 2) // outline and hole
    }

    func testIntersect() {
        let lines = PathOps.apply(.intersect, to: [square(0, 0), square(10, 10)])
        XCTAssertEqual(abs(area(lines)), 100, accuracy: 0.5)
        XCTAssertEqual(lines.bounds, CGRect(x: 10, y: 10, width: 10, height: 10))
    }

    func testIntersectWithoutOverlapIsEmpty() {
        XCTAssertTrue(PathOps.apply(.intersect, to: [square(0, 0), square(50, 50)]).isEmpty)
    }

    func testLetterHoleSurvivesWeld() {
        // "O" has a hole (even-odd); welding a far away square keeps it
        let o = CutShape.text(TextSpec(text: "O", fontName: "Helvetica", sizeMM: 30), at: .zero)!
        let lines = PathOps.apply(.weld, to: [o, square(100, 0)])
        XCTAssertEqual(lines.count, 3)
    }

    func testCombineReplacesSelectionInDocument() {
        let doc = CutDocument()
        let a = square(0, 0), b = square(10, 10), other = square(100, 100)
        doc.data.shapes = [a, other, b]
        let id = doc.combine(.weld, ids: [a.id, b.id], undoManager: nil)
        XCTAssertNotNil(id)
        XCTAssertEqual(doc.data.shapes.count, 2)
        XCTAssertEqual(doc.data.shapes[0].id, other.id)
        XCTAssertEqual(doc.data.shapes[1].id, id) // where the front object was
        XCTAssertNil(doc.data.shapes[1].shapeSpec)
    }

    func testCombineEmptyResultChangesNothing() {
        let doc = CutDocument()
        doc.data.shapes = [square(0, 0), square(50, 50)]
        let before = doc.data
        XCTAssertNil(doc.combine(.intersect, ids: Set(before.shapes.map(\.id)), undoManager: nil))
        XCTAssertEqual(doc.data, before)
    }
}
