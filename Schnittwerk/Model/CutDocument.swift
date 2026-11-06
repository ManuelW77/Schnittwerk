// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let schnittwerkProject = UTType(exportedAs: "de.manuelweiser.schnittwerk.project")
    static let dxf = UTType(filenameExtension: "dxf") ?? .data
}

/// Content of a `.schnittwerk` file (JSON).
struct ProjectData: Codable, Equatable {
    var formatVersion = 1
    var shapes: [CutShape] = []
    var mat: MatType = .mat12x12
    var settings = CutSettings()
}

/// One open project window.
final class CutDocument: ReferenceFileDocument, ObservableObject {
    static var readableContentTypes: [UTType] { [.schnittwerkProject] }

    @Published var data: ProjectData

    init() {
        data = ProjectData()
    }

    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = try JSONDecoder().decode(ProjectData.self, from: raw)
    }

    func snapshot(contentType: UTType) throws -> ProjectData { data }

    func fileWrapper(snapshot: ProjectData, configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(snapshot))
    }

    // MARK: - Changes with undo

    /// Changes the project and registers an undo step.
    func update(_ actionName: String? = nil, undoManager: UndoManager?, _ change: (inout ProjectData) -> Void) {
        let before = data
        var after = data
        change(&after)
        guard after != before else { return }
        data = after
        registerUndo(from: before, to: after, actionName: actionName, undoManager: undoManager)
    }

    /// Registers an undo step for a change that was already made
    /// step by step (e.g. dragging with the mouse).
    func commitChange(from before: ProjectData, actionName: String? = nil, undoManager: UndoManager?) {
        guard before != data else { return }
        registerUndo(from: before, to: data, actionName: actionName, undoManager: undoManager)
    }

    private func registerUndo(from before: ProjectData, to after: ProjectData, actionName: String?, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.data = before
            doc.registerUndo(from: after, to: before, actionName: actionName, undoManager: undoManager)
        }
        if let actionName { undoManager?.setActionName(actionName) }
    }
}
