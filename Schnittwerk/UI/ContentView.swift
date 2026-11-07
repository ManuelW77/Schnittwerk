// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Main window of a project: objects on the left, mat in the middle,
/// settings on the right.
struct ContentView: View {
    @ObservedObject var document: CutDocument
    @Environment(\.undoManager) private var undoManager

    @State private var selection: Set<UUID> = []
    @State private var zoom: CGFloat = 1
    @State private var showImporter = false
    /// What the file dialog opens: SVG/DXF, or an image to trace.
    @State private var importKind: ImportKind = .vector
    /// Image waiting in the trace window.
    @State private var tracing: TraceInput?

    enum ImportKind { case vector, image }
    @State private var showInspector = true
    @State private var message: AlertMessage?
    @State private var inspectorTab: InspectorTab = .object
    @State private var tool: DrawingTool = .select
    /// True once this window checked for an empty start window to replace.
    @State private var replacedBlankWindow = false
    /// Text object whose text is being edited in the sheet.
    @State private var editingText: TextEdit?

    struct TextEdit: Identifiable {
        let id: UUID
        var text: String
    }

    enum InspectorTab: Hashable, CaseIterable {
        case object, edit, cut

        var title: String {
            switch self {
            case .object: String(localized: "Object")
            case .edit: String(localized: "Edit")
            case .cut: String(localized: "Cut")
            }
        }

        var systemImage: String {
            switch self {
            case .object: "slider.horizontal.3"
            case .edit: "wand.and.rays"
            case .cut: "scissors"
            }
        }
    }

    /// Tool whose values the Cut panel shows.
    @State private var cutSlot = 1

    private static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    /// Objects to cut that stick out over the cutting area.
    private var outsideCount: Int {
        let area = document.data.mat.size
        return document.data.shapes.filter { $0.cutEnabled && !$0.fits(in: area) }.count
    }

    @ViewBuilder private var outsideNotice: some View {
        let count = outsideCount
        if count > 0 {
            Label("\(count) object(s) stick out over the cutting area. Those parts are not cut, to protect the mat.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        NavigationSplitView {
            ObjectListView(document: document, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            ScrollView([.horizontal, .vertical]) {
                MatCanvasView(document: document, selection: $selection, zoom: zoom, tool: $tool,
                              onCreated: {
                                  inspectorTab = .object
                                  showInspector = true
                              },
                              onEditText: beginTextEdit,
                              onPaste: pasteFromClipboard)
                    .padding(8)
                    .padding(.leading, 52) // room for the tool palette
                    .background(MatNavigator(zoom: $zoom, range: MatNavigator.zoomRange))
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(alignment: .top) { outsideNotice }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    ToolPalette(tool: $tool, addShape: addShape)
                    if tool == .eraser { EraserSizeControl() }
                }
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                // How the editing tools work, while one is active
                if [.points, .knife, .eraser].contains(tool) {
                    Text(tool.help)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 360, alignment: .leading)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(12)
                        .padding(.bottom, 44)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if !document.data.shapes.isEmpty {
                    ToolLegend(data: document.data)
                        .padding(.bottom, 12)
                        .onTapGesture {
                            inspectorTab = .cut
                            showInspector = true
                        }
                        .help("Which colour is cut with which tool. Click for the cut settings.")
                }
            }
            // Files from Finder, or drawings dragged straight out of another app
            .onDrop(of: [.fileURL, .svg, .pdf], isTargeted: nil) { providers in
                handleDrop(providers)
                return true
            }
        }
        .inspector(isPresented: $showInspector) {
            VStack(spacing: 0) {
                Picker("Panel", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                Group {
                    switch inspectorTab {
                    case .object: InspectorView(document: document, selection: $selection)
                    case .edit: EditPanelView(document: document, selection: $selection)
                    case .cut: CutPanelView(document: document, slot: $cutSlot)
                    }
                }
                // Room for a permanently shown scroll bar (mouse users),
                // so it never covers buttons at the right edge
                .contentMargins(.trailing, 12, for: .scrollContent)
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar { toolbar }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importKind == .vector ? [.svg, .dxf, .pdf] : ImageTracer.contentTypes,
                      allowsMultipleSelection: importKind == .vector) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): message = AlertMessage(title: String(localized: "Import failed"), text: error.localizedDescription)
            }
        }
        // Remember mat and tool values for "Last used" in new projects
        .onChange(of: document.data.mat) { NewProjectDefaults.remember(document.data) }
        .onChange(of: document.data.settings) { NewProjectDefaults.remember(document.data) }
        .onChange(of: document.data.settings2) { NewProjectDefaults.remember(document.data) }
        .onAppear {
            // Notes from opening an SVG/DXF directly (File → Open, Finder)
            guard !document.openNotes.isEmpty else { return }
            message = AlertMessage(title: String(localized: "Imported with notes"),
                                   text: document.openNotes.joined(separator: "\n"))
            document.openNotes = []
            selection = Set(document.data.shapes.prefix(1).map(\.id))
        }
        .sheet(item: $tracing) { input in
            TraceSheet(input: input) { layers in addTraced(layers, name: input.name) }
        }
        .sheet(item: $editingText) { edit in
            TextEditSheet(text: edit.text) { newText in
                applyTextEdit(id: edit.id, text: newText)
            }
        }
        .alert(item: $message) { m in
            Alert(title: Text(verbatim: m.title), message: Text(verbatim: m.text))
        }
        .background(WindowAccessor { window in
            // Lets the MCP server find this project (and select in it)
            DocumentRegistry.shared.register(document, window: window) { selection = $0 }
            // Opened from a file: take the place of an empty start window
            if !replacedBlankWindow {
                replacedBlankWindow = true
                let fromFile = document.needsDetachFromSourceFile
                    || NSDocumentController.shared.document(for: window)?.fileURL != nil
                if fromFile { DocumentRegistry.shared.replaceBlankProject(with: document, window: window) }
            }
            // Opened from an SVG/DXF: make it an untitled project so the
            // original file is never overwritten
            guard document.needsDetachFromSourceFile else { return }
            if SourceFileDetacher.detach(window: window, name: document.sourceFileName) {
                document.needsDetachFromSourceFile = false
            }
        })
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                importKind = .vector
                showImporter = true
            } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("i", modifiers: .command)
                .help("Import SVG, DXF or PDF (⌘I)")
            Button {
                importKind = .image
                showImporter = true
            } label: { Label("Trace image", systemImage: "photo.badge.plus") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help("Trace an image (PNG, JPG …) into cut lines (⇧⌘I)")
            .background {
                // ⌘T picks the text tool
                Button("Text") { tool = .text }
                    .keyboardShortcut("t", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        ToolbarItemGroup {
            UndoRedoButtons(undoManager: undoManager)

            Menu {
                Button("Group") { group() }
                    .disabled(!document.data.canGroup(editableSelection))
                Button("Ungroup") { ungroup() }
                    .disabled(!document.data.canUngroup(editableSelection))
                Divider()
                Button("Lock") { setLocked(true, ids: selection) }
                    .disabled(selection.isEmpty || !document.data.shapes.contains { selection.contains($0.id) && !$0.isLocked })
                Button("Unlock all") { setLocked(false, ids: Set(document.data.shapes.map(\.id))) }
                    .disabled(!document.data.shapes.contains(where: \.isLocked))
            } label: {
                Label("Arrange", systemImage: "square.3.layers.3d")
            }
            .help("Group objects so they move together (⌘G), or lock them (⌘L)")
            .background { arrangeShortcuts }

            Button(action: duplicateSelection) { Label("Duplicate", systemImage: "plus.square.on.square") }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(selection.isEmpty)
                .help("Duplicate (⌘D)")
            Button(role: .destructive, action: deleteSelection) { Label("Delete", systemImage: "trash") }
                .disabled(editableSelection.isEmpty)
                .help("Delete (⌫)")

            Picker("Mat", selection: Binding(
                get: { document.data.mat },
                set: { mat in document.update(String(localized: "Change mat"), undoManager: undoManager) { $0.mat = mat } }
            )) {
                ForEach(MatType.allCases) { Text($0.title).tag($0) }
            }
            .help("Mat or roll in the plotter")

            ControlGroup {
                Button { zoomBy(-1) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                Button { zoom = 1 } label: { Text(verbatim: "\(Int((zoom * 100).rounded())) %") }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Reset zoom (⌘0)")
                Button { zoomBy(1) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                    .keyboardShortcut("+", modifiers: .command)
            }

            Button { showInspector.toggle() } label: { Label("Settings", systemImage: "sidebar.right") }
                .help("Show or hide settings")

            Button {
                inspectorTab = .cut
                showInspector = true
            } label: { Label("Cut", systemImage: "scissors") }
                .help("Cut settings and send to the plotter")
        }
    }

    /// Keyboard shortcuts for the Arrange menu (menus in the toolbar
    /// do not handle shortcuts themselves).
    private var arrangeShortcuts: some View {
        ZStack {
            Button("Group") { group() }.keyboardShortcut("g", modifiers: .command)
            Button("Ungroup") { ungroup() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Lock") { setLocked(true, ids: selection) }.keyboardShortcut("l", modifiers: .command)
            Button("Unlock all") { setLocked(false, ids: Set(document.data.shapes.map(\.id))) }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    /// Selected objects that are not locked.
    private var editableSelection: Set<UUID> { document.data.unlocked(selection) }

    private func group() { document.group(selection, undoManager: undoManager) }

    private func ungroup() { document.ungroup(selection, undoManager: undoManager) }

    private func setLocked(_ locked: Bool, ids: Set<UUID>) {
        document.setLocked(locked, ids: ids, undoManager: undoManager)
        // Locked objects leave the selection on the mat
        if locked { selection.subtract(ids) }
    }

    private func beginTextEdit(_ id: UUID) {
        guard let shape = document.data.shapes.first(where: { $0.id == id }),
              !shape.isLocked, let spec = shape.text else { return }
        editingText = TextEdit(id: id, text: spec.text)
    }

    private func applyTextEdit(id: UUID, text: String) {
        document.update(String(localized: "Edit text"), undoManager: undoManager) { data in
            guard let i = data.shapes.firstIndex(where: { $0.id == id }), var spec = data.shapes[i].text else { return }
            spec.text = text
            data.shapes[i].updateText(spec)
        }
    }

    private func zoomBy(_ direction: Int) {
        let steps = Self.zoomSteps
        // Next step above or below the current (possibly pinched) zoom
        let next = direction > 0 ? steps.first { $0 > zoom + 0.001 } : steps.last { $0 < zoom - 0.001 }
        zoom = next ?? zoom
    }

    private func importFiles(_ urls: [URL]) {
        // Images go to the trace window (one at a time)
        let images = urls.filter(ImageTracer.isImage)
        if let first = images.first { openTrace(first) }
        let urls = urls.filter { !ImageTracer.isImage($0) }
        guard !urls.isEmpty else { return }
        var notes: [String] = []
        var failures: [String] = []
        let area = document.data.mat.displaySize
        var newShapes: [CutShape] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                var (shape, warnings) = try ShapeImporter.importShape(from: url)
                shape.placeInside(area)
                newShapes.append(shape)
                notes.append(contentsOf: warnings.map { "\(url.lastPathComponent): \($0)" })
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !newShapes.isEmpty {
            document.update(String(localized: "Import"), undoManager: undoManager) { $0.shapes.append(contentsOf: newShapes) }
            selection = Set(newShapes.map(\.id))
        }
        if !failures.isEmpty {
            message = AlertMessage(title: String(localized: "Import failed"), text: (failures + notes).joined(separator: "\n"))
        } else if !notes.isEmpty {
            message = AlertMessage(title: String(localized: "Imported with notes"), text: notes.joined(separator: "\n"))
        }
    }

    /// ⌘V on the mat: a drawing copied in another app.
    private func pasteFromClipboard() {
        do {
            guard let (shape, warnings) = try PasteboardImport.shape() else {
                message = AlertMessage(title: String(localized: "Nothing to paste"),
                                       text: String(localized: "The clipboard holds no vector drawing. Copy it as SVG or PDF in your design app."))
                return
            }
            addImported(shape, warnings: warnings, actionName: String(localized: "Paste"))
        } catch {
            message = AlertMessage(title: String(localized: "Paste failed"), text: error.localizedDescription)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { importFiles([url]) }
                }
            } else if let type = [UTType.svg, .pdf].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { importDropped(data, format: type == .svg ? "svg" : "pdf") }
                }
            }
        }
    }

    private func importDropped(_ data: Data, format: String) {
        do {
            let (shape, warnings) = try ShapeImporter.importShape(data: data, fileExtension: format,
                                                                  name: String(localized: "Dropped"))
            addImported(shape, warnings: warnings, actionName: String(localized: "Import"))
        } catch {
            message = AlertMessage(title: String(localized: "Import failed"), text: error.localizedDescription)
        }
    }

    private func addImported(_ shape: CutShape, warnings: [String], actionName: String) {
        var shape = shape
        shape.placeInside(document.data.mat.displaySize)
        document.update(actionName, undoManager: undoManager) { $0.shapes.append(shape) }
        selection = [shape.id]
        tool = .select
        if !warnings.isEmpty {
            message = AlertMessage(title: String(localized: "Imported with notes"), text: warnings.joined(separator: "\n"))
        }
    }

    private func openTrace(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let image = try ImageTracer.loadImage(from: url)
            tracing = TraceInput(image: image, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            message = AlertMessage(title: String(localized: "Import failed"),
                                   text: "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Puts the traced layers on the mat. Several layers become one
    /// group, so they stay in place relative to each other.
    private func addTraced(_ layers: [TraceLayer], name: String) {
        let used = layers.filter { !$0.lines.isEmpty }
        guard !used.isEmpty else { return }
        // Place all layers together: move them as one block onto the mat
        var block = CutShape(name: name, matPaths: used.flatMap(\.lines)
            .applying(CGAffineTransform(translationX: 20, y: 20)))
        let before = block.position
        block.placeInside(document.data.mat.displaySize)
        let move = CGAffineTransform(translationX: 20 + block.position.x - before.x,
                                     y: 20 + block.position.y - before.y)
        let group = used.count > 1 ? UUID() : nil
        let shapes = used.map { layer -> CutShape in
            var shape = CutShape(name: used.count > 1 ? "\(name) – \(layer.name)" : name,
                                 matPaths: layer.lines.applying(move))
            shape.groupID = group
            shape.colorHex = layer.color?.hex
            return shape
        }
        document.update(String(localized: "Trace image"), undoManager: undoManager) { $0.shapes.append(contentsOf: shapes) }
        selection = Set(shapes.map(\.id))
        tool = .select
        inspectorTab = .object
        showInspector = true
    }

    private func addShape(_ kind: ShapeSpec.Kind) {
        let shape = CutShape.basic(.standard(kind), at: CGPoint(x: 20, y: 20))
        document.update(String(localized: "Add shape"), undoManager: undoManager) { $0.shapes.append(shape) }
        selection = [shape.id]
        inspectorTab = .object
        showInspector = true
    }

    private func duplicateSelection() {
        let copies = document.duplicate(selection, undoManager: undoManager)
        if !copies.isEmpty { selection = copies }
    }

    private func deleteSelection() {
        selection.subtract(document.delete(selection, undoManager: undoManager))
    }
}

/// Floating tool palette at the left edge of the mat, like the tool
/// bar of drawing apps: select, text, freehand, curve and basic shapes.
struct ToolPalette: View {
    @Binding var tool: DrawingTool
    let addShape: (ShapeSpec.Kind) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(DrawingTool.allCases) { t in
                Button { tool = t } label: {
                    Image(systemName: t.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(tool == t ? Color.white : Color.primary)
                        .background(tool == t ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.help)
                .accessibilityLabel(Text(t.title))
                .accessibilityAddTraits(tool == t ? .isSelected : [])
            }
            Divider().frame(width: 26).padding(.vertical, 4)
            Menu {
                ForEach(ShapeSpec.Kind.allCases) { kind in
                    Button { addShape(kind) } label: { Label(kind.title, systemImage: kind.systemImage) }
                }
            } label: {
                Image(systemName: "square.on.circle")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 34, height: 34)
            .help("Add a basic shape")
            .accessibilityLabel(Text("Shape"))
        }
        .padding(5)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Size of the eraser, shown under the tool palette.
struct EraserSizeControl: View {
    @AppStorage("eraser.radius") private var radius = 2.0

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: CGFloat(4 + radius * 2)))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 30)
            Stepper("Eraser size", value: $radius, in: 0.5...10, step: 0.5)
                .labelsHidden()
            Text(verbatim: LengthUnit.current.text(radius))
                .font(.caption2.monospacedDigit())
        }
        .padding(6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help("Eraser size (radius)")
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// Sheet for editing the text of a text object (double-click on it).
struct TextEditSheet: View {
    @State var text: String
    let onApply: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit text").font(.headline)
            TextEditor(text: $text)
                .font(.title3)
                .frame(minWidth: 360, minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("Return makes a new line.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(text)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isEmpty)
            }
        }
        .padding(20)
    }
}

/// Back and forward through the edit history.
struct UndoRedoButtons: View {
    let undoManager: UndoManager?
    /// Changes whenever the history changes, so the buttons refresh.
    @State private var tick = 0

    private static let changes = NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)
        .merge(with: NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange),
               NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange))

    var body: some View {
        let _ = tick
        ControlGroup {
            Button { undoManager?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!(undoManager?.canUndo ?? false))
                .help(help(undo: true))
            Button { undoManager?.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!(undoManager?.canRedo ?? false))
                .help(help(undo: false))
        }
        .onReceive(Self.changes.receive(on: RunLoop.main)) { _ in tick &+= 1 }
    }

    private func help(undo: Bool) -> String {
        let name = (undo ? undoManager?.undoActionName : undoManager?.redoActionName) ?? ""
        if undo {
            return name.isEmpty ? String(localized: "Undo (⌘Z)") : String(localized: "Undo \(name) (⌘Z)")
        }
        return name.isEmpty ? String(localized: "Redo (⇧⌘Z)") : String(localized: "Redo \(name) (⇧⌘Z)")
    }
}
