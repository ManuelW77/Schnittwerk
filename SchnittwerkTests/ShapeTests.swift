// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class ShapeTests: XCTestCase {
    func testEveryKindFillsItsBox() {
        for kind in ShapeSpec.Kind.allCases {
            var spec = ShapeSpec.standard(kind)
            spec.widthMM = 80
            spec.heightMM = 30
            let lines = ShapeFactory.paths(for: spec)
            XCTAssertEqual(lines.count, 1, "\(kind)")
            XCTAssertTrue(lines[0].closed, "\(kind)")
            XCTAssertEqual(lines.bounds.width, 80, accuracy: 0.05, "\(kind)")
            XCTAssertEqual(lines.bounds.height, 30, accuracy: 0.05, "\(kind)")
        }
    }

    func testPolygonAndStarCornerCount() {
        var poly = ShapeSpec.standard(.polygon)
        poly.sides = 7
        XCTAssertEqual(ShapeFactory.paths(for: poly)[0].points.count, 7)
        var star = ShapeSpec.standard(.star)
        star.sides = 5
        XCTAssertEqual(ShapeFactory.paths(for: star)[0].points.count, 10)
    }

    func testCornerRadiusIsClamped() {
        var spec = ShapeSpec.standard(.rectangle)
        spec.widthMM = 40
        spec.heightMM = 20
        spec.cornerRadiusMM = 99
        XCTAssertEqual(spec.clamped.cornerRadiusMM, 10)
    }

    func testNewShapeSitsAtOrigin() {
        let shape = CutShape.basic(.standard(.ellipse), at: CGPoint(x: 20, y: 30))
        XCTAssertEqual(shape.matBounds.minX, 20, accuracy: 0.05)
        XCTAssertEqual(shape.matBounds.minY, 30, accuracy: 0.05)
        XCTAssertEqual(shape.name, ShapeSpec.Kind.ellipse.title)
    }

    func testScaleGoesIntoSpecAndKeepsCentreAndMirror() {
        var spec = ShapeSpec.standard(.rectangle)
        spec.cornerRadiusMM = 5
        var shape = CutShape.basic(spec, at: CGPoint(x: 10, y: 10))
        let centre = shape.position
        shape.scaleX = -2
        shape.scaleY = 1
        shape.bakeShapeScale()
        XCTAssertEqual(shape.scaleX, -1)
        XCTAssertEqual(shape.scaleY, 1)
        XCTAssertEqual(shape.shapeSpec?.widthMM ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(shape.shapeSpec?.heightMM ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(shape.shapeSpec?.cornerRadiusMM ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(shape.position, centre)
        XCTAssertEqual(shape.size.width, 100, accuracy: 0.05)
    }

    func testImportedShapeIgnoresShapeEdits() {
        var shape = CutShape(name: "x", matPaths: [Polyline(points: [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)], closed: true)])
        shape.updateShapeSpec(.standard(.star))
        XCTAssertNil(shape.shapeSpec)
        XCTAssertEqual(shape.paths[0].points.count, 3)
    }

    func testOldProjectWithoutShapeSpecStillLoads() throws {
        let shape = CutShape(name: "x", matPaths: [Polyline(points: [.zero, CGPoint(x: 10, y: 10)], closed: false)])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shape)) as! [String: Any]
        json.removeValue(forKey: "shapeSpec")
        let decoded = try JSONDecoder().decode(CutShape.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.shapeSpec)
    }

    func testShapeSpecSurvivesSaving() throws {
        let shape = CutShape.basic(.standard(.star), at: .zero)
        let decoded = try JSONDecoder().decode(CutShape.self, from: JSONEncoder().encode(shape))
        XCTAssertEqual(decoded.shapeSpec, shape.shapeSpec)
    }
}
