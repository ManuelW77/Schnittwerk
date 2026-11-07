// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import XCTest
@testable import Schnittwerk

final class ColorTracerTests: XCTestCase {
    /// 200 × 100 px, white (or transparent) background, three coloured
    /// boxes. Rects use y down.
    private func image(transparent: Bool = false) -> CGImage {
        let w = 200, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        if !transparent {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 80))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 75, y: 10, width: 50, height: 80))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 140, y: 30, width: 40, height: 40))
        return ctx.makeImage()!
    }

    private func settings() -> TraceSettings {
        var s = TraceSettings()
        s.widthMM = 200 // 1 px = 1 mm
        s.smoothing = 0
        return s
    }

    func testFindsColoursAndBackground() throws {
        let a = try XCTUnwrap(ColorTracer.analyze(image(), colorCount: 4))
        XCTAssertEqual(a.colors.count, 4)
        let bg = try XCTUnwrap(a.background)
        XCTAssertGreaterThan(a.colors[bg].r, 0.9) // white
        XCTAssertEqual(bg, 0, "most common colour first")
        XCTAssertTrue(a.colors.contains { $0.r > 0.6 && $0.g < 0.3 }, "red found")
    }

    func testEachColourBecomesALayerInPlace() throws {
        let a = try XCTUnwrap(ColorTracer.analyze(image(), colorCount: 4))
        let layerOf: [Int?] = a.colors.indices.map { $0 == a.background ? nil : $0 }
        let layers = try ColorTracer.layers(a, layerOf: layerOf, outline: false, settings: settings())
        XCTAssertEqual(layers.count, 3)
        XCTAssertTrue(layers.allSatisfy { $0.lines.count == 1 })
        let blue = try XCTUnwrap(layers.first { ($0.color?.b ?? 0) > 0.6 })
        XCTAssertEqual(blue.lines.bounds.minX, 140, accuracy: 2)
        XCTAssertEqual(blue.lines.bounds.minY, 30, accuracy: 2)
        XCTAssertEqual(blue.lines.bounds.width, 40, accuracy: 2)
    }

    func testSameLayerNumberMergesColours() throws {
        let a = try XCTUnwrap(ColorTracer.analyze(image(), colorCount: 4))
        var layerOf: [Int?] = a.colors.indices.map { $0 == a.background ? nil : $0 }
        let colours = a.colors.indices.filter { $0 != a.background }
        layerOf[colours[1]] = colours[0]
        let layers = try ColorTracer.layers(a, layerOf: layerOf, outline: true, settings: settings())
        XCTAssertEqual(layers.count, 3) // outline + merged + single
        XCTAssertEqual(layers.first?.id, -1)
        XCTAssertEqual(layers.first?.lines.count, 3) // outline of all three boxes
        XCTAssertEqual(layers.filter { $0.id != -1 }.map(\.lines.count).sorted(), [1, 2])
    }

    func testTransparencyIsTheBackground() throws {
        let a = try XCTUnwrap(ColorTracer.analyze(image(transparent: true), colorCount: 3))
        XCTAssertNil(a.background)
        XCTAssertEqual(a.colors.count, 3)
        let layers = try ColorTracer.layers(a, layerOf: a.colors.indices.map { $0 }, outline: false, settings: settings())
        XCTAssertEqual(layers.count, 3)
    }

    func testHexRoundTrip() {
        let c = RGB(r: 0.2, g: 0.4, b: 0.6)
        XCTAssertEqual(c.hex, "#336699")
        XCTAssertEqual(RGB(hex: "#336699")?.hex, "#336699")
        XCTAssertNil(RGB(hex: "nope"))
    }
}
