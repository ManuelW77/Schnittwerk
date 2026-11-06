// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class TextTests: XCTestCase {
    func testCapitalHeightMatchesFont() {
        let spec = TextSpec(text: "H", fontName: "Helvetica", sizeMM: 100)
        let lines = TextOutliner.paths(for: spec)
        XCTAssertFalse(lines.isEmpty)
        let capHeight = CTFontGetCapHeight(CTFontCreateWithName("Helvetica" as CFString, 100, nil))
        XCTAssertEqual(lines.bounds.height, capHeight, accuracy: 0.1)
    }

    func testLetterIsNotUpsideDown() {
        // "T": the bar is at the top, so the widest part has the smallest y
        let lines = TextOutliner.paths(for: TextSpec(text: "T", fontName: "Helvetica", sizeMM: 50))
        let b = lines.bounds
        let topPoints = lines.flatMap(\.points).filter { $0.y < b.minY + 1 }
        let topWidth = (topPoints.map(\.x).max() ?? 0) - (topPoints.map(\.x).min() ?? 0)
        XCTAssertEqual(topWidth, b.width, accuracy: 0.5)
    }

    func testHoleInLetterO() {
        let lines = TextOutliner.paths(for: TextSpec(text: "O", fontName: "Helvetica", sizeMM: 30))
        XCTAssertEqual(lines.count, 2) // outside and hole
        XCTAssertTrue(lines.allSatisfy(\.closed))
    }

    func testMultipleLines() {
        let one = TextOutliner.paths(for: TextSpec(text: "A", fontName: "Helvetica", sizeMM: 20))
        let two = TextOutliner.paths(for: TextSpec(text: "A\nA", fontName: "Helvetica", sizeMM: 20))
        XCTAssertGreaterThan(two.bounds.height, one.bounds.height * 2)
    }

    func testSpacesOnlyGiveNoShape() {
        XCTAssertNil(CutShape.text(TextSpec(text: "   ", fontName: "Helvetica", sizeMM: 20), at: .zero))
    }

    func testUpdateTextKeepsLeftTop() {
        var shape = CutShape.text(TextSpec(text: "Hi", fontName: "Helvetica", sizeMM: 20), at: CGPoint(x: 30, y: 40))!
        XCTAssertEqual(shape.matBounds.minX, 30, accuracy: 1e-6)
        var spec = shape.text!
        spec.text = "Hallo Welt"
        XCTAssertTrue(shape.updateText(spec))
        XCTAssertEqual(shape.matBounds.minX, 30, accuracy: 1e-6)
        XCTAssertEqual(shape.matBounds.minY, 40, accuracy: 1e-6)
        XCTAssertEqual(shape.name, "Hallo Welt")
    }
}
