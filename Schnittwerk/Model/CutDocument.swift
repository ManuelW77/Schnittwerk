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
    /// Settings of tool 1 (left holder).
    var settings = CutSettings()
    /// Settings of tool 2 (right holder); nil until first changed.
    var settings2: CutSettings?
    /// Print & Cut with registration marks; nil = never switched on.
    var printAndCut: PrintAndCut?

    /// Settings of tool 1 or 2, with the matching holder.
    func settings(slot: Int) -> CutSettings {
        var s = slot == 2 ? (settings2 ?? .holder2Default) : settings
        s.holder = slot == 2 ? 2 : 1
        return s
    }

    mutating func setSettings(_ s: CutSettings, slot: Int) {
        var s = s
        s.holder = slot == 2 ? 2 : 1
        if slot == 2 { settings2 = s } else { settings = s }
    }

    /// Tools that have objects to cut, in the order they run.
    var usedSlots: [Int] {
        [1, 2].filter { slot in shapes.contains { $0.cutEnabled && $0.toolSlot == slot } }
    }

    /// Projects before tool 1/2: one setting with a holder number. A
    /// project set to holder 2 keeps cutting everything with holder 2.
    mutating func migrateHolder() {
        guard settings2 == nil, settings.holder == 2 else { return }
        settings2 = settings
        settings = CutSettings()
        for i in shapes.indices { shapes[i].toolSlot = 2 }
    }

    /// Gives objects with an id that is already taken a new id.
    /// A damaged or hand-edited file must not have two objects with the
    /// same id (lists and dragging rely on unique ids).
    mutating func makeShapeIDsUnique() {
        var seen = Set<UUID>()
        for i in shapes.indices where !seen.insert(shapes[i].id).inserted {
            shapes[i].id = UUID()
            seen.insert(shapes[i].id)
        }
    }
}

/// One open project window.
final class CutDocument: ReferenceFileDocument, ObservableObject {
    /// SVG and DXF can be opened, but are never written: the window is
    /// detached from the file right after opening (ContentView), and
    /// fileWrapper refuses to write anything but a `.schnittwerk` project.
    static var readableContentTypes: [UTType] { [.schnittwerkProject, .svg, .dxf] }
    static var writableContentTypes: [UTType] { [.schnittwerkProject] }

    @Published var data: ProjectData
    /// Notes from opening an SVG/DXF (skipped text etc.), shown once.
    @Published var openNotes: [String] = []
    /// True while this window is still linked to an SVG/DXF file.
    /// ContentView then turns it into an untitled project.
    var needsDetachFromSourceFile = false
    /// Name for the untitled project (file name without extension).
    var sourceFileName: String?

    init() {
        data = ProjectData()
    }

    init(configuration: ReadConfiguration) throws {
        guard let raw = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if configuration.contentType.conforms(to: .schnittwerkProject) {
            data = try JSONDecoder().decode(ProjectData.self, from: raw)
            data.makeShapeIDsUnique()
            data.migrateHolder()
            return
        }
        let fileName = configuration.file.filename ?? "Import"
        let url = URL(fileURLWithPath: fileName)
        needsDetachFromSourceFile = true
        sourceFileName = url.deletingPathExtension().lastPathComponent

        // Repair: earlier versions (0.1, 06.11.2026) could write a project
        // into the .svg file. Such files open as the project they contain.
        if raw.first == UInt8(ascii: "{"), let project = try? JSONDecoder().decode(ProjectData.self, from: raw) {
            data = project
            data.makeShapeIDsUnique()
            openNotes = [String(localized: "This file contained a Schnittwerk project instead of SVG/DXF. It was opened as a project. Save it as a .schnittwerk file.")]
            return
        }

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
        // Never write project JSON into an SVG/DXF file (data loss in 0.1)
        guard configuration.contentType.conforms(to: .schnittwerkProject) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Schnittwerk does not change SVG or DXF files. Use File → Save As to save a .schnittwerk project."),
            ])
        }
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
