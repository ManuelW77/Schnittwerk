// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Vector drawings from the clipboard: copy in Affinity, Illustrator,
// Inkscape, Figma … and paste on the mat. SVG is preferred (exact paths),
// PDF is the fallback most design apps always provide.

import AppKit
import UniformTypeIdentifiers

enum PasteboardImport {
    /// Types the mat accepts for pasting.
    static let acceptedTypes: [UTType] = [.svg, .pdf, .plainText]

    /// The clipboard content as SVG or PDF data, best first.
    static func payload(from pasteboard: NSPasteboard) -> (data: Data, format: String)? {
        // SVG under its own or an app-specific type that conforms to SVG
        for type in pasteboard.types ?? [] {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .svg),
                  let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            return (data, "svg")
        }
        if let data = pasteboard.data(forType: .pdf), !data.isEmpty {
            return (data, "pdf")
        }
        // "Copy as SVG" in many apps puts the markup on the clipboard as text
        if let text = pasteboard.string(forType: .string), isSVGMarkup(text) {
            return (Data(text.utf8), "svg")
        }
        return nil
    }

    static func canPaste(_ pasteboard: NSPasteboard = .general) -> Bool {
        payload(from: pasteboard) != nil
    }

    static func isSVGMarkup(_ text: String) -> Bool {
        let head = text.prefix(4000).lowercased()
        return head.contains("<svg")
    }

    /// One object from the clipboard, or nil if it holds no drawing.
    static func shape(from pasteboard: NSPasteboard = .general) throws -> (shape: CutShape, warnings: [String])? {
        guard let payload = payload(from: pasteboard) else { return nil }
        return try ShapeImporter.importShape(data: payload.data, fileExtension: payload.format,
                                             name: String(localized: "Pasted"))
    }
}
