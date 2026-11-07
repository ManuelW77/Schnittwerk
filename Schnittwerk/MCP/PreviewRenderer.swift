// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders the mat with all objects to a PNG, so an AI can look at
// its own result. Each object is labelled with its number from
// get_document (#1, #2, …).

import AppKit
import CoreGraphics

enum PreviewRenderer {
    /// PNG of the mat. `maxPixels` limits the longer side.
    static func png(of data: ProjectData, maxPixels: Int = 1400) -> Data? {
        var area = data.mat.displaySize
        if data.mat == .roll {
            let maxY = data.shapes.map(\.matBounds.maxY).max() ?? 0
            area.height = min(max(area.height, maxY + 50), data.mat.size.height)
        }
        let margin: CGFloat = 10 // mm around the mat
        let total = CGSize(width: area.width + 2 * margin, height: area.height + 2 * margin)
        let scale = CGFloat(max(maxPixels, 100)) / max(total.width, total.height)
        let w = Int((total.width * scale).rounded()), h = Int((total.height * scale).rounded())

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // y down, millimetres
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: margin, y: margin)

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: -margin, y: -margin, width: total.width, height: total.height))
        let matRect = CGRect(origin: .zero, size: area)
        ctx.setFillColor(gray: 0.96, alpha: 1)
        ctx.fill(matRect)

        // Grid like the printed mat: every quarter inch, stronger every inch
        let quarter = MatGrid.inch / CGFloat(MatGrid.subdivisions)
        for (i, step) in stride(from: CGFloat(0), through: max(area.width, area.height), by: quarter).enumerated() {
            let strong = i % MatGrid.subdivisions == 0
            ctx.setStrokeColor(gray: strong ? 0.72 : 0.87, alpha: 1)
            ctx.setLineWidth((strong ? 1.0 : 0.6) / scale)
            if step <= area.width {
                ctx.move(to: CGPoint(x: step, y: 0)); ctx.addLine(to: CGPoint(x: step, y: area.height))
            }
            if step <= area.height {
                ctx.move(to: CGPoint(x: 0, y: step)); ctx.addLine(to: CGPoint(x: area.width, y: step))
            }
            ctx.strokePath()
        }
        ctx.setStrokeColor(gray: 0.6, alpha: 1)
        ctx.setLineWidth(1 / scale)
        ctx.stroke(matRect)

        for shape in data.shapes {
            let path = CGMutablePath()
            for line in shape.matPaths where line.points.count >= 2 {
                path.addLines(between: line.points)
                if line.closed { path.closeSubpath() }
            }
            let outside = !shape.fits(in: data.mat.size)
            let color: NSColor = !shape.cutEnabled ? .gray : (outside ? .orange : .systemRed)
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(0.12).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5 / scale)
            if !shape.cutEnabled { ctx.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Numbers, drawn in pixels so they stay readable
        NSGraphicsContext.saveGraphicsState()
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = ns
        var used: [CGRect] = [] // label boxes in pixels, to avoid overlaps
        for (i, shape) in data.shapes.enumerated() {
            let b = shape.matBounds
            let label = NSAttributedString(string: "#\(i + 1)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor.systemBlue,
                .backgroundColor: NSColor.white.withAlphaComponent(0.8),
            ])
            let size = label.size()
            var box = CGRect(x: (b.minX + margin) * scale, y: (b.minY + margin) * scale - 17,
                             width: size.width + 3, height: size.height)
            while used.contains(where: { $0.intersects(box) }) { box.origin.x += box.width }
            used.append(box)
            ctx.saveGState()
            ctx.translateBy(x: -margin, y: -margin)
            ctx.scaleBy(x: 1 / scale, y: 1 / scale)
            label.draw(at: box.origin)
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
