// Schnittwerk – SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Main window of a project: objects on the left, mat in the middle,
/// settings on the right.
struct ContentView: View {
    @ObservedObject var document: CutDocument
    @Environment(\.undoManager) private var undoManager

    @State private var selection: UUID?
    @State private var zoom: CGFloat = 1
    @State private var showImporter = false
    @State private var showInspector = true
    @State private var message: AlertMessage?
    @State private var inspectorTab: InspectorTab = .object

    enum InspectorTab: Hashable { case object, cut }

    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 1, 1.5, 2, 3, 4]

    var body: some View {
        NavigationSplitView {
            ObjectListView(document: document, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            ScrollView([.horizontal, .vertical]) {
                MatCanvasView(document: document, selection: $selection, zoom: zoom)
                    .padding(8)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls)
                return true
            }
        }
        .inspector(isPresented: $showInspector) {
            VStack(spacing: 0) {
                Picker("Panel", selection: $inspectorTab) {
                    Text("Object").tag(InspectorTab.object)
                    Text("Cut").tag(InspectorTab.cut)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                switch inspectorTab {
                case .object: InspectorView(document: document, selection: selection)
                case .cut: CutPanelView(document: document)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar { toolbar }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.svg, .dxf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): message = AlertMessage(title: String(localized: "Import failed"), text: error.localizedDescription)
            }
        }
        .onAppear {
            // Notes from opening an SVG/DXF directly (File → Open, Finder)
            guard !document.openNotes.isEmpty else { return }
            message = AlertMessage(title: String(localized: "Imported with notes"),
                                   text: document.openNotes.joined(separator: "\n"))
            document.openNotes = []
            selection = document.data.shapes.first?.id
        }
        .alert(item: $message) { m in
            Alert(title: Text(verbatim: m.title), message: Text(verbatim: m.text))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("i", modifiers: .command)
                .help("Import SVG or DXF (⌘I)")
            Button(action: addText) { Label("Text", systemImage: "textformat") }
                .keyboardShortcut("t", modifiers: .command)
                .help("Add text (⌘T)")
        }
        ToolbarItemGroup {
            Button(action: duplicateSelection) { Label("Duplicate", systemImage: "plus.square.on.square") }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(selection == nil)
                .help("Duplicate (⌘D)")
            Button(role: .destructive, action: deleteSelection) { Label("Delete", systemImage: "trash") }
                .disabled(selection == nil)
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
                Button { zoom = 1 } label: { Text(verbatim: "\(Int(zoom * 100)) %") }
                    .help("Reset zoom")
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

    // MARK: - Actions

    private func zoomBy(_ direction: Int) {
        let steps = Self.zoomSteps
        let current = steps.firstIndex { $0 >= zoom - 0.001 } ?? 2
        zoom = steps[min(max(current + direction, 0), steps.count - 1)]
    }

    private func importFiles(_ urls: [URL]) {
        var notes: [String] = []
        var failures: [String] = []
        var lastID: UUID?
        let area = document.data.mat.displaySize
        var newShapes: [CutShape] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                var (shape, warnings) = try ShapeImporter.importShape(from: url)
                shape.placeInside(area)
                newShapes.append(shape)
                lastID = shape.id
                notes.append(contentsOf: warnings.map { "\(url.lastPathComponent): \($0)" })
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !newShapes.isEmpty {
            document.update(String(localized: "Import"), undoManager: undoManager) { $0.shapes.append(contentsOf: newShapes) }
            selection = lastID
        }
        if !failures.isEmpty {
            message = AlertMessage(title: String(localized: "Import failed"), text: (failures + notes).joined(separator: "\n"))
        } else if !notes.isEmpty {
            message = AlertMessage(title: String(localized: "Imported with notes"), text: notes.joined(separator: "\n"))
        }
    }

    private func addText() {
        guard let shape = CutShape.text(FontCatalog.defaultSpec(), at: CGPoint(x: 20, y: 20)) else { return }
        document.update(String(localized: "Add text"), undoManager: undoManager) { $0.shapes.append(shape) }
        selection = shape.id
        showInspector = true
    }

    private func duplicateSelection() {
        guard let id = selection, let shape = document.data.shapes.first(where: { $0.id == id }) else { return }
        let copy = shape.duplicated()
        document.update(String(localized: "Duplicate"), undoManager: undoManager) { $0.shapes.append(copy) }
        selection = copy.id
    }

    private func deleteSelection() {
        guard let id = selection else { return }
        document.update(String(localized: "Delete"), undoManager: undoManager) { $0.shapes.removeAll { $0.id == id } }
        selection = nil
    }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
