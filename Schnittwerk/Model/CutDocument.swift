// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let schnittwerkProject = UTType(exportedAs: "de.manuelweiser.schnittwerk.project")
    /// Declared in Info.plist (UTImportedTypeDeclarations); macOS has no own type for DXF.
    static let dxf = UTType(importedAs: "com.autodesk.dxf")
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
    /// SVG and DXF open as a new, unsaved project; saving asks for a
    /// `.schnittwerk` file, so the original file is never overwritten.
    static var readableContentTypes: [UTType] { [.schnittwerkProject, .svg, .dxf] }
    static var writableContentTypes: [UTType] { [.schnittwerkProject] }

    @Published var data: ProjectData
    /// Notes from opening an SVG/DXF (skipped text etc.), shown once.
    @Published var openNotes: [String] = []

    init() {
        data = ProjectData()
    }

    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if configuration.contentType.conforms(to: .schnittwerkProject) {
            data = try JSONDecoder().decode(ProjectData.self, from: raw)
            return
        }
        let fileName = configuration.file.filename ?? "Import"
        let url = URL(fileURLWithPath: fileName)
        let ext = configuration.contentType.conforms(to: .svg) ? "svg" : (url.pathExtension.isEmpty ? "dxf" : url.pathExtension)
        var (shape, warnings) = try ShapeImporter.importShape(data: raw, fileExtension: ext,
                                                               name: url.deletingPathExtension().lastPathComponent)
        var project = ProjectData()
        shape.placeInside(project.mat.displaySize)
        project.shapes = [shape]
        data = project
        openNotes = warnings
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
