// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class DrawingTests: XCTestCase {
    func testSimplifyDropsPointsOnAStraightLine() {
        let points = (0...100).map { CGPoint(x: CGFloat($0), y: 0.001 * CGFloat($0 % 2)) }
        let simple = FreehandBuilder.simplify(points, tolerance: 0.1)
        XCTAssertEqual(simple, [points.first!, points.last!])
    }

    func testFreehandLineStaysOpenAndNearTheDrawing() throws {
        let points = (0...60).map { i -> CGPoint in
            let x = CGFloat(i)
            return CGPoint(x: x, y: 10 * sin(x / 10))
        }
        let line = try XCTUnwrap(FreehandBuilder.polyline(from: points, tolerance: 0.3, closeDistance: 2))
        XCTAssertFalse(line.closed)
        XCTAssertEqual(line.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(line.bounds.maxX, 60, accuracy: 0.01)
        for p in line.points {
            XCTAssertEqual(p.y, 10 * sin(p.x / 10), accuracy: 0.6)
        }
    }

    func testFreehandCircleCloses() throws {
        let points = (0...72).map { i -> CGPoint in
            let a = CGFloat(i) * .pi / 36
            return CGPoint(x: 50 + 20 * cos(a), y: 50 + 20 * sin(a))
        }
        let line = try XCTUnwrap(FreehandBuilder.polyline(from: points, tolerance: 0.2, closeDistance: 2))
        XCTAssertTrue(line.closed)
        XCTAssertEqual(line.bounds.width, 40, accuracy: 1)
    }

    func testTinyFreehandGivesNothing() {
        XCTAssertNil(FreehandBuilder.polyline(from: [CGPoint(x: 1, y: 1), CGPoint(x: 1.2, y: 1)],
                                              tolerance: 0.2, closeDistance: 2))
        XCTAssertNil(FreehandBuilder.polyline(from: [CGPoint(x: 1, y: 1)], tolerance: 0.2, closeDistance: 2))
    }

    func testPenCornersGiveStraightLines() throws {
        let curve = PenCurve(anchors: [.init(point: CGPoint(x: 0, y: 0)),
                                       .init(point: CGPoint(x: 30, y: 0)),
                                       .init(point: CGPoint(x: 30, y: 20))])
        let open = try XCTUnwrap(curve.polyline(closed: false))
        XCTAssertFalse(open.closed)
        XCTAssertEqual(open.points.count, 3)
        let closed = try XCTUnwrap(curve.polyline(closed: true))
        XCTAssertTrue(closed.closed)
        XCTAssertEqual(closed.length, 30 + 20 + hypot(30, 20), accuracy: 0.01)
    }

    func testPenRoundPointBends() throws {
        let curve = PenCurve(anchors: [.init(point: CGPoint(x: 0, y: 0), handle: CGPoint(x: 0, y: -20)),
                                       .init(point: CGPoint(x: 40, y: 0), handle: CGPoint(x: 0, y: 20))])
        let line = try XCTUnwrap(curve.polyline(closed: false))
        XCTAssertGreaterThan(line.points.count, 4)
        XCTAssertLessThan(line.bounds.minY, -5) // bulges upwards
        XCTAssertEqual(line.points.first!.x, 0, accuracy: 0.001)
        XCTAssertEqual(line.points.last!.x, 40, accuracy: 0.001)
    }

    func testPenNeedsTwoPoints() {
        XCTAssertNil(PenCurve(anchors: [.init(point: .zero)]).polyline(closed: false))
        XCTAssertNil(PenCurve().polyline(closed: true))
    }

    func testDrawnShapeKeepsItsPlace() {
        let line = Polyline(points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)], closed: false)
        let shape = CutShape.drawn(line, name: "Kurve")
        XCTAssertEqual(shape.matBounds.minX, 10, accuracy: 0.001)
        XCTAssertEqual(shape.matBounds.maxY, 30, accuracy: 0.001)
        XCTAssertNil(shape.text)
        XCTAssertNil(shape.shapeSpec)
    }
}
