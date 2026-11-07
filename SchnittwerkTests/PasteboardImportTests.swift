// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import XCTest
@testable import Schnittwerk

final class PasteboardImportTests: XCTestCase {
    private var board: NSPasteboard!

    override func setUp() {
        board = NSPasteboard(name: NSPasteboard.Name("schnittwerk.test.\(UUID().uuidString)"))
        board.clearContents()
    }

    override func tearDown() {
        board.releaseGlobally()
    }

    private let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="50mm" height="20mm" viewBox="0 0 50 20">
      <rect x="0" y="0" width="50" height="20"/>
    </svg>
    """

    private func pdfData() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 10, y: 10, width: 72, height: 72))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func testSVGType() throws {
        board.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType("public.svg-image"))
        XCTAssertEqual(PasteboardImport.payload(from: board)?.format, "svg")
        let (shape, _) = try XCTUnwrap(PasteboardImport.shape(from: board))
        XCTAssertEqual(shape.size.width, 50, accuracy: 0.1)
    }

    func testSVGWinsOverPDF() {
        board.declareTypes([NSPasteboard.PasteboardType("public.svg-image"), .pdf], owner: nil)
        board.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType("public.svg-image"))
        board.setData(pdfData(), forType: .pdf)
        XCTAssertEqual(PasteboardImport.payload(from: board)?.format, "svg")
    }

    func testPDFFallback() throws {
        board.setData(pdfData(), forType: .pdf)
        XCTAssertEqual(PasteboardImport.payload(from: board)?.format, "pdf")
        let (shape, _) = try XCTUnwrap(PasteboardImport.shape(from: board))
        XCTAssertEqual(shape.size.width, 25.4, accuracy: 0.05)
    }

    func testSVGAsText() {
        board.setString(svg, forType: .string)
        XCTAssertEqual(PasteboardImport.payload(from: board)?.format, "svg")
    }

    func testPlainTextIsNoDrawing() throws {
        board.setString("Hallo Welt", forType: .string)
        XCTAssertFalse(PasteboardImport.canPaste(board))
        XCTAssertNil(try PasteboardImport.shape(from: board))
    }
}
