// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later
//
// Keeps track of the open project windows, so the MCP server knows
// which project to work on: the window that was in front last.

import AppKit

/// A project the MCP tools work on, with the undo manager of its window.
struct DocumentContext {
    let document: CutDocument
    let undoManager: UndoManager?
    /// Selects objects in the window (nil in tests).
    var select: ((Set<UUID>) -> Void)?
}

@MainActor
final class DocumentRegistry {
    static let shared = DocumentRegistry()

    private struct Entry {
        weak var document: CutDocument?
        weak var window: NSWindow?
        var select: (Set<UUID>) -> Void
        var lastActive: Date
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.windowBecameActive(window) }
            })
        }
    }

    /// Called by every project window when it appears.
    func register(_ document: CutDocument, window: NSWindow, select: @escaping (Set<UUID>) -> Void) {
        let key = ObjectIdentifier(document)
        let isNew = entries[key]?.window !== window
        let active = isNew ? Date() : (entries[key]?.lastActive ?? Date())
        entries[key] = Entry(document: document, window: window, select: select, lastActive: active)
    }

    private func windowBecameActive(_ window: NSWindow) {
        for (key, entry) in entries where entry.window === window {
            entries[key]?.lastActive = Date()
        }
    }

    /// The project window that was in front last, if any is open.
    var current: DocumentContext? {
        entries = entries.filter { $0.value.document != nil && $0.value.window?.isVisible == true }
        guard let entry = entries.values.max(by: { $0.lastActive < $1.lastActive }),
              let document = entry.document else { return nil }
        return DocumentContext(document: document, undoManager: entry.window?.undoManager, select: entry.select)
    }

    /// Opens a new, empty project window.
    func openNewDocument() {
        NSDocumentController.shared.newDocument(nil)
    }
}
