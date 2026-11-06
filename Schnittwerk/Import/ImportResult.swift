// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// Result of reading a file: cut lines in mm (y down) plus notes
/// about parts that were skipped.
struct ImportResult {
    var paths: [Polyline]
    var warnings: [String]
}

enum ImportError: LocalizedError, Equatable {
    case unreadable
    case unsupportedFormat(String)
    case noGeometry

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "The file could not be read.")
        case .unsupportedFormat(let ext):
            return String(localized: "The file type “\(ext)” is not supported. Use SVG or DXF.")
        case .noGeometry:
            return String(localized: "The file contains no lines that can be cut.")
        }
    }
}

enum ShapeImporter {
    static let tolerance: CGFloat = 0.02

    /// Reads an SVG or DXF file and returns one object for the mat.
    static func importShape(from url: URL) throws -> (shape: CutShape, warnings: [String]) {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ImportError.unreadable }
        let ext = url.pathExtension.lowercased()
        let result: ImportResult
        switch ext {
        case "svg":
            result = try SVGImporter.parse(data)
        case "dxf":
            result = try DXFImporter.parse(data)
        default:
            throw ImportError.unsupportedFormat(ext)
        }
        guard !result.paths.isEmpty else { throw ImportError.noGeometry }
        let name = url.deletingPathExtension().lastPathComponent
        return (CutShape(name: name, matPaths: result.paths), result.warnings)
    }
}

extension CutShape {
    /// Moves the object onto the mat if it lies (partly) outside.
    /// Objects that fit stay where the file put them.
    mutating func placeInside(_ area: CGSize, margin: CGFloat = 10) {
        let b = matBounds
        let matRect = CGRect(origin: .zero, size: area)
        if matRect.contains(b) { return }
        position.x += margin - b.minX
        position.y += margin - b.minY
    }

    /// True if the object lies completely inside the cutting area.
    func fits(in area: CGSize) -> Bool {
        CGRect(origin: .zero, size: area).insetBy(dx: -0.01, dy: -0.01).contains(matBounds)
    }
}
