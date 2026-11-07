// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Print & Cut: the page to print, with the registration marks and the
// objects (filled in their colour, or as thin outlines).

import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PrintAndCutPrinter {
    static let pointsPerMM: CGFloat = 72 / 25.4

    /// One PDF page in paper size; the paper lies at the top left of the mat.
    static func pdf(for data: ProjectData, outlines: Bool) -> Data {
        let pc = data.printCut
        let size = pc.paperSize
        var box = CGRect(x: 0, y: 0, width: size.width * pointsPerMM, height: size.height * pointsPerMM)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        // Mat millimetres, y downwards
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: pointsPerMM, y: -pointsPerMM)

        func addPath(_ lines: [Polyline]) {
            for line in lines where line.points.count >= 2 {
                ctx.addLines(between: line.points)
                if line.closed { ctx.closePath() }
            }
        }
        let paper = CGRect(origin: .zero, size: size)
        for shape in data.shapes {
            let lines = shape.matPaths
            guard lines.contains(where: { $0.points.contains { paper.contains($0) } }) else { continue }
            if let rgb = shape.colorHex.flatMap(RGB.init(hex:)) {
                ctx.setFillColor(CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
                addPath(lines.filter(\.closed))
                ctx.fillPath(using: .evenOdd)
            }
            if outlines || shape.colorHex == nil {
                ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
                ctx.setLineWidth(0.1)
                addPath(lines)
                ctx.strokePath()
            }
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        addPath(pc.marks)
        ctx.fillPath()
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    static func savePDF(for data: ProjectData, outlines: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Print and Cut") + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pdf(for: data, outlines: outlines).write(to: url)
    }

    /// Print dialog at 100 %, without scaling.
    static func print(_ data: ProjectData, outlines: Bool) {
        guard let doc = PDFDocument(data: pdf(for: data, outlines: outlines)) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: false)?
            .runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
}
