// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

@MainActor
final class EditToolsTests: XCTestCase {
    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CutShape {
        CutShape(name: "R", matPaths: [Polyline(points: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                                                         CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)], closed: true)])
    }

    // MARK: Weeding

    func testWeedingBoxAndLinesAvoidTheMotif() {
        let a = rect(10, 10, 20, 20)
        let lines = Weeding.lines(around: [a], margin: 3, horizontal: 1, vertical: 1)
        let box = lines[0]
        XCTAssertTrue(box.closed)
        XCTAssertEqual(box.bounds.minX, 7, accuracy: 1e-6)
        XCTAssertEqual(box.bounds.maxX, 33, accuracy: 1e-6)
        // The middle lines run through the motif: each is split in two
        XCTAssertEqual(lines.count, 5)
        for l in lines.dropFirst() {
            let mid = CGPoint(x: (l.points[0].x + l.points[1].x) / 2, y: (l.points[0].y + l.points[1].y) / 2)
            XCTAssertFalse(a.matBounds.contains(mid))
        }
    }

    func testWeedingBetweenTwoObjects() {
        let lines = Weeding.lines(around: [rect(0, 0, 10, 10), rect(30, 0, 10, 10)], margin: 2, horizontal: 0, vertical: 1)
        // Vertical line at x = 20 lies in the gap: one full line
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].length, 14, accuracy: 1e-6)
    }

    // MARK: Points

    func testMoveDeleteInsertSplitPoint() {
        var s = rect(0, 0, 10, 10)
        let ref = s.point(near: CGPoint(x: 10.2, y: 0.1), radius: 1)!
        s.movePoint(ref, toMat: CGPoint(x: 15, y: 0))
        XCTAssertEqual(s.matBounds.maxX, 15, accuracy: 1e-6)
        XCTAssertEqual(s.matBounds.minX, 0, accuracy: 1e-6, "the rest stays in place")

        let (seg, at) = s.segment(near: CGPoint(x: 0, y: 5), radius: 1)!
        s.insertPoint(after: seg, atMat: at)
        XCTAssertEqual(s.paths[0].points.count, 5)

        s.deletePoint(PointRef(path: 0, index: 4))
        XCTAssertEqual(s.paths[0].points.count, 4)

        s.splitLine(at: PointRef(path: 0, index: 0))
        XCTAssertFalse(s.paths[0].closed)
        XCTAssertEqual(s.paths[0].points.count, 5)
    }

    func testEditingAShapeMakesItPlainLines() {
        var s = CutShape.basic(.standard(.rectangle), at: CGPoint(x: 10, y: 10))
        s.deletePoint(PointRef(path: 0, index: 0))
        XCTAssertNil(s.shapeSpec)
    }

    // MARK: Knife and eraser

    func testKnifeCutsIntoTwo() {
        let doc = CutDocument()
        let a = rect(0, 0, 20, 10)
        doc.data.shapes = [a]
        let pieces = doc.knife(from: CGPoint(x: 10, y: -5), to: CGPoint(x: 10, y: 15), selection: [], undoManager: nil)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(doc.data.shapes.count, 2)
    }

    func testKnifeMissLeavesObjects() {
        let doc = CutDocument()
        doc.data.shapes = [rect(0, 0, 20, 10)]
        XCTAssertTrue(doc.knife(from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 20), selection: [], undoManager: nil).isEmpty)
        XCTAssertEqual(doc.data.shapes.count, 1)
    }

    func testEraserRemovesPart() {
        let doc = CutDocument()
        let a = rect(0, 0, 20, 10)
        doc.data.shapes = [a]
        doc.erase(along: [CGPoint(x: 10, y: -5), CGPoint(x: 10, y: 15)], radius: 1, selection: [], undoManager: nil)
        XCTAssertEqual(doc.data.shapes.count, 1, "the eraser keeps one object")
        XCTAssertEqual(doc.data.shapes[0].matPaths.count, 2)
    }

    // MARK: Plan

    func testPlanMatchesTheJob() {
        var data = ProjectData()
        data.shapes = [rect(10, 10, 20, 20), rect(50, 10, 10, 10)]
        let plan = CutPlan.make(for: data)
        let job = GPGLBuilder.build(for: data)
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.cutLengthMM, job.cutLengthMM, accuracy: 1e-6)
        XCTAssertGreaterThan(plan.seconds, 0)
        XCTAssertEqual(plan.toolChanges, 0)
    }

    // MARK: Print & Cut

    func testPrintAndCutSearchesMarksFirstAndShiftsCoordinates() {
        var data = ProjectData()
        data.shapes = [rect(50, 60, 20, 20)]
        data.printCut.enabled = true // A4, marks 10 mm from the edge
        let job = GPGLBuilder.build(for: data)
        let n = try! XCTUnwrap(job.replyAfter)
        XCTAssertEqual(Array(job.commands[2..<n]),
                       ["TB50,0", "TB99", "TB52,2", "TB51,400", "TB53,10", "TB55,1", "TB123,5540,3800,0,0"])
        XCTAssertTrue(job.commands.contains("Z5540,3800"))
        // (50, 60) on the mat is (40, 50) from the top left mark
        XCTAssertTrue(job.commands.contains("M1000,800"))
    }

    func testNoMarksForClassicMachines() {
        var data = ProjectData()
        data.shapes = [rect(50, 60, 20, 20)]
        data.printCut.enabled = true
        let job = GPGLBuilder.build(for: data, model: PlotterModel.all.first { $0.name == "Cameo 2" }!)
        XCTAssertNil(job.replyAfter)
        XCTAssertFalse(job.commands.contains("TB99"))
    }

    func testMarksAndPDF() {
        var data = ProjectData()
        data.printCut.enabled = true
        XCTAssertEqual(data.printCut.marks.count, 5)
        XCTAssertGreaterThan(PrintAndCutPrinter.pdf(for: data, outlines: true).count, 500)
    }

    func testOldProjectWithoutPrintAndCutDecodes() throws {
        let json = #"{"formatVersion":1,"shapes":[],"mat":"mat12x12","settings":{"tool":"autoBlade","holder":1,"depth":2,"pressure":10,"speed":5,"passes":1}}"#
        let data = try JSONDecoder().decode(ProjectData.self, from: Data(json.utf8))
        XCTAssertFalse(data.usesPrintAndCut)
    }

    // MARK: Settings

    func testInchConversion() {
        XCTAssertEqual(LengthUnit.inch.mmPerUnit, 25.4)
        XCTAssertTrue(LengthUnit.inch.text(25.4).hasPrefix("1"))
        XCTAssertTrue(LengthUnit.inch.text(25.4).hasSuffix(" in"))
    }

    func testNewProjectUsesDefaults() {
        let d = UserDefaults.standard
        let keys = [NewProjectDefaults.matKey, NewProjectDefaults.profile1Key, NewProjectDefaults.profile2Key]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        d.set(MatType.mat12x24.rawValue, forKey: NewProjectDefaults.matKey)
        d.set("leatherThin", forKey: NewProjectDefaults.profile1Key)
        d.set("embossPaper", forKey: NewProjectDefaults.profile2Key)
        let doc = CutDocument.newProject()
        XCTAssertEqual(doc.data.mat, .mat12x24)
        XCTAssertEqual(doc.data.settings(slot: 1).tool, .kraftBlade)
        XCTAssertEqual(doc.data.settings(slot: 2).tool, .emboss)
    }
}
