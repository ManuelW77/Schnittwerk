// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import XCTest
@testable import Schnittwerk

final class PDFImportTests: XCTestCase {
    /// A4-ish page; `draw` gets a context with PDF coordinates (points, y up).
    private func pdf(width: CGFloat = 300, height: CGFloat = 200, _ draw: (CGContext) -> Void) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private let mm = PDFImporter.mmPerPoint

    func testFilledRectangleAndCircle() throws {
        let data = pdf { ctx in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 72, y: 72, width: 72, height: 36))     // 1 × 0.5 in
            ctx.addEllipse(in: CGRect(x: 180, y: 50, width: 72, height: 72))
            ctx.strokePath()
        }
        let result = try PDFImporter.parse(data)
        XCTAssertEqual(result.paths.count, 2)
        XCTAssertTrue(result.paths.allSatisfy(\.closed))
        let rect = try XCTUnwrap(result.paths.min { $0.bounds.minX < $1.bounds.minX }).bounds
        XCTAssertEqual(rect.minX, 72 * mm, accuracy: 0.05)
        XCTAssertEqual(rect.width, 25.4, accuracy: 0.05)
        XCTAssertEqual(rect.height, 12.7, accuracy: 0.05)
        // y flipped: top of the rect is 200 - 108 points from the top
        XCTAssertEqual(rect.minY, (200 - 108) * mm, accuracy: 0.05)
        let circle = try XCTUnwrap(result.paths.max { $0.bounds.minX < $1.bounds.minX }).bounds
        XCTAssertEqual(circle.width, 25.4, accuracy: 0.05)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testTransformsAreApplied() throws {
        let data = pdf { ctx in
            ctx.saveGState()
            ctx.translateBy(x: 100, y: 50)
            ctx.scaleBy(x: 2, y: 2)
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            ctx.restoreGState()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let result = try PDFImporter.parse(data)
        XCTAssertEqual(result.paths.count, 2)
        let big = try XCTUnwrap(result.paths.max { $0.bounds.width < $1.bounds.width }).bounds
        XCTAssertEqual(big.width, 20 * mm, accuracy: 0.05)
        XCTAssertEqual(big.minX, 100 * mm, accuracy: 0.05)
    }

    func testClippingPathIsNotCut() throws {
        let data = pdf { ctx in
            ctx.clip(to: CGRect(x: 10, y: 10, width: 280, height: 180))
            ctx.fill(CGRect(x: 50, y: 50, width: 20, height: 20))
        }
        let result = try PDFImporter.parse(data)
        XCTAssertEqual(result.paths.count, 1)
        XCTAssertEqual(result.paths[0].bounds.width, 20 * mm, accuracy: 0.05)
    }

    func testTextIsReported() throws {
        let data = pdf { ctx in
            ctx.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hi", attributes: [
                .font: NSFont.systemFont(ofSize: 20),
            ]))
            ctx.textPosition = CGPoint(x: 50, y: 50)
            CTLineDraw(line, ctx)
        }
        let result = try PDFImporter.parse(data)
        XCTAssertEqual(result.paths.count, 1)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testNotAPDF() {
        XCTAssertThrowsError(try PDFImporter.parse(Data("hello".utf8)))
    }

    func testShapeImporterKnowsPDF() throws {
        let data = pdf { $0.fill(CGRect(x: 10, y: 10, width: 30, height: 30)) }
        let (shape, _) = try ShapeImporter.importShape(data: data, fileExtension: "pdf", name: "Test")
        XCTAssertEqual(shape.size.width, 30 * mm, accuracy: 0.05)
    }
}
