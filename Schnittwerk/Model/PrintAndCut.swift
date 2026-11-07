// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Print & Cut: the design is printed with registration marks, the sheet
// lies at the top left of the mat, and the plotter's optical sensor
// finds the marks before it cuts. Mark type, sizes and commands follow
// the open-source project inkscape-silhouette (Silhouette "type 2"
// marks: a square at the top left, corner angles at the top right and
// bottom left).

import CoreGraphics
import Foundation

enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case a4, letter
    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .a4: CGSize(width: 210, height: 297)
        case .letter: CGSize(width: 215.9, height: 279.4)
        }
    }

    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "US Letter"
        }
    }
}

struct PrintAndCut: Codable, Equatable {
    var enabled = false
    var paper: PaperSize = .a4
    /// Distance of the marks from the paper edge (mm).
    var insetMM: Double = 10

    /// Length of the corner angles (TB51: 400 units = 20 mm).
    static let markLength: CGFloat = 20
    /// Line width of the marks (TB53: 10 units = 0.5 mm).
    static let markThickness: CGFloat = 0.5
    /// Side of the square mark at the top left.
    static let squareSize: CGFloat = 5
    static let insetRange = 5.0...30.0

    var paperSize: CGSize { paper.size }
    private var inset: CGFloat { CGFloat(min(max(insetMM, Self.insetRange.lowerBound), Self.insetRange.upperBound)) }

    /// Top left corner of the mark frame on the mat (= on the paper).
    var origin: CGPoint { CGPoint(x: inset, y: inset) }
    /// Size of the mark frame: from the square to the corner angles.
    var frameSize: CGSize { CGSize(width: paperSize.width - 2 * inset, height: paperSize.height - 2 * inset) }

    /// Where the design may go: inside the frame, clear of the marks.
    var designArea: CGRect {
        let gap = Self.markLength + 2
        return CGRect(x: origin.x, y: origin.y, width: frameSize.width, height: frameSize.height)
            .divided(atDistance: gap, from: .minYEdge).remainder
            .divided(atDistance: gap, from: .maxYEdge).remainder
    }

    /// The marks as filled areas (mat mm).
    var marks: [Polyline] {
        let t = Self.markThickness, l = Self.markLength, q = Self.squareSize
        let o = origin, w = frameSize.width, h = frameSize.height
        func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> Polyline {
            Polyline(points: [CGPoint(x: x, y: y), CGPoint(x: x + rw, y: y), CGPoint(x: x + rw, y: y + rh),
                              CGPoint(x: x, y: y + rh)], closed: true)
        }
        let right = o.x + w, bottom = o.y + h
        return [
            rect(o.x, o.y, q, q),
            // Top right: legs to the left and down
            rect(right - l, o.y, l, t), rect(right - t, o.y, t, l),
            // Bottom left: legs to the right and up
            rect(o.x, bottom - t, l, t), rect(o.x, bottom - l, t, l),
        ]
    }

    /// Commands that make the plotter search the marks (Cameo 3 and 4 line).
    var searchCommands: [String] {
        let u = GPGLBuilder.units
        return [
            "TB50,0",
            "TB99",
            "TB52,2",                             // mark type: Cameo, Portrait
            "TB51,\(u(Self.markLength))",         // length of the marks
            "TB53,\(u(Self.markThickness))",      // width of the marks
            "TB55,1",
            "TB123,\(u(frameSize.height)),\(u(frameSize.width)),\(u(max(origin.y - 10, 0))),\(u(max(origin.x - 10, 0)))",
        ]
    }
}

extension ProjectData {
    var printCut: PrintAndCut {
        get { printAndCut ?? PrintAndCut() }
        set { printAndCut = newValue }
    }

    var usesPrintAndCut: Bool { printAndCut?.enabled == true }
}
