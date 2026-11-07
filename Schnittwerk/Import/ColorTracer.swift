// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Traces an image in several colours: the image is reduced to a few
// colours (k-means in Lab colour space), the background is found, and
// each colour becomes its own layer of cut lines, e.g. for vinyl in
// several colours.

import CoreGraphics
import Foundation

/// A colour, components 0…1.
struct RGB: Equatable, Hashable, Sendable {
    var r: Double, g: Double, b: Double

    var hex: String {
        func c(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }
}

/// Result of reducing an image to a few colours.
struct ColorAnalysis: @unchecked Sendable {
    /// Size of the analysed (reduced) image in pixels.
    let width: Int
    let height: Int
    /// The colours, most common first.
    let colors: [RGB]
    /// Share of each colour in the image (0…1).
    let shares: [Double]
    /// Colour index per pixel, row by row from the top;
    /// `transparent` for see-through pixels.
    let labels: [UInt8]
    /// Index of the colour that forms the background, if any.
    let background: Int?

    static let transparent: UInt8 = 255
}

/// One colour of the traced image.
struct TraceLayer: Identifiable {
    /// Colour index, or -1 for the outline of the whole motif.
    let id: Int
    let name: String
    /// Display colour; nil for a single-colour trace.
    let color: RGB?
    let lines: [Polyline]
}

enum ColorTracer {
    /// Longest side of the image for the colour analysis (pixels).
    static let workingSize = 1000
    static let colorRange = 2...8

    // MARK: - Analysis

    static func analyze(_ image: CGImage, colorCount: Int) -> ColorAnalysis? {
        let k = min(max(colorCount, colorRange.lowerBound), colorRange.upperBound)
        guard let px = rgba(image) else { return nil }
        let n = px.width * px.height

        // Slight blur, so paint texture and noise do not form own colours
        let blurred = boxBlur(px.rgb, width: px.width, height: px.height, passes: 2)
        var lab = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            let l = toLab(blurred[i * 3], blurred[i * 3 + 1], blurred[i * 3 + 2])
            lab[i * 3] = l.0; lab[i * 3 + 1] = l.1; lab[i * 3 + 2] = l.2
        }
        let opaque = (0..<n).filter { px.alpha[$0] >= 128 }
        guard !opaque.isEmpty else { return nil }

        // k-means on a sample of the pixels
        let step = max(opaque.count / 40000, 1)
        let sample = stride(from: 0, to: opaque.count, by: step).map { opaque[$0] }
        var centers = kMeansPlusPlus(lab, sample: sample, k: min(k, sample.count))
        for _ in 0..<20 {
            var sum = [Double](repeating: 0, count: centers.count * 3)
            var count = [Int](repeating: 0, count: centers.count)
            for i in sample {
                let c = nearest(lab, i, centers)
                sum[c * 3] += Double(lab[i * 3]); sum[c * 3 + 1] += Double(lab[i * 3 + 1]); sum[c * 3 + 2] += Double(lab[i * 3 + 2])
                count[c] += 1
            }
            var moved: Float = 0
            for c in centers.indices where count[c] > 0 {
                let new = (Float(sum[c * 3] / Double(count[c])), Float(sum[c * 3 + 1] / Double(count[c])),
                           Float(sum[c * 3 + 2] / Double(count[c])))
                moved = max(moved, abs(new.0 - centers[c].0) + abs(new.1 - centers[c].1) + abs(new.2 - centers[c].2))
                centers[c] = new
            }
            if moved < 0.2 { break }
        }

        // Every pixel gets its nearest colour, then a majority filter
        // removes single stray pixels
        var labels = [UInt8](repeating: ColorAnalysis.transparent, count: n)
        for i in opaque { labels[i] = UInt8(nearest(lab, i, centers)) }
        labels = majorityFilter(labels, width: px.width, height: px.height, passes: 2)

        // Colour = mean of the original (unblurred) pixels
        var sum = [Double](repeating: 0, count: centers.count * 3)
        var count = [Int](repeating: 0, count: centers.count)
        for i in 0..<n where labels[i] != ColorAnalysis.transparent {
            let c = Int(labels[i])
            sum[c * 3] += Double(px.rgb[i * 3]); sum[c * 3 + 1] += Double(px.rgb[i * 3 + 1]); sum[c * 3 + 2] += Double(px.rgb[i * 3 + 2])
            count[c] += 1
        }
        // Most common first; empty colours are dropped
        let order = centers.indices.filter { count[$0] > 0 }.sorted { count[$0] > count[$1] }
        var remap = [UInt8](repeating: ColorAnalysis.transparent, count: 256)
        for (newIndex, old) in order.enumerated() { remap[old] = UInt8(newIndex) }
        labels = labels.map { $0 == ColorAnalysis.transparent ? $0 : remap[Int($0)] }
        let colors = order.map { c in
            RGB(r: sum[c * 3] / Double(count[c]), g: sum[c * 3 + 1] / Double(count[c]), b: sum[c * 3 + 2] / Double(count[c]))
        }
        let shares = order.map { Double(count[$0]) / Double(n) }

        return ColorAnalysis(width: px.width, height: px.height, colors: colors, shares: shares,
                             labels: labels, background: background(labels, width: px.width, height: px.height))
    }

    /// The colour along the image edge, if the image has no transparency.
    private static func background(_ labels: [UInt8], width: Int, height: Int) -> Int? {
        let total = labels.count
        let clear = labels.reduce(0) { $0 + ($1 == ColorAnalysis.transparent ? 1 : 0) }
        if clear > total / 50 { return nil } // transparency is the background
        var edge: [Int: Int] = [:]
        var edgeCount = 0
        func add(_ i: Int) {
            let l = labels[i]
            guard l != ColorAnalysis.transparent else { return }
            edge[Int(l), default: 0] += 1
            edgeCount += 1
        }
        for x in 0..<width { add(x); add((height - 1) * width + x) }
        for y in 0..<height { add(y * width); add(y * width + width - 1) }
        guard let best = edge.max(by: { $0.value < $1.value }), edgeCount > 0,
              Double(best.value) / Double(edgeCount) >= 0.4 else { return nil }
        return best.key
    }

    // MARK: - Layers

    /// Cut lines per layer (mm, top left at 0, 0). `layerOf[c]` is the
    /// layer number of colour c (colours with the same number form one
    /// layer), or nil to leave the colour out. With `outline`, the
    /// outline of the whole motif comes first.
    static func layers(_ a: ColorAnalysis, layerOf: [Int?], outline: Bool,
                       settings: TraceSettings) throws -> [TraceLayer] {
        var result: [TraceLayer] = []
        let labels = a.labels
        if outline {
            let bg = a.background.map(UInt8.init)
            guard let mask = ImageTracer.maskImage(width: a.width, height: a.height, ink: { i in
                labels[i] != ColorAnalysis.transparent && labels[i] != bg
            }) else { throw ImageTracer.TraceError.failed }
            let lines = try ImageTracer.trace(mask: mask, imageWidth: a.width, settings: settings)
            if !lines.isEmpty {
                result.append(TraceLayer(id: -1, name: String(localized: "Outline"),
                                         color: RGB(r: 0.3, g: 0.3, b: 0.3), lines: lines))
            }
        }
        let numbers = Set(a.colors.indices.compactMap { c in c < layerOf.count ? layerOf[c] : nil }).sorted()
        for number in numbers {
            let members = a.colors.indices.filter { $0 < layerOf.count && layerOf[$0] == number }
            var inLayer = [Bool](repeating: false, count: 256)
            members.forEach { inLayer[$0] = true }
            guard let mask = ImageTracer.maskImage(width: a.width, height: a.height, ink: { inLayer[Int(labels[$0])] })
            else { throw ImageTracer.TraceError.failed }
            let lines = try ImageTracer.trace(mask: mask, imageWidth: a.width, settings: settings)
            guard !lines.isEmpty else { continue }
            result.append(TraceLayer(id: number, name: String(localized: "Layer \(number + 1)"),
                                     color: mixed(members.map { (a.colors[$0], a.shares[$0]) }), lines: lines))
        }
        return result
    }

    /// Average colour, weighted by share.
    private static func mixed(_ parts: [(RGB, Double)]) -> RGB {
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return parts.first?.0 ?? RGB(r: 0.5, g: 0.5, b: 0.5) }
        return RGB(r: parts.reduce(0) { $0 + $1.0.r * $1.1 } / total,
                   g: parts.reduce(0) { $0 + $1.0.g * $1.1 } / total,
                   b: parts.reduce(0) { $0 + $1.0.b * $1.1 } / total)
    }

    // MARK: - Pixels

    private struct RGBAPixels {
        let width: Int, height: Int
        /// r, g, b per pixel (0…1), on white where see-through.
        var rgb: [Float]
        var alpha: [UInt8]
    }

    private static func rgba(_ image: CGImage) -> RGBAPixels? {
        let scale = min(1, Double(workingSize) / Double(max(image.width, image.height)))
        let w = max(Int((Double(image.width) * scale).rounded()), 1)
        let h = max(Int((Double(image.height) * scale).rounded()), 1)
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        let ok = raw.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = [Float](repeating: 1, count: w * h * 3)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let a = raw[i * 4 + 3]
            alpha[i] = a
            let af = Float(a) / 255
            // Premultiplied on transparent black → composite on white
            for c in 0..<3 { rgb[i * 3 + c] = Float(raw[i * 4 + c]) / 255 + (1 - af) }
        }
        return RGBAPixels(width: w, height: h, rgb: rgb, alpha: alpha)
    }

    private static func boxBlur(_ src: [Float], width w: Int, height h: Int, passes: Int) -> [Float] {
        var a = src, b = src
        for _ in 0..<passes {
            for y in 0..<h {
                for x in 0..<w {
                    var s: (Float, Float, Float) = (0, 0, 0)
                    var n: Float = 0
                    for yy in max(y - 1, 0)...min(y + 1, h - 1) {
                        for xx in max(x - 1, 0)...min(x + 1, w - 1) {
                            let j = (yy * w + xx) * 3
                            s.0 += a[j]; s.1 += a[j + 1]; s.2 += a[j + 2]
                            n += 1
                        }
                    }
                    let i = (y * w + x) * 3
                    b[i] = s.0 / n; b[i + 1] = s.1 / n; b[i + 2] = s.2 / n
                }
            }
            swap(&a, &b)
        }
        return a
    }

    private static func majorityFilter(_ src: [UInt8], width w: Int, height h: Int, passes: Int) -> [UInt8] {
        var a = src, b = src
        var votes = [Int](repeating: 0, count: 256)
        for _ in 0..<passes {
            for y in 0..<h {
                for x in 0..<w {
                    var best = a[y * w + x], bestCount = 0
                    var seen: [UInt8] = []
                    for yy in max(y - 1, 0)...min(y + 1, h - 1) {
                        for xx in max(x - 1, 0)...min(x + 1, w - 1) {
                            let l = a[yy * w + xx]
                            if votes[Int(l)] == 0 { seen.append(l) }
                            votes[Int(l)] += 1
                        }
                    }
                    for l in seen {
                        if votes[Int(l)] > bestCount { best = l; bestCount = votes[Int(l)] }
                        votes[Int(l)] = 0
                    }
                    // Keep the pixel unless a clear majority disagrees
                    b[y * w + x] = bestCount >= 5 ? best : a[y * w + x]
                }
            }
            swap(&a, &b)
        }
        return a
    }

    // MARK: - Colour math

    private typealias Lab = (Float, Float, Float)

    private static func toLab(_ r: Float, _ g: Float, _ b: Float) -> Lab {
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        let R = lin(min(max(r, 0), 1)), G = lin(min(max(g, 0), 1)), B = lin(min(max(b, 0), 1))
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func nearest(_ lab: [Float], _ i: Int, _ centers: [Lab]) -> Int {
        let l = lab[i * 3], a = lab[i * 3 + 1], b = lab[i * 3 + 2]
        var best = 0, bestD = Float.greatestFiniteMagnitude
        for (c, center) in centers.enumerated() {
            let d = (l - center.0) * (l - center.0) + (a - center.1) * (a - center.1) + (b - center.2) * (b - center.2)
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    /// k-means++ start values with a fixed random seed (same result every time).
    private static func kMeansPlusPlus(_ lab: [Float], sample: [Int], k: Int) -> [Lab] {
        var rng = SplitMix(seed: 0x5C41_77E8)
        func point(_ i: Int) -> Lab { (lab[i * 3], lab[i * 3 + 1], lab[i * 3 + 2]) }
        var centers = [point(sample[Int(rng.next() % UInt64(sample.count))])]
        var dist = [Float](repeating: .greatestFiniteMagnitude, count: sample.count)
        while centers.count < k {
            let c = centers.last!
            var total: Double = 0
            for (j, i) in sample.enumerated() {
                let p = point(i)
                let d = (p.0 - c.0) * (p.0 - c.0) + (p.1 - c.1) * (p.1 - c.1) + (p.2 - c.2) * (p.2 - c.2)
                dist[j] = min(dist[j], d)
                total += Double(dist[j])
            }
            guard total > 0 else { break } // fewer distinct colours than k
            var target = Double(rng.next() % 1_000_000) / 1_000_000 * total
            var pick = sample.count - 1
            for j in sample.indices {
                target -= Double(dist[j])
                if target <= 0 { pick = j; break }
            }
            centers.append(point(sample[pick]))
        }
        return centers
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
