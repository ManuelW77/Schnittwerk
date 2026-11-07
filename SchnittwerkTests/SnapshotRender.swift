// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
// Renders editor views to PNG for a visual check (only when SW_SNAPSHOT_DIR is set).

import SwiftUI
import XCTest
@testable import Schnittwerk

@MainActor
final class SnapshotRender: XCTestCase {
    func testRenderEditor() throws {
        guard let dir = ProcessInfo.processInfo.environment["SW_SNAPSHOT_DIR"] else { throw XCTSkip("no SW_SNAPSHOT_DIR") }
        let doc = CutDocument()
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="80mm" height="60mm" viewBox="0 0 80 60"><rect x="2" y="2" width="76" height="56" rx="6"/><circle cx="25" cy="30" r="12"/><path d="M45 18 l12 24 l12 -24 z"/></svg>"#
        var shape = CutShape(name: "Test", matPaths: try SVGImporter.parse(Data(svg.utf8)).paths)
        shape.position = CGPoint(x: 80, y: 60)
        shape.rotation = 15
        var text = CutShape.text(TextSpec(text: "Schnittwerk", fontName: "HelveticaNeue-Bold", sizeMM: 25), at: CGPoint(x: 30, y: 150))!
        text.cutEnabled = true
        var off = shape.duplicated()
        off.position = CGPoint(x: 290, y: 250)
        doc.data.shapes = [shape, text, off]

        let canvas = MatCanvasView(document: doc, selection: .constant([shape.id]), zoom: 1, tool: .constant(.select))
        let r = ImageRenderer(content: canvas.background(Color.white))
        r.scale = 1
        let img = try XCTUnwrap(r.nsImage)
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("canvas.png"))

        let inspector = InspectorView(document: doc, selection: .constant([text.id])).frame(width: 320, height: 900)
        let r2 = ImageRenderer(content: inspector.background(Color.white))
        let png2 = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r2.nsImage?.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png2.write(to: URL(fileURLWithPath: dir).appendingPathComponent("inspector.png"))
    }

    func testRenderShapes() throws {
        guard let dir = ProcessInfo.processInfo.environment["SW_SNAPSHOT_DIR"] else { throw XCTSkip("no SW_SNAPSHOT_DIR") }
        let doc = CutDocument()
        var rect = ShapeSpec.standard(.rectangle)
        rect.cornerRadiusMM = 8
        rect.widthMM = 70
        let shapes = [
            CutShape.basic(rect, at: CGPoint(x: 20, y: 20)),
            CutShape.basic(.standard(.ellipse), at: CGPoint(x: 110, y: 20)),
            CutShape.basic(.standard(.polygon), at: CGPoint(x: 180, y: 20)),
            CutShape.basic(.standard(.star), at: CGPoint(x: 250, y: 20)),
        ]
        doc.data.shapes = shapes
        let text = CutShape.text(TextSpec(text: "Hallo", fontName: "HelveticaNeue-Bold", sizeMM: 25), at: CGPoint(x: 30, y: 110))!
        doc.data.shapes.append(text)
        doc.addOffset(ids: [text.id], distance: 3, roundCorners: true, undoManager: nil)
        doc.addOffset(ids: [shapes[3].id], distance: 4, roundCorners: false, undoManager: nil)
        doc.combine(.subtract, ids: [shapes[0].id, shapes[1].id], undoManager: nil)
        let canvas = MatCanvasView(document: doc, selection: .constant([shapes[3].id]), zoom: 1, tool: .constant(.select))
        let r = ImageRenderer(content: canvas.background(Color.white))
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r.nsImage?.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("shapes.png"))

        for (i, name) in [(0, "inspector-rect"), (3, "inspector-star")] {
            let inspector = InspectorView(document: doc, selection: .constant([shapes[i].id])).frame(width: 320, height: 900)
            let r2 = ImageRenderer(content: inspector.background(Color.white))
            let png2 = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r2.nsImage?.tiffRepresentation))?.representation(using: .png, properties: [:]))
            try png2.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testRenderToolsAndPanels() throws {
        guard let dir = ProcessInfo.processInfo.environment["SW_SNAPSHOT_DIR"] else { throw XCTSkip("no SW_SNAPSHOT_DIR") }
        func save(_ view: some View, _ name: String) throws {
            let r = ImageRenderer(content: view.background(Color.white))
            r.scale = 2
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(r.nsImage?.tiffRepresentation))?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let doc = CutDocument()
        let heart = CutShape.basic(.standard(.star), at: CGPoint(x: 20, y: 20))
        var circle = CutShape.basic(.standard(.ellipse), at: CGPoint(x: 120, y: 20))
        circle.toolSlot = 2
        doc.data.shapes = [heart, circle]
        doc.addFill(ids: [circle.id], pattern: .crossHatch, spacing: 3, angle: 45, undoManager: nil)
        let rect = CutShape.basic(.standard(.rectangle), at: CGPoint(x: 200, y: 20))
        doc.data.shapes.append(rect)
        doc.addStipple(ids: [rect.id], mode: .fill, spacing: 3, replace: false, undoManager: nil)
        doc.rotateCopies([heart.id], count: 6, undoManager: nil)
        var s2 = CutSettings.holder2Default
        s2.tool = .emboss
        doc.data.setSettings(s2, slot: 2)
        let canvas = MatCanvasView(document: doc, selection: .constant([circle.id]), zoom: 1, tool: .constant(.select))
        try save(ZStack(alignment: .topLeading) {
            canvas.padding(.leading, 52)
            ToolPalette(tool: .constant(.select), addShape: { _ in }).padding(12)
        }.overlay(alignment: .bottom) { ToolLegend(data: doc.data).padding(12) }, "tools-canvas.png")
        // Forms only draw inside a real window
        func saveInWindow(_ view: some View, _ name: String, size: CGSize) throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        try saveInWindow(EditPanelView(document: doc, selection: .constant([circle.id])), "edit-panel.png",
                         size: CGSize(width: 340, height: 1700))
        try saveInWindow(CutPanelView(document: doc, slot: .constant(2)), "cut-panel.png",
                         size: CGSize(width: 340, height: 1400))
        try saveInWindow(InspectorView(document: doc, selection: .constant([circle.id])), "object-panel.png",
                         size: CGSize(width: 340, height: 1000))
    }

    func testRenderPrintCutPointsAndPreview() throws {
        guard let dir = ProcessInfo.processInfo.environment["SW_SNAPSHOT_DIR"] else { throw XCTSkip("no SW_SNAPSHOT_DIR") }
        let doc = CutDocument()
        let star = CutShape.basic(.standard(.star), at: CGPoint(x: 40, y: 50))
        let text = CutShape.text(TextSpec(text: "Hi", fontName: "HelveticaNeue-Bold", sizeMM: 40), at: CGPoint(x: 110, y: 50))!
        doc.data.shapes = [star, text]
        doc.data.printCut.enabled = true
        doc.addWeedingLines(ids: [text.id], margin: 4, horizontal: 1, vertical: 1, undoManager: nil)
        func shot(_ view: some View, _ name: String, _ size: CGSize) throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        try shot(MatCanvasView(document: doc, selection: .constant([star.id]), zoom: 1, tool: .constant(.points)), "printcut-points.png",
                 CGSize(width: 860, height: 860))
        try shot(CutPreviewSheet(data: doc.data, model: .cameo4, onCut: {}), "preview.png", CGSize(width: 640, height: 720))
        try shot(CutPanelView(document: doc, slot: .constant(1)), "cut-printcut.png", CGSize(width: 340, height: 1500))
    }
}
