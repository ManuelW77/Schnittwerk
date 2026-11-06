// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
// Renders app icon concepts as 1024×1024 PNG.
// Usage: swift tools/icon/render_icons.swift <output-dir> [variant]
import AppKit
import CoreText

let S: CGFloat = 1024
let inset: CGFloat = 100              // macOS icon grid: 824 pt body
let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius: CGFloat = 185

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func squircle(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Letter "S" as a path, centred in `box`.
func letterS(font: String, size: CGFloat, center: CGPoint) -> CGPath {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    var ch: [UniChar] = Array("S".utf16), g = [CGGlyph](repeating: 0, count: 1)
    CTFontGetGlyphsForCharacters(f, &ch, &g, 1)
    let p = CTFontCreatePathForGlyph(f, g[0], nil)!
    let b = p.boundingBoxOfPath
    var t = CGAffineTransform(translationX: center.x - b.midX, y: center.y - b.midY)
    return p.copy(using: &t)!
}

func render(_ name: String, dir: String, draw: (CGContext) -> Void) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Soft drop shadow under the body, like system icons
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
    ctx.addPath(squircle(body)); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle(body)); ctx.clip()
    draw(ctx)
    ctx.restoreGState()
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    print("wrote \(dir)/\(name).png")
}

func grid(_ ctx: CGContext, step: CGFloat, color: CGColor, width: CGFloat, majorEvery: Int, major: CGColor) {
    var i = 0
    var v = body.minX
    while v <= body.maxX + 1 {
        ctx.setStrokeColor(i % majorEvery == 0 ? major : color)
        ctx.setLineWidth(i % majorEvery == 0 ? width * 2 : width)
        ctx.move(to: CGPoint(x: v, y: body.minY)); ctx.addLine(to: CGPoint(x: v, y: body.maxY)); ctx.strokePath()
        ctx.move(to: CGPoint(x: body.minX, y: v)); ctx.addLine(to: CGPoint(x: body.maxX, y: v)); ctx.strokePath()
        v += step; i += 1
    }
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let center = CGPoint(x: S / 2, y: S / 2)

// A) Cutting mat with a weeded vinyl "S" being lifted off
if only == nil || only == "A" {
render("A-matte", dir: dir) { ctx in
    let g = CGGradient(colorsSpace: nil, colors: [rgb(0x2F7D5B), rgb(0x1F5E44)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    grid(ctx, step: 824 / 12, color: rgb(0xFFFFFF, 0.16), width: 2, majorEvery: 3, major: rgb(0xFFFFFF, 0.28))
    let s = letterS(font: "AvenirNext-Heavy", size: 640, center: CGPoint(x: center.x, y: center.y - 10))
    // Shadow of the lifted letter
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 10, height: -18), blur: 22, color: rgb(0x0B2A1E, 0.55))
    ctx.addPath(s); ctx.setFillColor(rgb(0xF4D35E)); ctx.fillPath()
    ctx.restoreGState()
    // Vinyl sheen
    ctx.saveGState()
    ctx.addPath(s); ctx.clip()
    let sheen = CGGradient(colorsSpace: nil, colors: [rgb(0xFFF3B0), rgb(0xF4D35E), rgb(0xE0B63A)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 260, y: 860), end: CGPoint(x: 760, y: 160), options: [])
    ctx.restoreGState()
    // Cut edge
    ctx.addPath(s); ctx.setStrokeColor(rgb(0x8A6A12, 0.55)); ctx.setLineWidth(4); ctx.strokePath()
}
}

// B) Paper sheet with a die-cut "S", colour shows through
if only == nil || only == "B" {
render("B-papier", dir: dir) { ctx in
    ctx.setFillColor(rgb(0xD9503F)); ctx.fill(body)                 // card underneath
    let s = letterS(font: "AvenirNext-Heavy", size: 620, center: center)
    // Paper with S-shaped hole (even-odd)
    let paper = CGMutablePath()
    paper.addRect(body.insetBy(dx: -50, dy: -50))
    paper.addPath(s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: rgb(0x5A1A12, 0.55))
    ctx.addPath(paper); ctx.setFillColor(rgb(0xFBF7EF)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    // Fine paper grain
    ctx.saveGState()
    ctx.addPath(paper); ctx.clip(using: .evenOdd)
    var seed: UInt64 = 7
    for _ in 0..<5000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let x = CGFloat(seed >> 33 % 1024) .truncatingRemainder(dividingBy: S)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let y = CGFloat(seed >> 33).truncatingRemainder(dividingBy: S)
        ctx.setFillColor(rgb(0x8C7B5E, 0.06)); ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
    }
    ctx.restoreGState()
    ctx.addPath(s); ctx.setStrokeColor(rgb(0xB9AE98, 0.8)); ctx.setLineWidth(3); ctx.strokePath()
}
}

// C) Blade cutting the outline of an "S" into blue vinyl (kiss cut), top view
if only == nil || only == "C" {
render("C-klinge", dir: dir) { ctx in
    let g = CGGradient(colorsSpace: nil, colors: [rgb(0x4A86D0), rgb(0x2C5FA3)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Mat grid, as in the editor
    grid(ctx, step: 824 / 12, color: rgb(0xFFFFFF, 0.15), width: 2, majorEvery: 3, major: rgb(0xFFFFFF, 0.27))
    let sPath = letterS(font: "AvenirNext-Heavy", size: 600, center: CGPoint(x: center.x - 30, y: center.y - 20))
    // Groove of the cut, then a thin light edge
    ctx.addPath(sPath); ctx.setLineJoin(.round)
    // Red cut line (same colour as cut lines in the editor), with a dark rim for contrast
    ctx.setStrokeColor(rgb(0x7A1712, 0.55)); ctx.setLineWidth(26); ctx.strokePath()
    ctx.addPath(sPath); ctx.setStrokeColor(rgb(0xE5382D)); ctx.setLineWidth(19); ctx.strokePath()
    ctx.addPath(sPath); ctx.setStrokeColor(rgb(0xFF8A7A, 0.85)); ctx.setLineWidth(5); ctx.strokePath()
    // Point on the outline furthest up and right: the blade sits there
    var tip = CGPoint.zero; var best = -CGFloat.infinity
    sPath.applyWithBlock { e in
        let n = e.pointee.type == .addCurveToPoint ? 3 : (e.pointee.type == .addQuadCurveToPoint ? 2 : (e.pointee.type == .closeSubpath ? 0 : 1))
        if n > 0 { let pt = e.pointee.points[n - 1]; if pt.x + pt.y > best { best = pt.x + pt.y; tip = pt } }
    }
    // Blade holder seen from above: round cap, slight offset towards top right
    let capCenter = CGPoint(x: tip.x + 38, y: tip.y + 38)
    let cap = CGRect(x: capCenter.x - 78, y: capCenter.y - 78, width: 156, height: 156)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 10, height: -14), blur: 22, color: rgb(0x0E2442, 0.6))
    ctx.addEllipse(in: cap); ctx.setFillColor(rgb(0xE6E8EC)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: cap); ctx.clip()
    let capGrad = CGGradient(colorsSpace: nil, colors: [rgb(0xFAFBFC), rgb(0xB4BAC3)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(capGrad, start: CGPoint(x: cap.minX, y: cap.maxY), end: CGPoint(x: cap.maxX, y: cap.minY), options: [])
    ctx.restoreGState()
    ctx.addEllipse(in: cap.insetBy(dx: 34, dy: 34)); ctx.setFillColor(rgb(0xF2B134)); ctx.fillPath()
    ctx.addEllipse(in: cap.insetBy(dx: 64, dy: 64)); ctx.setFillColor(rgb(0x6B5A2A)); ctx.fillPath()
}
}
