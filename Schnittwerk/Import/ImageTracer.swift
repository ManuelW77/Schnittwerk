// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Traces a raster image (PNG, JPG, HEIC …) into cut lines. The image is
// first turned into black and white (brightness threshold, or the
// transparency of the image), then Apple's Vision framework finds the
// outlines. Works best for logos, lettering and silhouettes.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct TraceSettings: Equatable {
    /// Brightness below which a pixel counts as part of the motif (0…1).
    var threshold: Double = 0.5
    /// 0 = follow the pixels closely, 1 = very smooth and round.
    var smoothing: Double = 0.3
    /// Outlines smaller than this (mm, longer side) are dropped.
    var minSizeMM: Double = 1
    /// Trace the light parts instead of the dark ones.
    var invert = false
    /// Use the transparency instead of the brightness (images with alpha).
    var useTransparency = false
    /// Width of the result on the mat, in mm.
    var widthMM: Double = 100
}

enum ImageTracer {
    /// Longest side the image is reduced to before tracing (pixels).
    static let maxWorkingSize = 2000

    enum TraceError: LocalizedError {
        case unreadable, failed
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "The image could not be read.")
            case .failed: String(localized: "The image could not be traced.")
            }
        }
    }

    static func loadImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw TraceError.unreadable }
        // Thumbnail API: applies the EXIF orientation and limits the size
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxWorkingSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw TraceError.unreadable }
        return image
    }

    /// File types the tracer accepts.
    static let contentTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// True if the image has see-through parts worth tracing.
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let alpha = pixels(of: image, alphaOnly: true) else { return false }
        let clear = alpha.data.reduce(0) { $0 + ($1 < 128 ? 1 : 0) }
        return clear > alpha.data.count / 50 // at least 2 % transparent
    }

    /// Height of the result in mm for the given width.
    static func heightMM(for image: CGImage, widthMM: Double) -> Double {
        widthMM * Double(image.height) / Double(max(image.width, 1))
    }

    // MARK: - Tracing

    /// Cut lines in mm, top left corner at (0, 0), `settings.widthMM` wide.
    static func trace(_ image: CGImage, settings: TraceSettings) throws -> [Polyline] {
        guard let mask = blackAndWhite(image, settings: settings) else { throw TraceError.failed }
        return try trace(mask: mask, imageWidth: image.width, settings: settings)
    }

    /// Outlines of the black parts of a mask made by `maskImage`
    /// (with border). `imageWidth` is the width without the border.
    static func trace(mask: CGImage, imageWidth: Int, settings: TraceSettings) throws -> [Polyline] {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = true
        request.contrastAdjustment = 1
        request.maximumImageDimension = max(mask.width, mask.height)
        let handler = VNImageRequestHandler(cgImage: mask, options: [:])
        do { try handler.perform([request]) } catch { throw TraceError.failed }
        guard let observation = request.results?.first else { return [] }

        let w = max(settings.widthMM, 1)
        let pixelMM = w / Double(max(imageWidth, 1))
        let padW = Double(mask.width), padH = Double(mask.height), border = Double(borderPixels)
        let tolerance = pixelMM * (0.4 + settings.smoothing * 2.5)
        let smooth = settings.smoothing >= 0.15

        var result: [Polyline] = []
        var stack = observation.topLevelContours
        while let contour = stack.popLast() {
            stack.append(contentsOf: contour.childContours)
            let points = contour.normalizedPoints.map {
                // Vision: 0…1 of the padded mask, origin bottom left
                CGPoint(x: (Double($0.x) * padW - border) * pixelMM,
                        y: ((1 - Double($0.y)) * padH - border) * pixelMM)
            }
            guard points.count >= 3 else { continue }
            let box = Polyline(points: points, closed: true).bounds
            guard max(box.width, box.height) >= settings.minSizeMM else { continue }
            if let line = outline(points, tolerance: tolerance, smooth: smooth,
                                  cornerAngle: 40 + settings.smoothing * 50) {
                result.append(line)
            }
        }
        return result
    }

    /// Simplified (and optionally rounded) closed outline. Rounding cuts
    /// corners (Chaikin), so the line never bulges past the motif; corners
    /// sharper than `cornerAngle` degrees stay sharp.
    private static func outline(_ points: [CGPoint], tolerance: CGFloat, smooth: Bool,
                                cornerAngle: CGFloat) -> Polyline? {
        var simple = FreehandBuilder.simplify(points, tolerance: tolerance)
        if simple.count > 1, let f = simple.first, let l = simple.last, f.distance(to: l) < 1e-6 {
            simple.removeLast()
        }
        guard simple.count >= 3 else { return nil }
        guard smooth else { return Polyline(points: simple, closed: true) }
        return Polyline(points: chaikin(simple, cornerAngle: cornerAngle, iterations: 3), closed: true)
    }

    /// Corner cutting on a closed polygon; corners stay where they are.
    static func chaikin(_ points: [CGPoint], cornerAngle: CGFloat, iterations: Int) -> [CGPoint] {
        let n = points.count
        guard n >= 3 else { return points }
        var pts = points
        var corner = (0..<n).map { i -> Bool in
            let a = points[(i + n - 1) % n], b = points[i], c = points[(i + 1) % n]
            let d1 = atan2(b.y - a.y, b.x - a.x), d2 = atan2(c.y - b.y, c.x - b.x)
            var turn = abs(d2 - d1)
            if turn > .pi { turn = 2 * .pi - turn }
            return turn * 180 / .pi > cornerAngle
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        for _ in 0..<iterations {
            var next: [CGPoint] = [], nextCorner: [Bool] = []
            next.reserveCapacity(pts.count * 2)
            for i in pts.indices {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                let aCorner = corner[i], bCorner = corner[(i + 1) % pts.count]
                if aCorner { next.append(a); nextCorner.append(true) }
                // The two cut points of this edge (none towards a corner)
                if !aCorner { next.append(lerp(a, b, 0.25)); nextCorner.append(false) }
                if !bCorner { next.append(lerp(a, b, 0.75)); nextCorner.append(false) }
            }
            pts = next
            corner = nextCorner
            if pts.count > 20000 { break }
        }
        return pts
    }

    // MARK: - Black and white

    private struct Pixels {
        var data: [UInt8]
        let width: Int
        let height: Int
    }

    /// 8-bit grey pixels (brightness on white) or the alpha channel.
    private static func pixels(of image: CGImage, alphaOnly: Bool) -> Pixels? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: alphaOnly ? 0 : 255, count: w * h)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            let ctx: CGContext?
            if alphaOnly {
                ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            } else {
                ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                // Transparent parts count as white paper
                ctx?.setFillColor(gray: 1, alpha: 1)
                ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            guard let ctx else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Pixels(data: data, width: w, height: h) : nil
    }

    /// White border around the mask, in pixels.
    static let borderPixels = 2

    /// Motif black, everything else white, with a white border so outlines
    /// touching the edge still close.
    static func blackAndWhite(_ image: CGImage, settings: TraceSettings) -> CGImage? {
        guard let src = pixels(of: image, alphaOnly: settings.useTransparency) else { return nil }
        let cut = UInt8(min(max(settings.threshold, 0.01), 0.99) * 255)
        return maskImage(width: src.width, height: src.height) { i in
            var ink = settings.useTransparency ? src.data[i] >= 128 : src.data[i] < cut
            if settings.invert { ink.toggle() }
            return ink
        }
    }

    /// Black-and-white mask with a white border; `ink(i)` tells for pixel
    /// index i (row by row, top first) whether it belongs to the motif.
    static func maskImage(width: Int, height: Int, ink: (Int) -> Bool) -> CGImage? {
        let border = borderPixels
        let w = width + 2 * border, h = height + 2 * border
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<height {
            for x in 0..<width where ink(y * width + x) {
                out[(y + border) * w + x + border] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
