// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads the vector paths of a PDF (first page): what design apps like
// Affinity put on the clipboard or drag out. The content stream is
// scanned with CGPDFScanner; lines, curves and rectangles that are
// stroked or filled become cut lines. Clipping paths, text and images
// are skipped (with a note). Form XObjects (nested drawings) are followed.

import CoreGraphics
import Foundation

enum PDFImporter {
    static let mmPerPoint: CGFloat = 25.4 / 72

    static func parse(_ data: Data) throws -> ImportResult {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages >= 1,
              let page = document.page(at: 1) else { throw ImportError.unreadable }

        let collector = PDFPathCollector()
        collector.scan(CGPDFContentStreamCreateWithPage(page))

        // Page coordinates (points, y up) → mat millimetres (y down)
        let box = page.getBoxRect(.cropBox)
        let toMM = CGAffineTransform(a: mmPerPoint, b: 0, c: 0, d: -mmPerPoint,
                                     tx: -box.minX * mmPerPoint, ty: box.maxY * mmPerPoint)
        let lines = collector.path.polylines(tolerance: ShapeImporter.tolerance / mmPerPoint).applying(toMM)

        var warnings: [String] = []
        if document.numberOfPages > 1 {
            warnings.append(String(localized: "Only the first page of the PDF was used."))
        }
        if collector.sawText {
            warnings.append(String(localized: "Text was skipped. Convert text to curves in your design app first."))
        }
        if collector.sawImage {
            warnings.append(String(localized: "Images in the PDF were skipped."))
        }
        if collector.overBudget {
            warnings.append(String(localized: "The PDF is too complex; only part of it was read."))
        }
        return ImportResult(paths: lines, warnings: warnings)
    }
}

/// Walks a PDF content stream and collects the painted paths in page space.
final class PDFPathCollector {
    /// All painted paths, in page coordinates (points, y up).
    let path = CGMutablePath()
    var sawText = false
    var sawImage = false
    /// Set when a limit below stopped reading (protects against PDFs
    /// built to make the import explode).
    private(set) var overBudget = false

    static let maxDepth = 8
    static let maxFormCalls = 5_000
    static let maxPathElements = 2_000_000
    private var formCalls = 0
    private var pathElements = 0
    /// Forms being drawn right now (a form drawing itself is refused).
    private var activeForms: Set<Int> = []

    private var ctm = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    /// Path under construction, already in page coordinates.
    private var current = CGMutablePath()
    /// Current and subpath start point, in user space.
    private var point = CGPoint.zero
    private var depth = 0

    /// Scans the stream and releases it afterwards.
    func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < Self.maxDepth else {
            overBudget = true
            CGPDFContentStreamRelease(stream)
            return
        }
        depth += 1
        defer { depth -= 1 }
        let table = Self.makeTable()
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
        CGPDFContentStreamRelease(stream)
    }

    // MARK: - Operators

    fileprivate static func me(_ info: UnsafeMutableRawPointer?) -> PDFPathCollector? {
        info.map { Unmanaged<PDFPathCollector>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Pops `count` numbers; returns them in the order they were written.
    fileprivate static func numbers(_ s: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var result: [CGFloat] = []
        for _ in 0..<count {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &v) else { return nil }
            result.append(CGFloat(v))
        }
        return result.reversed()
    }

    private static func makeTable() -> CGPDFOperatorTableRef {
        let t = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(t, "q") { _, i in PDFPathCollector.me(i)?.save() }
        CGPDFOperatorTableSetCallback(t, "Q") { _, i in PDFPathCollector.me(i)?.restore() }
        CGPDFOperatorTableSetCallback(t, "cm") { s, i in
            guard let n = PDFPathCollector.numbers(s, 6) else { return }
            PDFPathCollector.me(i)?.concat(CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]))
        }
        CGPDFOperatorTableSetCallback(t, "m") { s, i in
            guard let n = PDFPathCollector.numbers(s, 2) else { return }
            PDFPathCollector.me(i)?.move(CGPoint(x: n[0], y: n[1]))
        }
        CGPDFOperatorTableSetCallback(t, "l") { s, i in
            guard let n = PDFPathCollector.numbers(s, 2) else { return }
            PDFPathCollector.me(i)?.line(CGPoint(x: n[0], y: n[1]))
        }
        CGPDFOperatorTableSetCallback(t, "c") { s, i in
            guard let n = PDFPathCollector.numbers(s, 6) else { return }
            PDFPathCollector.me(i)?.curve(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]), CGPoint(x: n[4], y: n[5]))
        }
        CGPDFOperatorTableSetCallback(t, "v") { s, i in
            guard let n = PDFPathCollector.numbers(s, 4), let c = PDFPathCollector.me(i) else { return }
            c.curve(c.point, CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]))
        }
        CGPDFOperatorTableSetCallback(t, "y") { s, i in
            guard let n = PDFPathCollector.numbers(s, 4) else { return }
            let end = CGPoint(x: n[2], y: n[3])
            PDFPathCollector.me(i)?.curve(CGPoint(x: n[0], y: n[1]), end, end)
        }
        CGPDFOperatorTableSetCallback(t, "h") { _, i in PDFPathCollector.me(i)?.close() }
        CGPDFOperatorTableSetCallback(t, "re") { s, i in
            guard let n = PDFPathCollector.numbers(s, 4) else { return }
            PDFPathCollector.me(i)?.rect(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
        }
        // Painting: keep the path. "n" ends a path without painting
        // (clipping paths), so it is dropped.
        for op in ["S", "f", "F", "f*", "B", "B*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, i in PDFPathCollector.me(i)?.paint(close: false) }
        }
        for op in ["s", "b", "b*"] {
            CGPDFOperatorTableSetCallback(t, op) { _, i in PDFPathCollector.me(i)?.paint(close: true) }
        }
        CGPDFOperatorTableSetCallback(t, "n") { _, i in PDFPathCollector.me(i)?.discard() }
        CGPDFOperatorTableSetCallback(t, "BT") { _, i in PDFPathCollector.me(i)?.sawText = true }
        CGPDFOperatorTableSetCallback(t, "BI") { _, i in PDFPathCollector.me(i)?.sawImage = true }
        CGPDFOperatorTableSetCallback(t, "Do") { s, i in
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(s, &name), let name else { return }
            PDFPathCollector.me(i)?.drawObject(named: name, scanner: s)
        }
        return t
    }

    // MARK: - State

    private func save() { stack.append(ctm) }

    private func restore() { if let last = stack.popLast() { ctm = last } }

    private func concat(_ m: CGAffineTransform) { ctm = m.concatenating(ctm) }

    private func page(_ p: CGPoint) -> CGPoint { p.applying(ctm) }

    /// Counts one path element; false once the budget is used up.
    private func spend() -> Bool {
        guard pathElements < Self.maxPathElements else { overBudget = true; return false }
        pathElements += 1
        return true
    }

    private func move(_ p: CGPoint) {
        guard spend() else { return }
        current.move(to: page(p))
        point = p
    }

    private func line(_ p: CGPoint) {
        guard !current.isEmpty else { return move(p) }
        guard spend() else { return }
        current.addLine(to: page(p))
        point = p
    }

    private func curve(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) {
        guard !current.isEmpty else { return move(end) }
        guard spend() else { return }
        current.addCurve(to: page(end), control1: page(c1), control2: page(c2))
        point = end
    }

    private func close() { if !current.isEmpty { current.closeSubpath() } }

    private func rect(_ r: CGRect) {
        guard spend() else { return }
        current.move(to: page(CGPoint(x: r.minX, y: r.minY)))
        current.addLine(to: page(CGPoint(x: r.maxX, y: r.minY)))
        current.addLine(to: page(CGPoint(x: r.maxX, y: r.maxY)))
        current.addLine(to: page(CGPoint(x: r.minX, y: r.maxY)))
        current.closeSubpath()
        point = CGPoint(x: r.minX, y: r.minY)
    }

    private func paint(close: Bool) {
        if close { self.close() }
        path.addPath(current)
        current = CGMutablePath()
    }

    private func discard() { current = CGMutablePath() }

    /// `Do`: a form XObject is drawn like a small page of its own.
    private func drawObject(named name: UnsafePointer<CChar>, scanner: CGPDFScannerRef) {
        let stream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(stream, "XObject", name) else { return }
        var xStream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &xStream), let xStream,
              let dict = CGPDFStreamGetDictionary(xStream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
        switch String(cString: subtype) {
        case "Image":
            sawImage = true
        case "Form":
            let key = unsafeBitCast(xStream, to: Int.self) // address of the stream
            guard formCalls < Self.maxFormCalls, !activeForms.contains(key) else {
                overBudget = true
                return
            }
            formCalls += 1
            activeForms.insert(key)
            defer { activeForms.remove(key) }
            save()
            var matrix: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                var v = [CGPDFReal](repeating: 0, count: 6)
                for k in 0..<6 { _ = CGPDFArrayGetNumber(matrix, k, &v[k]) }
                concat(CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]))
            }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
            let saved = current
            current = CGMutablePath()
            scan(CGPDFContentStreamCreateWithStream(xStream, resources ?? dict, stream))
            current = saved
            restore()
        default:
            break
        }
    }
}
