// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Gives access to the NSWindow a SwiftUI view lives in.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
    }
}

enum SourceFileDetacher {
    /// Turns a window opened from an SVG/DXF into an untitled project:
    /// it no longer points to the file, so neither autosave nor ⌘S can
    /// write to it. The project counts as changed, so closing asks to save.
    /// Returns true when the document was found and detached.
    @MainActor
    @discardableResult
    static func detach(window: NSWindow, name: String?) -> Bool {
        guard let doc = window.windowController?.document as? NSDocument ?? NSDocumentController.shared.document(for: window)
        else {
            debugLog("detach: no document for window \(window.title)")
            return false
        }
        guard let type = doc.fileType, let ut = UTType(type), !ut.conforms(to: .schnittwerkProject) else {
            return true // already a project
        }
        doc.fileURL = nil
        doc.fileType = UTType.schnittwerkProject.identifier
        if let name { doc.displayName = name }
        doc.updateChangeCount(.changeDone)
        debugLog("detach: done, fileURL=\(String(describing: doc.fileURL)) type=\(doc.fileType ?? "-")")
        return true
    }

    private static func debugLog(_ text: String) {
        if ProcessInfo.processInfo.environment["SW_DEBUG"] != nil { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    }
}
