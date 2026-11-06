// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class ProjectDataTests: XCTestCase {
    func testShapeKeepsPositionOnMat() {
        let square = Polyline(points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10),
                                       CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)], closed: true)
        let shape = CutShape(name: "Square", matPaths: [square])
        XCTAssertEqual(shape.position, CGPoint(x: 20, y: 20))
        XCTAssertEqual(shape.matBounds, CGRect(x: 10, y: 10, width: 20, height: 20))
        XCTAssertEqual(shape.size, CGSize(width: 20, height: 20))
    }

    func testRotationKeepsCentre() {
        let line = Polyline(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)], closed: false)
        var shape = CutShape(name: "Line", matPaths: [line])
        shape.rotation = 90
        let b = shape.matBounds
        XCTAssertEqual(b.midX, 20, accuracy: 1e-9)
        XCTAssertEqual(b.height, 40, accuracy: 1e-9)
        XCTAssertEqual(b.width, 0, accuracy: 1e-9)
    }

    func testProjectRoundTrip() throws {
        var data = ProjectData()
        data.mat = .mat12x24
        data.settings.pressure = 17
        data.shapes = [CutShape(name: "A", matPaths: [
            Polyline(points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], closed: false),
        ])]
        let json = try JSONEncoder().encode(data)
        let back = try JSONDecoder().decode(ProjectData.self, from: json)
        XCTAssertEqual(back, data)
    }

    func testSettingsAreClamped() {
        var s = CutSettings()
        s.pressure = 99; s.speed = 0; s.depth = 20; s.holder = 3
        let c = s.clamped
        XCTAssertEqual(c.pressure, 33)
        XCTAssertEqual(c.speed, 1)
        XCTAssertEqual(c.depth, 10)
        XCTAssertEqual(c.holder, 2)
    }

    func testFlattenCircle() {
        let path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 20, height: 20), transform: nil)
        let lines = path.polylines(tolerance: 0.02)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].closed)
        // Circumference 2πr ≈ 62.83 mm
        XCTAssertEqual(lines[0].length, 62.83, accuracy: 0.1)
    }
}
