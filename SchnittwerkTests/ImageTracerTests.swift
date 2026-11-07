// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Schnittwerk

final class ImageTracerTests: XCTestCase {
    /// 200 × 100 px. Rects are given with y down (like on the mat).
    private func image(background: CGColor?, ink: CGColor, rects: [CGRect], holes: [CGRect] = []) -> CGImage {
        let w = 200, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // y down
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.setFillColor(ink)
        rects.forEach { ctx.fill($0) }
        ctx.setBlendMode(.copy)
        ctx.setFillColor(background ?? CGColor(gray: 0, alpha: 0))
        holes.forEach { ctx.fill($0) }
        return ctx.makeImage()!
    }

    private let white = CGColor(gray: 1, alpha: 1)
    private let black = CGColor(gray: 0, alpha: 1)

    func testRectangleWithHole() throws {
        let img = image(background: white, ink: black,
                        rects: [CGRect(x: 20, y: 20, width: 100, height: 60)],
                        holes: [CGRect(x: 50, y: 40, width: 40, height: 20)])
        var settings = TraceSettings()
        settings.widthMM = 200 // 1 px = 1 mm
        settings.smoothing = 0
        let lines = try ImageTracer.trace(img, settings: settings)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy(\.closed))
        let outer = try XCTUnwrap(lines.max { $0.bounds.width < $1.bounds.width }).bounds
        XCTAssertEqual(outer.minX, 20, accuracy: 1.5)
        XCTAssertEqual(outer.maxX, 120, accuracy: 1.5)
        XCTAssertEqual(outer.minY, 20, accuracy: 1.5) // not upside down
        XCTAssertEqual(outer.maxY, 80, accuracy: 1.5)
        let inner = try XCTUnwrap(lines.min { $0.bounds.width < $1.bounds.width }).bounds
        XCTAssertEqual(inner.minX, 50, accuracy: 1.5)
        XCTAssertEqual(inner.minY, 40, accuracy: 1.5)
    }

    func testSizeFollowsWidth() throws {
        let img = image(background: white, ink: black, rects: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        var settings = TraceSettings()
        settings.widthMM = 50 // 0.25 mm per px
        settings.smoothing = 0
        let lines = try ImageTracer.trace(img, settings: settings)
        XCTAssertEqual(lines.bounds.width, 25, accuracy: 0.6)
        XCTAssertEqual(lines.bounds.height, 25, accuracy: 0.6)
        XCTAssertEqual(ImageTracer.heightMM(for: img, widthMM: 50), 25, accuracy: 0.001)
    }

    func testSmallSpecksAreDropped() throws {
        let img = image(background: white, ink: black,
                        rects: [CGRect(x: 20, y: 20, width: 60, height: 60), CGRect(x: 150, y: 50, width: 2, height: 2)])
        var settings = TraceSettings()
        settings.widthMM = 200
        settings.minSizeMM = 5
        XCTAssertEqual(try ImageTracer.trace(img, settings: settings).count, 1)
        settings.minSizeMM = 0.5
        XCTAssertEqual(try ImageTracer.trace(img, settings: settings).count, 2)
    }

    func testInvertTracesTheLightPart() throws {
        let img = image(background: black, ink: white, rects: [CGRect(x: 40, y: 30, width: 50, height: 40)])
        var settings = TraceSettings()
        settings.widthMM = 200
        settings.invert = true
        let lines = try ImageTracer.trace(img, settings: settings)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.bounds.width, 50, accuracy: 2)
    }

    func testTransparencyIsUsedForLogos() throws {
        // White logo on a transparent background: invisible by brightness
        let img = image(background: nil, ink: white, rects: [CGRect(x: 30, y: 30, width: 40, height: 40)])
        XCTAssertTrue(ImageTracer.hasTransparency(img))
        var settings = TraceSettings()
        settings.widthMM = 200
        settings.useTransparency = true
        let lines = try ImageTracer.trace(img, settings: settings)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.bounds.minX, 30, accuracy: 1.5)
    }

    func testOpaqueImageHasNoTransparency() {
        let img = image(background: white, ink: black, rects: [])
        XCTAssertFalse(ImageTracer.hasTransparency(img))
    }

    func testLoadsAndTracesAPNGFile() throws {
        let img = image(background: white, ink: black, rects: [CGRect(x: 10, y: 10, width: 80, height: 40)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        XCTAssertTrue(ImageTracer.isImage(url))
        XCTAssertFalse(ImageTracer.isImage(URL(fileURLWithPath: "/x/logo.svg")))
        let loaded = try ImageTracer.loadImage(from: url)
        XCTAssertEqual(loaded.width, 200)
        var settings = TraceSettings()
        settings.widthMM = 200
        let lines = try ImageTracer.trace(loaded, settings: settings)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.bounds.minY, 10, accuracy: 1.5)
    }
}
