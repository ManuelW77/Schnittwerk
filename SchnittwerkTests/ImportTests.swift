// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class SVGImportTests: XCTestCase {
    private func svg(_ body: String, root: String = #"width="100mm" height="100mm" viewBox="0 0 100 100""#) throws -> ImportResult {
        let text = #"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" \#(root)>\#(body)</svg>"#
        return try SVGImporter.parse(Data(text.utf8))
    }

    func testRectInMillimetres() throws {
        let r = try svg(#"<rect x="10" y="20" width="30" height="40"/>"#)
        XCTAssertEqual(r.paths.count, 1)
        let b = r.paths.bounds
        XCTAssertEqual(b.minX, 10, accuracy: 1e-6)
        XCTAssertEqual(b.minY, 20, accuracy: 1e-6)
        XCTAssertEqual(b.width, 30, accuracy: 1e-6)
        XCTAssertEqual(b.height, 40, accuracy: 1e-6)
        XCTAssertTrue(r.paths[0].closed)
    }

    func testPixelsWithoutViewBox() throws {
        // 96 px = 1 inch = 25.4 mm
        let r = try svg(#"<rect width="96" height="96"/>"#, root: "")
        XCTAssertEqual(r.paths.bounds.width, 25.4, accuracy: 1e-6)
    }

    func testViewBoxScaling() throws {
        // 200 units across 100 mm → 0.5 mm per unit
        let r = try svg(#"<line x1="0" y1="0" x2="200" y2="0"/>"#,
                        root: #"width="100mm" height="50mm" viewBox="0 0 200 100""#)
        XCTAssertEqual(r.paths.bounds.width, 100, accuracy: 1e-6)
    }

    func testGroupTransform() throws {
        let r = try svg(#"<g transform="translate(50 0) scale(2)"><rect width="10" height="5"/></g>"#)
        let b = r.paths.bounds
        XCTAssertEqual(b.minX, 50, accuracy: 1e-6)
        XCTAssertEqual(b.width, 20, accuracy: 1e-6)
        XCTAssertEqual(b.height, 10, accuracy: 1e-6)
    }

    func testRelativePathCommandsAndCompactNumbers() throws {
        // "l10-5" without separator, implicit lineto after m, h/v
        let r = try svg(#"<path d="m10 10 10 0l0-5h-10v5z"/>"#)
        XCTAssertEqual(r.paths.count, 1)
        let b = r.paths.bounds
        XCTAssertEqual(b.minX, 10, accuracy: 1e-6)
        XCTAssertEqual(b.maxX, 20, accuracy: 1e-6)
        XCTAssertEqual(b.minY, 5, accuracy: 1e-6)
        XCTAssertEqual(b.maxY, 10, accuracy: 1e-6)
    }

    func testArcHalfCircle() throws {
        // Half circle radius 10 from (0,50) to (20,50), sweep 1 → bulges up (y smaller)
        let r = try svg(#"<path d="M0 50 A10 10 0 0 1 20 50"/>"#)
        let b = r.paths.bounds
        XCTAssertEqual(b.width, 20, accuracy: 0.01)
        XCTAssertEqual(b.minY, 40, accuracy: 0.03)
        XCTAssertEqual(b.maxY, 50, accuracy: 0.01)
    }

    func testCompactArcFlags() throws {
        let r = try svg(#"<path d="M0 50a10 10 0 0120 0"/>"#)
        XCTAssertEqual(r.paths.bounds.width, 20, accuracy: 0.01)
    }

    func testHiddenAndDefsAreSkipped() throws {
        let r = try svg(#"""
        <defs><rect width="90" height="90"/></defs>
        <rect width="90" height="90" style="display: none"/>
        <circle cx="50" cy="50" r="5"/>
        """#)
        XCTAssertEqual(r.paths.count, 1)
        XCTAssertEqual(r.paths.bounds.width, 10, accuracy: 0.01)
    }

    func testTextGivesWarning() throws {
        let r = try svg(#"<text x="10" y="10">Hallo</text><rect width="5" height="5"/>"#)
        XCTAssertEqual(r.paths.count, 1)
        XCTAssertEqual(r.warnings.count, 1)
    }

    func testBrokenXMLThrows() {
        XCTAssertThrowsError(try SVGImporter.parse(Data("not svg".utf8)))
    }
}

final class DXFImportTests: XCTestCase {
    private func dxf(_ entities: String, units: Int? = nil) throws -> ImportResult {
        var s = "0\nSECTION\n2\nHEADER\n"
        if let units { s += "9\n$INSUNITS\n70\n\(units)\n" }
        s += "0\nENDSEC\n0\nSECTION\n2\nENTITIES\n\(entities)0\nENDSEC\n0\nEOF\n"
        return try DXFImporter.parse(Data(s.utf8))
    }

    func testLineFlipsY() throws {
        let r = try dxf("0\nLINE\n8\n0\n10\n0\n20\n0\n11\n10\n21\n5\n")
        XCTAssertEqual(r.paths.count, 1)
        XCTAssertEqual(r.paths[0].points[1].x, 10, accuracy: 1e-9)
        XCTAssertEqual(r.paths[0].points[1].y, -5, accuracy: 1e-9)
    }

    func testInchUnits() throws {
        let r = try dxf("0\nLINE\n10\n0\n20\n0\n11\n1\n21\n0\n", units: 1)
        XCTAssertEqual(r.paths.bounds.width, 25.4, accuracy: 1e-9)
    }

    func testCircle() throws {
        let r = try dxf("0\nCIRCLE\n10\n50\n20\n50\n40\n10\n")
        XCTAssertTrue(r.paths[0].closed)
        XCTAssertEqual(r.paths.bounds.width, 20, accuracy: 0.05)
        XCTAssertEqual(r.paths[0].length, 2 * .pi * 10, accuracy: 0.1)
    }

    func testLWPolylineWithBulge() throws {
        // Two points 20 apart, bulge 1 = half circle
        let r = try dxf("0\nLWPOLYLINE\n90\n2\n70\n0\n10\n0\n20\n0\n42\n1\n10\n20\n20\n0\n")
        let b = r.paths.bounds
        XCTAssertEqual(b.width, 20, accuracy: 0.01)
        XCTAssertEqual(b.height, 10, accuracy: 0.03)
    }

    func testClosedPolylineEntity() throws {
        let r = try dxf("0\nPOLYLINE\n70\n1\n0\nVERTEX\n10\n0\n20\n0\n0\nVERTEX\n10\n10\n20\n0\n0\nVERTEX\n10\n10\n20\n10\n0\nSEQEND\n")
        XCTAssertEqual(r.paths.count, 1)
        XCTAssertTrue(r.paths[0].closed)
        XCTAssertEqual(r.paths[0].points.count, 3)
    }

    func testClampedSplineEndsAtControlPoints() throws {
        // Degree 2, 3 control points, clamped knots 0 0 0 1 1 1
        let e = "0\nSPLINE\n70\n8\n71\n2\n72\n6\n73\n3\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n10\n0\n20\n0\n10\n10\n20\n10\n10\n20\n20\n0\n"
        let r = try dxf(e)
        let pts = r.paths[0].points
        XCTAssertEqual(pts.first!.x, 0, accuracy: 1e-9)
        XCTAssertEqual(pts.last!.x, 20, accuracy: 1e-9)
        // Top of a quadratic Bézier at 1/2 of control height
        XCTAssertEqual(r.paths.bounds.height, 5, accuracy: 0.01)
    }

    func testInsertGivesWarning() throws {
        let r = try dxf("0\nINSERT\n2\nBLOCK1\n10\n0\n20\n0\n0\nLINE\n10\n0\n20\n0\n11\n1\n21\n1\n")
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertEqual(r.paths.count, 1)
    }
}
