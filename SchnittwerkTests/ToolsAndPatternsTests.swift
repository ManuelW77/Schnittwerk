// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Schnittwerk

final class ToolsAndPatternsTests: XCTestCase {
    private let square = Polyline(points: [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 20),
                                           CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 40)], closed: true)

    private func shape(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, slot: Int = 1) -> CutShape {
        var s = CutShape(name: "R", matPaths: [Polyline(points: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                                                                  CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)],
                                                         closed: true)])
        s.toolSlot = slot
        return s
    }

    // MARK: Cut options

    func testAccelerationAndOffsetCorrection() {
        var s = CutSettings()
        s.options.acceleration = 1
        s.options.offsetAdjust = -4
        let job = GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x12)
        XCTAssertTrue(job.commands.contains("TJ1"))
        XCTAssertFalse(job.commands.contains("TJ3"))
        XCTAssertTrue(job.commands.contains("FC14,1,1"))
    }

    func testTrackEnhancingOnlyWhenOn() {
        XCTAssertFalse(GPGLBuilder.build(paths: [square], settings: CutSettings(), mat: .mat12x12).commands.contains("FY0"))
        var s = CutSettings()
        s.options.trackEnhancing = true
        XCTAssertTrue(GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x12).commands.contains("FY0"))
    }

    func testOvercutRunsPastTheStart() {
        var s = CutSettings()
        s.options.overcut = true
        let job = GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x12)
        let body = job.commands.filter { $0.hasPrefix("D") }
        // back at the start (400,200), then 1 mm further along the top edge
        XCTAssertEqual(Array(body.suffix(2)), ["D400,200", "D400,220"])
        XCTAssertEqual(job.cutLengthMM, 81, accuracy: 1e-6)
    }

    func testSharpCornersLiftAtEachCorner() {
        var s = CutSettings()
        s.options.sharpCorners = true
        let strokes = GPGLBuilder.strokes(square, settings: s)
        XCTAssertEqual(strokes.count, 4) // 3 inner corners split the outline
        // The first stroke runs 0.4 mm past the corner at (30, 20)
        XCTAssertEqual(strokes[0].last!.x, 30.4, accuracy: 1e-6)
        XCTAssertEqual(strokes[1].first, CGPoint(x: 30, y: 20))
    }

    func testPenGetsNoOvercut() {
        var s = CutSettings()
        s.tool = .pen
        s.options.overcut = true
        XCTAssertEqual(GPGLBuilder.strokes(square, settings: s).first?.count, 5)
    }

    func testPunchPiercesTheCentre() {
        var s = CutSettings()
        s.tool = .punch
        s.holder = 2
        let dot = Patterns.dot(at: CGPoint(x: 50, y: 60))
        let job = GPGLBuilder.build(paths: [dot], settings: s, mat: .mat12x12)
        let body = job.commands.filter { $0.hasPrefix("M") || $0.hasPrefix("D") }
        XCTAssertEqual(Array(body.prefix(2)), ["M1200,1000", "D1200,1000"])
        XCTAssertTrue(job.commands.contains("FC0,1,2"))
    }

    func testKraftBladeSetsDepthOnCameo4Only() {
        var s = CutSettings()
        s.tool = .kraftBlade
        s.holder = 2
        s.depth = 7
        XCTAssertTrue(GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x12).commands.contains("TF7,2"))
        XCTAssertFalse(GPGLBuilder.build(paths: [square], settings: s, mat: .mat12x12, model: .cameo3)
            .commands.contains { $0.hasPrefix("TF") })
    }

    // MARK: Two tools

    func testTwoToolsInOneJobPenFirst() {
        var data = ProjectData()
        data.shapes = [shape(10, 10, 20, 20, slot: 1), shape(50, 10, 20, 20, slot: 2)]
        data.setSettings(.holder2Default, slot: 2)
        let job = GPGLBuilder.build(for: data)
        let j2 = job.commands.firstIndex(of: "J2")!
        let j1 = job.commands.firstIndex(of: "J1")!
        XCTAssertLessThan(j2, j1, "the pen in holder 2 draws before the blade cuts")
        XCTAssertEqual(job.pathCount, 2)
    }

    func testOneHolderMachineCutsEverythingWithTool1() {
        var data = ProjectData()
        data.shapes = [shape(10, 10, 20, 20, slot: 1), shape(50, 10, 20, 20, slot: 2)]
        let job = GPGLBuilder.build(for: data, model: PlotterModel.all.first { $0.name == "Portrait 3" }!)
        XCTAssertFalse(job.commands.contains("J2"))
        XCTAssertEqual(job.commands.filter { $0.hasPrefix("M") }.count, 3) // 2 lines + end
    }

    func testOldProjectWithHolder2Migrates() throws {
        var old = ProjectData()
        old.settings.holder = 2
        old.settings.tool = .pen
        old.shapes = [shape(10, 10, 5, 5)]
        var data = try JSONDecoder().decode(ProjectData.self, from: JSONEncoder().encode(old))
        data.migrateHolder()
        XCTAssertEqual(data.shapes[0].toolSlot, 2)
        XCTAssertEqual(data.settings(slot: 2).tool, .pen)
        XCTAssertEqual(data.settings(slot: 1).tool, .autoBlade)
    }

    func testSettingsWithoutOptionsDecode() throws {
        let json = #"{"tool":"autoBlade","holder":1,"depth":3,"pressure":12,"speed":4,"passes":1}"#
        let s = try JSONDecoder().decode(CutSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.options, CutOptions())
        XCTAssertEqual(s.depth, 3)
    }

    func testPresetIDsAreUnique() {
        XCTAssertEqual(Set(MaterialPreset.all.map(\.id)).count, MaterialPreset.all.count)
        XCTAssertTrue(MaterialPreset.all.contains { $0.tool == .kraftBlade })
    }

    // MARK: Patterns

    func testHatchFillsInsideOnly() {
        let lines = Patterns.hatch([square], spacing: 2, angle: 0)
        XCTAssertEqual(lines.count, 10)
        for l in lines {
            XCTAssertEqual(l.points.map(\.x).min()!, 10, accuracy: 1e-6)
            XCTAssertEqual(l.points.map(\.x).max()!, 30, accuracy: 1e-6)
        }
    }

    func testHatchSkipsHoles() {
        let hole = Polyline(points: [CGPoint(x: 15, y: 25), CGPoint(x: 25, y: 25),
                                     CGPoint(x: 25, y: 35), CGPoint(x: 15, y: 35)], closed: true)
        let lines = Patterns.hatch([square, hole], spacing: 2, angle: 0)
        // rows through the hole are split in two
        XCTAssertGreaterThan(lines.count, 10)
    }

    func testStippleOutlineSpacing() {
        let s = CutShape(name: "S", matPaths: [square])
        let pts = Patterns.stipplePoints([s], mode: .outline, spacing: 5)
        XCTAssertEqual(pts.count, 16) // 80 mm outline / 5 mm
    }

    func testStippleFillStaysInside() {
        let s = CutShape(name: "S", matPaths: [square])
        let pts = Patterns.stipplePoints([s], mode: .fill, spacing: 2)
        XCTAssertFalse(pts.isEmpty)
        XCTAssertTrue(pts.allSatisfy { $0.x > 10 && $0.x < 30 && $0.y > 20 && $0.y < 40 })
    }

    // MARK: Modify and replicate

    @MainActor
    func testDivideMakesThreePieces() {
        let doc = CutDocument()
        let a = shape(0, 0, 20, 20), b = shape(10, 0, 20, 20)
        doc.data.shapes = [a, b]
        let result = doc.modify(.divide, ids: [a.id, b.id], undoManager: nil)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(doc.data.shapes.count, 3)
    }

    @MainActor
    func testSubtractAllKeepsEachObject() {
        let doc = CutDocument()
        let a = shape(0, 0, 20, 20), b = shape(30, 0, 20, 20), cutter = shape(15, 5, 20, 10)
        doc.data.shapes = [a, b, cutter]
        let result = doc.modify(.subtractAll, ids: [a.id, b.id, cutter.id], undoManager: nil)
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(doc.data.shapes.contains { $0.id == cutter.id })
    }

    @MainActor
    func testReleaseCompoundKeepsHoles() {
        let doc = CutDocument()
        let ring = [Polyline(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)], closed: true),
                    Polyline(points: [CGPoint(x: 2, y: 2), CGPoint(x: 8, y: 2), CGPoint(x: 8, y: 8), CGPoint(x: 2, y: 8)], closed: true),
                    Polyline(points: [CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 10), CGPoint(x: 20, y: 10)], closed: true)]
        let s = CutShape(name: "C", matPaths: ring)
        doc.data.shapes = [s]
        let result = doc.modify(.releaseCompound, ids: [s.id], undoManager: nil)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(doc.data.shapes.map { $0.matPaths.count }.sorted(), [1, 2])
    }

    @MainActor
    func testGridAndMirrorAndRotateCopies() {
        let doc = CutDocument()
        let a = shape(0, 0, 10, 10)
        doc.data.shapes = [a]
        XCTAssertEqual(doc.replicateGrid([a.id], rows: 2, columns: 3, gap: 2, undoManager: nil).count, 5)
        let last = doc.data.shapes.last!.matBounds
        XCTAssertEqual(last.minX, 24, accuracy: 1e-6)
        XCTAssertEqual(last.minY, 12, accuracy: 1e-6)

        doc.data.shapes = [a]
        let m = doc.mirrorCopy([a.id], toward: .right, undoManager: nil)
        let copy = doc.data.shapes.first { m.contains($0.id) }!
        XCTAssertEqual(copy.matBounds.minX, 10, accuracy: 1e-6)
        XCTAssertEqual(copy.scaleX, -1)

        doc.data.shapes = [a]
        XCTAssertEqual(doc.rotateCopies([a.id], count: 4, undoManager: nil).count, 3)
    }

    @MainActor
    func testFillMatUsesTheWholeMat() {
        let doc = CutDocument()
        let a = shape(100, 100, 100, 100)
        doc.data.shapes = [a]
        doc.fillMat([a.id], gap: 0, undoManager: nil)
        XCTAssertEqual(doc.data.shapes.count, 9) // 3 × 3 on 304.8 mm
        XCTAssertEqual(doc.data.shapes[0].matBounds.minX, 0, accuracy: 1e-6)
    }

    @MainActor
    func testScaleAroundCentre() {
        let doc = CutDocument()
        let a = shape(0, 0, 10, 10)
        doc.data.shapes = [a]
        doc.scale([a.id], percent: 200, undoManager: nil)
        let b = doc.data.shapes[0].matBounds
        XCTAssertEqual(b.width, 20, accuracy: 1e-6)
        XCTAssertEqual(b.midX, 5, accuracy: 1e-6)
    }
}
