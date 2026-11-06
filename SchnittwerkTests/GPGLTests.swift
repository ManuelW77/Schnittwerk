// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class GPGLTests: XCTestCase {
    private let square = Polyline(points: [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 20),
                                           CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 40)], closed: true)

    func testHeaderForMat12x12AutoBlade() {
        var s = CutSettings()
        s.tool = .autoBlade; s.depth = 3; s.pressure = 12; s.speed = 6; s.holder = 1
        let job = GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x12)
        XCTAssertEqual(Array(job.commands.prefix(18)), [
            "TG1", "FN0", "TB50,0", "\\0,0", "Z6096,6096",
            "J1", "TF3,1", "FX12,1", "TJ0", "!6,1", "FC0,1,1", "FE0,1", "FF1,0,1", "FF1,1,1",
            "FX12,1", "TJ3", "FC18,1,1",
            "M400,200", // y first: 20 mm → 400, x 10 mm → 200
        ])
    }

    func testClosedPathReturnsToStartAndEnds() {
        let job = GPGLBuilder.build(paths: [square], settings: CutSettings(), mat: .mat12x12)
        let body = job.commands.drop { !$0.hasPrefix("M") }
        XCTAssertEqual(Array(body), ["M400,200", "D400,600", "D800,600", "D800,200", "D400,200", "M800,0", "SO0"])
        XCTAssertEqual(job.cutLengthMM, 80, accuracy: 1e-9)
    }

    func testPenHasNoBladeOffsetAndNoDepth() {
        var s = CutSettings()
        s.tool = .pen; s.holder = 2
        let job = GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x24)
        XCTAssertTrue(job.commands.contains("Z12192,6096"))
        XCTAssertTrue(job.commands.contains("FC0,1,2"))
        XCTAssertFalse(job.commands.contains { $0.hasPrefix("TF") })
        XCTAssertFalse(job.commands.contains("FC18,1,2"))
    }

    func testPassesRepeatLines() {
        var s = CutSettings()
        s.passes = 3
        let job = GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x12)
        XCTAssertEqual(job.commands.filter { $0 == "M400,200" }.count, 3)
        XCTAssertEqual(job.cutLengthMM, 240, accuracy: 1e-9)
    }

    func testPointsAreClampedToMat() {
        let line = Polyline(points: [CGPoint(x: -5, y: 10), CGPoint(x: 400, y: 10)], closed: false)
        let job = GPGLBuilder.build(paths: [line], settings: CutSettings(), mat: .mat12x12)
        XCTAssertTrue(job.commands.contains("M200,0"))
        XCTAssertTrue(job.commands.contains("D200,6096"))
    }

    func testHolesAreCutBeforeOutline() {
        let outer = Polyline(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)], closed: true)
        let hole = Polyline(points: [CGPoint(x: 40, y: 40), CGPoint(x: 60, y: 40), CGPoint(x: 60, y: 60)], closed: true)
        XCTAssertEqual(GPGLBuilder.ordered([outer, hole]), [hole, outer])
    }

    func testDisabledShapesAreNotCut() {
        var data = ProjectData()
        var a = CutShape(name: "a", matPaths: [square])
        a.cutEnabled = false
        data.shapes = [a]
        XCTAssertTrue(GPGLBuilder.cutPaths(data).isEmpty)
    }

    func testChunksEndAtCommandBoundary() {
        let many = (0..<200).map { i in
            Polyline(points: [CGPoint(x: Double(i), y: 0), CGPoint(x: Double(i), y: 10)], closed: false)
        }
        let job = GPGLBuilder.build(paths: many, settings: CutSettings(), mat: .mat12x12)
        let chunks = job.chunks(maxBytes: 256)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 256 && $0.last == GPGLJob.etx })
        XCTAssertEqual(chunks.reduce(Data(), +), job.data)
    }

    func testTestCutFitsInCorner() {
        let job = GPGLBuilder.testCut(settings: CutSettings(), mat: .mat12x12)
        XCTAssertEqual(job.pathCount, 2)
        // Triangle (inside) first
        XCTAssertEqual(job.commands.first { $0.hasPrefix("M") }, "M360,240")
    }
}

final class USBSmokeTests: XCTestCase {
    /// libusb is linked and works: without a plotter, open() reports "not found".
    func testOpenWithoutPlotterReportsNotFound() {
        let usb = CameoUSB()
        do {
            try usb.open()
            usb.close() // a Cameo 4 is connected: also fine
        } catch let e as PlotterError {
            XCTAssertTrue([.notFound, .busy].contains(e), "\(e)")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testStatusReplies() {
        XCTAssertEqual(PlotterStatus(reply: "0"), .ready)
        XCTAssertEqual(PlotterStatus(reply: "1"), .moving)
        XCTAssertEqual(PlotterStatus(reply: "2"), .noMedia)
        XCTAssertEqual(PlotterStatus(reply: "x"), .unknown("x"))
    }
}
